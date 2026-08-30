import AVFoundation
import Foundation
import Observation
import os

/// Simple one-shot preview player with a live playhead. Lives on the main actor.
@MainActor
@Observable
final class PreviewPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var timer: Timer?
    private var scopedURL: URL?
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "player")

    private(set) var currentURL: URL?
    private(set) var currentSampleId: Int64?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var volume: Float = 1 { didSet { node.volume = volume } }

    init() {
        engine.attach(node)
    }

    func toggle(url: URL, sampleId: Int64, rootURL: URL?) {
        if currentSampleId == sampleId, isPlaying {
            stop()
        } else {
            play(url: url, sampleId: sampleId, rootURL: rootURL, from: 0)
        }
    }

    func play(url: URL, sampleId: Int64, rootURL: URL?, from seconds: TimeInterval = 0) {
        stop(keepFile: false)
        if let rootURL {
            _ = rootURL.startAccessingSecurityScopedResource()
            scopedURL = rootURL
        }
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            currentURL = url
            currentSampleId = sampleId
            duration = Double(f.length) / f.processingFormat.sampleRate
            try prepareEngine(format: f.processingFormat)
            seek(to: seconds)
        } catch {
            Self.log.error("play failed: \(error, privacy: .public)")
            releaseScope()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let f = file else { return }
        let sr = f.processingFormat.sampleRate
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * sr)
        let remaining = AVAudioFrameCount(max(0, f.length - frame))
        node.stop()
        guard remaining > 0 else { isPlaying = false; position = duration; return }
        startFrame = frame
        node.scheduleSegment(f, startingFrame: frame, frameCount: remaining, at: nil) { [weak self] in
            Task { @MainActor in self?.playbackEnded() }
        }
        do {
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            position = seconds
            startTimer()
        } catch {
            Self.log.error("engine start failed: \(error, privacy: .public)")
        }
    }

    func stop() { stop(keepFile: true) }

    private func stop(keepFile: Bool) {
        node.stop()
        timer?.invalidate(); timer = nil
        isPlaying = false
        if !keepFile {
            file = nil
            currentURL = nil
            currentSampleId = nil
            position = 0
            duration = 0
            releaseScope()
        }
    }

    private func playbackEnded() {
        // The completion fires slightly before the tail renders; only mark stopped if we're at the end.
        guard isPlaying else { return }
        if position >= duration - 0.05 || !node.isPlaying {
            isPlaying = false
            position = duration
            timer?.invalidate(); timer = nil
        }
    }

    private func prepareEngine(format: AVAudioFormat) throws {
        if currentFormat != format {
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            currentFormat = format
            engine.prepare()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying, let f = file,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        let sr = f.processingFormat.sampleRate
        position = Double(startFrame + playerTime.sampleTime) / sr
        if position >= duration { playbackEnded() }
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
