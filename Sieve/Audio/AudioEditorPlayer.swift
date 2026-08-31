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
        do {
            try prepareEngine(format: buffer.format)
            let options: AVAudioPlayerNodeBufferOptions = looping ? [.loops, .interrupts] : [.interrupts]
            node.scheduleBuffer(buffer, at: nil, options: options) { [weak self] in
                Task { @MainActor in self?.bufferFinished(looping: looping) }
            }
            if !engine.isRunning { try startEngineRecovering(format: buffer.format) }
            node.play()
            isPlaying = true
            playheadFrame = r.lowerBound
            startTimer()
        } catch {
            Self.log.error("editor play failed: \(error, privacy: .public)")
        }
    }

    func stop() {
        node.stop()
        timer?.invalidate(); timer = nil
        isPlaying = false
    }

    private func bufferFinished(looping: Bool) {
        guard !looping else { return }
        isPlaying = false
        playheadFrame = rangeStart + scheduledFrames
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
        guard isPlaying, let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        let played = max(0, Int(playerTime.sampleTime)) % max(1, scheduledFrames)
        playheadFrame = rangeStart + played
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
