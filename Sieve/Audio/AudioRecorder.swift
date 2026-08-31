import AVFoundation
import AppKit
import Foundation
import Observation
import os

/// Captures system audio input to a fresh 24-bit WAV in the user's recordings folder. Standalone —
/// it never touches the editor's clip. Tap buffers stream to a detached writer so nothing is held
/// in memory beyond the in-flight queue.
@MainActor
@Observable
final class AudioRecorder {
    private unowned let env: AppEnvironment
    private let engine = AVAudioEngine()
    private let levelBox = LevelBox()
    private var continuation: AsyncStream<RecChunk>.Continuation?
    private var writerTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var scopedFolder: URL?

    private(set) var isRecording = false
    private(set) var level: Float = 0            // 0…1, decayed — drives the pulsing waveform
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastRecordingURL: URL?
    private(set) var lastError: String?

    private nonisolated static let log = Logger(subsystem: "com.arlo.Sieve", category: "recorder")
    private static let maxSeconds: TimeInterval = 60 * 60

    init(env: AppEnvironment) { self.env = env }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        lastError = nil
        lastRecordingURL = nil

        guard await Self.requestMicrophone() else {
            lastError = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        guard let folder = resolveFolder() else { return }   // user cancelled the folder picker

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "No audio input is available."
            return
        }

        let dest = FileOperator.uniqueDestination(in: folder, filename: Self.timestampName()) {
            FileManager.default.fileExists(atPath: $0.path)
        }

        // Hold the folder's security scope for the whole take; released when the writer finishes.
        scopedFolder = folder.startAccessingSecurityScopedResource() ? folder : nil

        let (stream, cont) = AsyncStream<RecChunk>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        writerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.runWriter(stream: stream, dest: dest, sampleRate: sampleRate, channels: channels)
            await self?.writerFinished(url: dest)
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [levelBox, cont] buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            let ch = Int(buffer.format.channelCount)
            var frames = [[Float]](repeating: [], count: ch)
            var peak: Float = 0
            for c in 0..<ch {
                let p = data[c]
                frames[c] = Array(UnsafeBufferPointer(start: p, count: n))
                for i in 0..<n { let a = abs(p[i]); if a > peak { peak = a } }
            }
            levelBox.bump(peak)
            cont.yield(RecChunk(frames: frames))
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            cont.finish()
            releaseScope()
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            return
        }

        startedAt = Date()
        elapsed = 0
        level = 0
        isRecording = true
        startTimer()
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        timer?.invalidate(); timer = nil
        level = 0
    }

    // MARK: Writer (off the main actor)

    private nonisolated static func runWriter(stream: AsyncStream<RecChunk>, dest: URL,
                                              sampleRate: Double, channels: Int) async {
        let settings = AudioFileIO.pcmSettings(sampleRate: sampleRate, channels: channels, bits: .int(24))
        guard let file = try? AVAudioFile(forWriting: dest, settings: settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else {
            log.error("recorder: could not open \(dest.lastPathComponent, privacy: .public) for writing")
            return
        }
        for await chunk in stream {
            let n = chunk.frames.first?.count ?? 0
            guard n > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            buffer.frameLength = AVAudioFrameCount(n)
            let dst = buffer.floatChannelData!
            for c in 0..<min(channels, chunk.frames.count) {
                chunk.frames[c].withUnsafeBufferPointer { src in
                    dst[c].update(from: src.baseAddress!, count: n)
                }
            }
            try? file.write(from: buffer)
        }
    }

    private func writerFinished(url: URL) {
        releaseScope()
        writerTask = nil
        lastRecordingURL = url
        Task {
            if let rootId = env.rootId(containing: url) { await env.scanner.scan(rootId: rootId) }
        }
    }

    private func releaseScope() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    // MARK: Meter / elapsed

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isRecording else { return }
        let peak = levelBox.take()
        level = peak >= level ? peak : level * 0.8      // fast attack, slow release
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        if elapsed >= Self.maxSeconds {
            lastError = "Recording stopped at the \(Int(Self.maxSeconds / 60))-minute limit."
            stop()
        }
    }

    // MARK: Helpers

    private func resolveFolder() -> URL? {
        if let folder = env.bookmarks.lastRecordingsFolder() { return folder }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder to save recordings into."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        env.bookmarks.rememberRecordingsFolder(url)
        return url
    }

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: Date())).wav"
    }

    private static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Sendable, de-interleaved snapshot of one tap buffer.
private struct RecChunk: Sendable {
    var frames: [[Float]]
}

/// Thread-safe latch for the most recent input peak, written from the audio tap.
private final class LevelBox: Sendable {
    private let state = OSAllocatedUnfairLock<Float>(initialState: 0)

    func bump(_ v: Float) { state.withLock { if v > $0 { $0 = v } } }

    /// Reads and resets.
    func take() -> Float { state.withLock { let v = $0; $0 = 0; return v } }
}
