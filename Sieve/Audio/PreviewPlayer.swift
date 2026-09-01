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
    private var timer: Timer?
    private var scopedURL: URL?
    /// Playhead is tracked off a wall clock, not `node.playerTime`: that node's sample time
    /// keeps accumulating across stop()/reschedule cycles rather than resetting, which threw
    /// `position` past the end on the first resume and desynced play/pause.
    private var playStartDate: Date?
    private var playStartPosition: TimeInterval = 0
    /// Bumped on every schedule and every stop; a segment-completion callback is honoured only
    /// while its token is still current. `node.stop()` fires the completion of the segment it
    /// cancels, so without this a pause would land a stale "playback ended" on the next resume.
    private var playToken = 0
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
            pause()
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
        playToken &+= 1
        node.stop()
        guard remaining > 0 else { isPlaying = false; position = duration; return }
        playToken &+= 1
        let token = playToken
        node.scheduleSegment(f, startingFrame: frame, frameCount: remaining, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.playbackEnded(token: token) }
        }
        do {
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            position = seconds
            playStartPosition = seconds
            playStartDate = Date()
            startTimer()
        } catch {
            Self.log.error("engine start failed: \(error, privacy: .public)")
        }
    }

    /// Halts playback but keeps the file open and the playhead where it is, so `resume()`
    /// can continue from the same spot. This is what Space does in the list.
    func pause() { stop(keepFile: true) }

    /// Fully stops: drops the file, zeroes the playhead, releases the security scope.
    func stop() { stop(keepFile: false) }

    /// True when playback was paused partway through and `resume()` would continue it.
    var isPaused: Bool {
        file != nil && !isPlaying && position > 0 && position < duration
    }

    /// Continues a paused preview from where `pause()` left the playhead. If the previous
    /// play had reached the end, starts over from the top.
    func resume() {
        guard file != nil, !isPlaying else { return }
        seek(to: position < duration ? position : 0)
    }

    private func stop(keepFile: Bool) {
        playToken &+= 1
        node.stop()
        timer?.invalidate(); timer = nil
        isPlaying = false
        playStartDate = nil
        if !keepFile {
            file = nil
            currentURL = nil
            currentSampleId = nil
            position = 0
            duration = 0
            releaseScope()
        }
    }

    private func playbackEnded(token: Int) {
        guard token == playToken, isPlaying else { return }
        finishAtEnd()
    }

    private func finishAtEnd() {
        isPlaying = false
        position = duration
        playStartDate = nil
        timer?.invalidate(); timer = nil
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
        guard isPlaying, let start = playStartDate else { return }
        position = min(duration, max(0, playStartPosition + Date().timeIntervalSince(start)))
        if position >= duration { finishAtEnd() }
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
