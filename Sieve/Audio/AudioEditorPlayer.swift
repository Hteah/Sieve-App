import AVFoundation
import Foundation
import Observation
import os

/// How the editor's loop button repeats the playback range.
enum EditorLoopMode: Equatable {
    case off        // play once
    case loop       // repeat head-to-tail
    case pingPong   // forward, then backward, forever
}

/// Plays an in-memory `AudioClip` (optionally a sub-range, optionally looping — plain or
/// ping-pong) for the inspector editor. Its own engine, separate from `PreviewPlayer`, so list
/// preview and editing don't fight over one player node.
@MainActor
@Observable
final class AudioEditorPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private var timer: Timer?
    private var rangeStart = 0        // first clip frame of what was scheduled
    private var scheduledFrames = 0   // length of the scheduled buffer (2*forwardFrames-2 when ping-pong)
    private var forwardFrames = 0     // length of the real range; == scheduledFrames unless ping-pong
    private var isLooping = false
    private var isPingPong = false
    private var clipSampleRate: Double = 44_100
    /// Playhead is driven by the node's render clock (`playerTime.sampleTime`) so it stays in
    /// sync with the audio — important for short selections / loops where engine start-up
    /// latency is a big fraction of playback. `nodeAnchor` is that clock's value captured on
    /// the first tick of each play, subtracted out so the count across stop()/reschedule
    /// cycles doesn't matter. `playStartDate` is a wall-clock fallback for the ticks before
    /// the render clock is available.
    private var playStartDate: Date?
    private var nodeAnchor: AVAudioFramePosition?
    /// Bumped on every schedule and every stop; a buffer-completion callback is honoured only
    /// while its token is current, so a stop()'d buffer can't land a stale "finished" on the
    /// next play (which would jump the playhead to the end and desync play/pause).
    private var playToken = 0
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "editorplayer")

    private(set) var isPlaying = false
    private(set) var playheadFrame = 0   // absolute frame within the clip
    var volume: Float = 1 { didSet { node.volume = volume } }

    init() { engine.attach(node) }

    /// Plays `range` of `clip` (whole clip when nil). `.loop` reschedules the same buffer
    /// seamlessly; `.pingPong` schedules a forward+reversed buffer and loops that, so playback
    /// bounces back and forth. Ranges under 3 frames fall back to a plain loop.
    func play(_ clip: AudioClip, range: Range<Int>?, loopMode: EditorLoopMode) {
        stop()
        let r = clip.clampedRange(range)
        let loops = loopMode != .off
        let pingPong = loopMode == .pingPong && r.count >= 3
        guard r.count > 0, clip.channelCount > 0,
              let buffer = Self.makeBuffer(clip, range: r, pingPong: pingPong) else { return }
        rangeStart = r.lowerBound
        forwardFrames = r.count
        scheduledFrames = Int(buffer.frameLength)
        isLooping = loops
        isPingPong = pingPong
        clipSampleRate = clip.sampleRate
        playToken &+= 1
        let token = playToken
        do {
            try prepareEngine(format: buffer.format)
            let options: AVAudioPlayerNodeBufferOptions = loops ? [.loops, .interrupts] : [.interrupts]
            node.scheduleBuffer(buffer, at: nil, options: options,
                                completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.bufferFinished(token: token, looping: loops) }
            }
            if !engine.isRunning { try startEngineRecovering(format: buffer.format) }
            node.play()
            isPlaying = true
            playheadFrame = r.lowerBound
            playStartDate = Date()
            nodeAnchor = nil
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
        isPingPong = false
        playStartDate = nil
        nodeAnchor = nil
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
        guard isPlaying else { return }

        // Prefer the node's render clock so the playhead tracks the audio; anchor it on the
        // first available reading of this play and subtract that out. Fall back to the wall
        // clock until the render clock is up.
        let elapsed: Int
        if let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) {
            if nodeAnchor == nil { nodeAnchor = playerTime.sampleTime }
            elapsed = max(0, Int(playerTime.sampleTime - (nodeAnchor ?? 0)))
        } else if let start = playStartDate {
            elapsed = max(0, Int(Date().timeIntervalSince(start) * clipSampleRate))
        } else {
            return
        }

        // Wrap while looping; otherwise clamp so a tick at the boundary can't snap the
        // playhead back to the range start before `bufferFinished` lands. In ping-pong the
        // scheduled buffer is forward+reversed, so fold the second half back onto the range.
        let raw = isLooping ? elapsed % max(1, scheduledFrames) : min(elapsed, scheduledFrames)
        let played = (isPingPong && raw >= forwardFrames) ? (2 * forwardFrames - 2 - raw) : raw
        playheadFrame = rangeStart + played
        // End on the .dataPlayedBack callback, which tracks real audio. Only fall back to the
        // clock well past the end (a quarter second), so this can't pre-empt playback that is
        // still sounding and desync play/pause.
        if !isLooping, elapsed >= scheduledFrames + Int(clipSampleRate / 4) {
            bufferFinished(token: playToken, looping: false)
        }
    }

    /// Builds the buffer to schedule. `pingPong` appends the range reversed with both endpoints
    /// dropped (`f0 … f(n-1) f(n-2) … f1`, length `2n-2`), so looping it plays the range forward
    /// then backward with no repeated sample at the turnarounds. Caller guarantees `r.count >= 3`
    /// when `pingPong` is true.
    private static func makeBuffer(_ clip: AudioClip, range r: Range<Int>, pingPong: Bool) -> AVAudioPCMBuffer? {
        let channels = max(1, clip.channelCount)
        let frames = pingPong ? 2 * r.count - 2 : r.count
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let dst = buffer.floatChannelData!
        for c in 0..<clip.channelCount {
            clip.channels[c].withUnsafeBufferPointer { src in
                let base = src.baseAddress! + r.lowerBound
                dst[c].update(from: base, count: r.count)
                if pingPong {
                    var w = r.count
                    var i = r.count - 2
                    while i >= 1 { dst[c][w] = base[i]; w += 1; i -= 1 }
                }
            }
        }
        return buffer
    }
}
