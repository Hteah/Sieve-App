import AVFoundation
import Foundation
import Observation
import os

/// Plays an in-memory `AudioClip` (optionally a sub-range, optionally looping) for the inspector
/// editor. Its own engine, separate from `PreviewPlayer`, so list preview and editing don't
/// fight over one player node.
@MainActor
@Observable
final class AudioEditorPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var timer: Timer?
    private var rangeStart = 0        // first clip frame of what was scheduled
    private var scheduledFrames = 0
    private var isLooping = false
    private var clipSampleRate: Double = 44_100
    /// Playhead runs off a wall clock, not `node.playerTime`: the node's sample time keeps
    /// accumulating across stop()/reschedule cycles instead of resetting, which threw the
    /// playhead off on the first resume and desynced play/pause.
    private var playStartDate: Date?
    /// Bumped on every schedule and every stop; a buffer-completion callback is honoured only
    /// while its token is current, so a stop()'d buffer can't land a stale "finished" on the
    /// next play (which would jump the playhead to the end and desync play/pause).
    private var playToken = 0
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "editorplayer")

    private(set) var isPlaying = false
    private(set) var playheadFrame = 0   // absolute frame within the clip
    var volume: Float = 1 { didSet { node.volume = volume } }

    init() { engine.attach(node) }

    /// Plays `range` of `clip` (whole clip when nil). `looping` reschedules the same buffer seamlessly.
    func play(_ clip: AudioClip, range: Range<Int>?, looping: Bool) {
        stop()
        let r = clip.clampedRange(range)
        guard r.count > 0, clip.channelCount > 0,
              let buffer = Self.makeBuffer(clip, range: r) else { return }
        rangeStart = r.lowerBound
        scheduledFrames = r.count
        isLooping = looping
        clipSampleRate = clip.sampleRate
        playToken &+= 1
        let token = playToken
        do {
            try prepareEngine(format: buffer.format)
            let options: AVAudioPlayerNodeBufferOptions = looping ? [.loops, .interrupts] : [.interrupts]
            node.scheduleBuffer(buffer, at: nil, options: options,
                                completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.bufferFinished(token: token, looping: looping) }
            }
            if !engine.isRunning { try startEngineRecovering(format: buffer.format) }
            node.play()
            isPlaying = true
            playheadFrame = r.lowerBound
            playStartDate = Date()
            startTimer()
        } catch {
            Self.log.error("editor play failed: \(error, privacy: .public)")
        }
    }

    func stop() {
        playToken &+= 1
        node.stop()
        timer?.invalidate(); timer = nil
        isPlaying = false
        playStartDate = nil
    }

    private func bufferFinished(token: Int, looping: Bool) {
        guard token == playToken, !looping else { return }
        isPlaying = false
        playheadFrame = rangeStart + scheduledFrames
        playStartDate = nil
        timer?.invalidate(); timer = nil
    }

    private func prepareEngine(format: AVAudioFormat) throws {
        if currentFormat != format {
            // Reconnect without stopping the engine, so an output-capture tap on the mixer
            // (the recorder) isn't interrupted when a new clip's format comes through.
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            currentFormat = format
            if !engine.isRunning { engine.prepare() }
        }
    }

    // MARK: Output capture (used by AudioRecorder to record what the editor plays)

    var captureFormat: AVAudioFormat { engine.mainMixerNode.outputFormat(forBus: 0) }

    func beginOutputCapture(bufferSize: AVAudioFrameCount,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let mixer = engine.mainMixerNode
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: mixer.outputFormat(forBus: 0), block: block)
    }

    func endOutputCapture() {
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    /// Starts the engine; if it fails (e.g. the recorder just had the device), fully resets the
    /// graph and tries once more.
    private func startEngineRecovering(format: AVAudioFormat) throws {
        do {
            try engine.start()
        } catch {
            engine.stop()
            engine.reset()
            engine.connect(node, to: engine.mainMixerNode, format: format)
            currentFormat = format
            engine.prepare()
            try engine.start()
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
        let elapsed = max(0, Int(Date().timeIntervalSince(start) * clipSampleRate))
        // Wrap while looping; otherwise clamp so a tick at the boundary can't snap the
        // playhead back to the range start before `bufferFinished` lands.
        let played = isLooping ? elapsed % max(1, scheduledFrames) : min(elapsed, scheduledFrames)
        playheadFrame = rangeStart + played
        // End on the .dataPlayedBack callback, which tracks real audio. Only fall back to the
        // wall clock well past the end (a quarter second), so this can't pre-empt playback
        // that is still sounding and desync play/pause.
        if !isLooping, elapsed >= scheduledFrames + Int(clipSampleRate / 4) {
            bufferFinished(token: playToken, looping: false)
        }
    }

    private static func makeBuffer(_ clip: AudioClip, range r: Range<Int>) -> AVAudioPCMBuffer? {
        let channels = max(1, clip.channelCount)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(r.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(r.count)
        let dst = buffer.floatChannelData!
        for c in 0..<clip.channelCount {
            clip.channels[c].withUnsafeBufferPointer { src in
                dst[c].update(from: src.baseAddress! + r.lowerBound, count: r.count)
            }
        }
        return buffer
    }
}
