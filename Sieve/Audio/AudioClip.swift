import Foundation

/// De-interleaved Float32 PCM held in memory for editing. Value type: every edit returns a new
/// clip, and unedited channels share storage (copy-on-write), so undo snapshots stay cheap.
struct AudioClip: Sendable {
    var channels: [[Float]]      // channels[channel][frame]
    var sampleRate: Double

    var channelCount: Int { channels.count }
    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Clamps a caller's range to `0..<frameCount`; `nil` means the whole clip.
    func clampedRange(_ r: Range<Int>?) -> Range<Int> {
        guard let r else { return 0..<frameCount }
        let lo = max(0, min(r.lowerBound, frameCount))
        let hi = max(lo, min(r.upperBound, frameCount))
        return lo..<hi
    }

    // MARK: Edits (each returns a new clip)

    func cropped(to r: Range<Int>) -> AudioClip {
        let cr = clampedRange(r)
        guard !cr.isEmpty, cr != 0..<frameCount else { return self }
        return AudioClip(channels: channels.map { Array($0[cr]) }, sampleRate: sampleRate)
    }

    func removingRange(_ r: Range<Int>) -> AudioClip {
        let cr = clampedRange(r)
        guard !cr.isEmpty else { return self }
        return AudioClip(channels: channels.map { var c = $0; c.removeSubrange(cr); return c },
                         sampleRate: sampleRate)
    }

    func peakLinear(in r: Range<Int>) -> Float {
        let cr = clampedRange(r)
        var peak: Float = 0
        for ch in channels {
            for i in cr { let a = abs(ch[i]); if a > peak { peak = a } }
        }
        return peak
    }

    func withGain(_ gain: Float, in r: Range<Int>) -> AudioClip {
        let cr = clampedRange(r)
        guard gain != 1, !cr.isEmpty else { return self }
        return AudioClip(channels: channels.map { ch in
            var out = ch
            for i in cr { out[i] *= gain }
            return out
        }, sampleRate: sampleRate)
    }

    func amplified(db: Float, in r: Range<Int>) -> AudioClip {
        withGain(pow(10, db / 20), in: r)
    }

    /// Scales `r` so its loudest sample sits at `db` dBFS. No-op if the range is silent.
    func normalizedToPeak(db: Float, in r: Range<Int>) -> AudioClip {
        let peak = peakLinear(in: r)
        guard peak > 0 else { return self }
        return withGain(pow(10, db / 20) / peak, in: r)
    }

    func reversed(in r: Range<Int>) -> AudioClip {
        let cr = clampedRange(r)
        guard cr.count > 1 else { return self }
        return AudioClip(channels: channels.map { ch in
            var out = ch
            out.replaceSubrange(cr, with: ch[cr].reversed())
            return out
        }, sampleRate: sampleRate)
    }

    func silenced(in r: Range<Int>) -> AudioClip {
        let cr = clampedRange(r)
        guard !cr.isEmpty else { return self }
        return AudioClip(channels: channels.map { ch in
            var out = ch
            for i in cr { out[i] = 0 }
            return out
        }, sampleRate: sampleRate)
    }

    func fadedIn(in r: Range<Int>) -> AudioClip { faded(in: r, fadeIn: true) }
    func fadedOut(in r: Range<Int>) -> AudioClip { faded(in: r, fadeIn: false) }

    private func faded(in r: Range<Int>, fadeIn: Bool) -> AudioClip {
        let cr = clampedRange(r)
        guard cr.count > 1 else { return self }
        let n = cr.count
        var envelope = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let x = Float(k) / Float(n - 1)               // 0...1
            let g = 0.5 - 0.5 * cos(.pi * x)              // raised cosine, 0 -> 1
            envelope[k] = fadeIn ? g : 1 - g
        }
        return AudioClip(channels: channels.map { ch in
            var out = ch
            var k = 0
            for i in cr { out[i] *= envelope[k]; k += 1 }
            return out
        }, sampleRate: sampleRate)
    }

    /// Replaces `r` with `clip` (conformed to this clip's rate and channel count). Powers paste;
    /// a zero-width `r` inserts.
    func replacingRange(_ r: Range<Int>, with clip: AudioClip) -> AudioClip {
        let cr = clampedRange(r)
        let insert = clip.conformed(toRate: sampleRate, channelCount: max(1, channelCount))
        return AudioClip(channels: (0..<max(1, channelCount)).map { c in
            var out = channels.indices.contains(c) ? channels[c] : []
            out.replaceSubrange(cr, with: insert.channels[c])
            return out
        }, sampleRate: sampleRate)
    }

    /// Per-channel peak + RMS reduced to `buckets`, matching the shape stored in the DB — so the
    /// list thumbnail can show live editor state without a rescan.
    func thumbnailSummary(buckets: Int = WaveformSummary.thumbnailBuckets) -> WaveformSummary {
        let chs = max(1, channelCount)
        let b = max(1, buckets)
        let n = frameCount
        var peaks = Array(repeating: [Float](repeating: 0, count: b), count: chs)
        var rms = Array(repeating: [Float](repeating: 0, count: b), count: chs)
        guard n > 0 else { return WaveformSummary(bucketCount: b, channels: chs, peaks: peaks, rms: rms) }
        let per = Double(n) / Double(b)
        for c in 0..<channelCount {
            let ch = channels[c]
            for k in 0..<b {
                let lo = min(n - 1, Int(Double(k) * per))
                let hi = min(n, max(lo + 1, Int(Double(k + 1) * per)))
                var pk: Float = 0
                var sumSq = 0.0
                for i in lo..<hi {
                    let v = ch[i]
                    let a = abs(v)
                    if a > pk { pk = a }
                    sumSq += Double(v) * Double(v)
                }
                peaks[c][k] = pk
                rms[c][k] = Float((sumSq / Double(hi - lo)).squareRoot())
            }
        }
        return WaveformSummary(bucketCount: b, channels: chs, peaks: peaks, rms: rms)
    }

    /// Mixes to `target` channels and linearly resamples to `rate`. Linear interpolation is fine
    /// for the occasional paste across mismatched formats.
    func conformed(toRate rate: Double, channelCount target: Int) -> AudioClip {
        var chans = channels
        if chans.count != target {
            if target == 1 {
                let n = frameCount
                var mono = [Float](repeating: 0, count: n)
                for ch in chans { for i in 0..<n { mono[i] += ch[i] } }
                let g = 1 / Float(max(1, chans.count))
                for i in 0..<n { mono[i] *= g }
                chans = [mono]
            } else if chans.count == 1 {
                chans = Array(repeating: chans[0], count: target)
            } else if chans.isEmpty {
                chans = Array(repeating: [], count: target)
            } else {
                while chans.count < target { chans.append(chans[chans.count - 1]) }
                chans = Array(chans.prefix(target))
            }
        }
        if sampleRate > 0, abs(rate - sampleRate) > 0.5 {
            let ratio = rate / sampleRate
            chans = chans.map { src in
                let srcN = src.count
                guard srcN > 1 else { return src }
                let newN = max(1, Int((Double(srcN) * ratio).rounded()))
                var dst = [Float](repeating: 0, count: newN)
                for i in 0..<newN {
                    let pos = Double(i) / ratio
                    let i0 = min(srcN - 1, Int(pos))
                    let i1 = min(srcN - 1, i0 + 1)
                    let f = Float(pos - Double(i0))
                    dst[i] = src[i0] * (1 - f) + src[i1] * f
                }
                return dst
            }
        }
        return AudioClip(channels: chans, sampleRate: rate)
    }
}

/// Min/max envelope of a clip at a few power-of-two decimations, so the editor waveform can be
/// drawn without scanning every raw sample when zoomed out. Rebuilt after each edit.
struct PeakMip: Sendable {
    struct Level: Sendable {
        let stride: Int                    // frames per bin
        let minMax: [[SIMD2<Float>]]       // minMax[channel][bin] = (min, max)
    }

    let levels: [Level]
    let frameCount: Int

    init(_ clip: AudioClip, base: Int = 256, levelCount: Int = 6) {
        frameCount = clip.frameCount
        var levels: [Level] = []
        var stride = max(1, base)
        for _ in 0..<levelCount {
            guard clip.frameCount / stride >= 2 else { break }
            let bins = (clip.frameCount + stride - 1) / stride
            var rows: [[SIMD2<Float>]] = []
            for ch in clip.channels {
                var row = [SIMD2<Float>](repeating: SIMD2(0, 0), count: bins)
                for b in 0..<bins {
                    let lo = b * stride, hi = min(lo + stride, ch.count)
                    guard lo < hi else { continue }
                    var mn = ch[lo], mx = ch[lo]
                    for i in (lo + 1)..<hi {
                        let v = ch[i]
                        if v < mn { mn = v }
                        if v > mx { mx = v }
                    }
                    row[b] = SIMD2(mn, mx)
                }
                rows.append(row)
            }
            levels.append(Level(stride: stride, minMax: rows))
            stride *= 4
        }
        self.levels = levels
    }

    /// Coarsest level whose stride is still <= `spp` (samples per pixel), or nil to read raw samples.
    func level(forSamplesPerPixel spp: Double) -> Level? {
        var best: Level?
        for level in levels where Double(level.stride) <= spp { best = level }
        return best
    }
}
