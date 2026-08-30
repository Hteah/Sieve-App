import Foundation

/// Per-channel peak + RMS per bucket. Encoded compactly (Float16) for storage in the DB.
struct WaveformSummary: Hashable, Sendable {
    var bucketCount: Int
    var channels: Int
    /// peaks[channel][bucket] in 0...1
    var peaks: [[Float]]
    /// rms[channel][bucket] in 0...1
    var rms: [[Float]]

    static let thumbnailBuckets = 512

    func encoded() -> Data {
        var data = Data(capacity: 4 + bucketCount * channels * 4)
        var bc = UInt16(bucketCount).littleEndian
        var ch = UInt16(channels).littleEndian
        withUnsafeBytes(of: &bc) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { data.append(contentsOf: $0) }
        for c in 0..<channels {
            let p = peaks[c].map { Float16($0).bitPattern.littleEndian }
            let r = rms[c].map { Float16($0).bitPattern.littleEndian }
            p.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
            r.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        return data
    }

    init(bucketCount: Int, channels: Int, peaks: [[Float]], rms: [[Float]]) {
        self.bucketCount = bucketCount
        self.channels = channels
        self.peaks = peaks
        self.rms = rms
    }

    init?(encoded data: Data) {
        guard data.count >= 4 else { return nil }
        let bc = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self) }.littleEndian)
        let ch = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }.littleEndian)
        guard bc > 0, ch > 0, data.count == 4 + bc * ch * 4 else { return nil }
        var peaks: [[Float]] = []
        var rms: [[Float]] = []
        var offset = 4
        func readRow() -> [Float] {
            var out = [Float](repeating: 0, count: bc)
            data.withUnsafeBytes { raw in
                for i in 0..<bc {
                    let bits = raw.loadUnaligned(fromByteOffset: offset + i * 2, as: UInt16.self).littleEndian
                    out[i] = Float(Float16(bitPattern: bits))
                }
            }
            offset += bc * 2
            return out
        }
        for _ in 0..<ch {
            peaks.append(readRow())
            rms.append(readRow())
        }
        self.init(bucketCount: bc, channels: ch, peaks: peaks, rms: rms)
    }

    /// Mono mix (max of channel peaks, mean of channel rms) for compact rendering.
    var mono: (peaks: [Float], rms: [Float]) {
        guard channels > 1 else { return (peaks[0], rms[0]) }
        var p = peaks[0], r = rms[0]
        for c in 1..<channels {
            for i in 0..<bucketCount {
                p[i] = max(p[i], peaks[c][i])
                r[i] += rms[c][i]
            }
        }
        for i in 0..<bucketCount { r[i] /= Float(channels) }
        return (p, r)
    }
}

/// Accumulates peak/RMS per bucket while streaming through audio frames.
struct WaveformAccumulator {
    let bucketCount: Int
    let channels: Int
    let totalFrames: Int64
    private let framesPerBucket: Double
    private var peak: [[Float]]
    private var sumSq: [[Double]]
    private var counts: [Int]
    private var framesConsumed: Int64 = 0

    init(bucketCount: Int, channels: Int, totalFrames: Int64) {
        self.bucketCount = max(1, bucketCount)
        self.channels = max(1, channels)
        self.totalFrames = max(1, totalFrames)
        self.framesPerBucket = Double(self.totalFrames) / Double(self.bucketCount)
        peak = Array(repeating: Array(repeating: 0, count: self.bucketCount), count: self.channels)
        sumSq = Array(repeating: Array(repeating: 0, count: self.bucketCount), count: self.channels)
        counts = Array(repeating: 0, count: self.bucketCount)
    }

    /// `channelData[c]` points to `frameCount` floats.
    mutating func consume(channelData: [UnsafePointer<Float>], frameCount: Int) {
        for f in 0..<frameCount {
            let globalFrame = framesConsumed + Int64(f)
            let b = min(bucketCount - 1, Int(Double(globalFrame) / framesPerBucket))
            counts[b] += 1
            for c in 0..<channels {
                let v = channelData[c][f]
                let a = abs(v)
                if a > peak[c][b] { peak[c][b] = a }
                sumSq[c][b] += Double(v * v)
            }
        }
        framesConsumed += Int64(frameCount)
    }

    func summary() -> WaveformSummary {
        var rms: [[Float]] = []
        for c in 0..<channels {
            rms.append((0..<bucketCount).map { b in
                counts[b] > 0 ? Float((sumSq[c][b] / Double(counts[b])).squareRoot()) : 0
            })
        }
        return WaveformSummary(bucketCount: bucketCount, channels: channels, peaks: peak, rms: rms)
    }
}
