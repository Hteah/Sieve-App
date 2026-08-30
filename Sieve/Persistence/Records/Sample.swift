import Foundation
import GRDB

enum SampleStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case present
    case missing
    case unavailable
}

struct Sample: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "sample"

    var id: Int64?
    var rootId: Int64
    var relativePath: String
    var filename: String
    var parentDir: String
    var ext: String
    var fileSize: Int64
    var modifiedAt: Date
    var fileHash: String?
    var audioHash: String?
    var durationSec: Double?
    var sampleRate: Double?
    var channels: Int?
    var bitDepth: Int?
    var formatName: String?
    var bpm: Double?
    var musicalKey: String?
    var waveform: Data?
    var peakDb: Double?
    var rmsDb: Double?
    var clippedSamples: Int?
    var status: SampleStatus
    var lastSeenAt: Date
    var indexedAt: Date?

    init(rootId: Int64, relativePath: String, fileSize: Int64, modifiedAt: Date, now: Date = Date()) {
        self.rootId = rootId
        self.relativePath = relativePath
        let comps = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        self.filename = comps.last.map(String.init) ?? relativePath
        self.parentDir = comps.dropLast().joined(separator: "/")
        self.ext = (self.filename as NSString).pathExtension.lowercased()
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.status = .present
        self.lastSeenAt = now
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let root = belongsTo(Root.self)

    /// True once the enrichment pass (metadata/hash/waveform) has run.
    var isEnriched: Bool { indexedAt != nil }

    /// Hash used for annotation lookup and duplicate grouping.
    var contentHash: String? { audioHash ?? fileHash }
}

/// Lightweight row used by the library table (no waveform blob decoding overhead beyond what's selected).
struct SampleRow: Codable, Identifiable, Hashable, Sendable, FetchableRecord {
    var id: Int64
    var rootId: Int64
    var relativePath: String
    var filename: String
    var parentDir: String
    var ext: String
    var fileSize: Int64
    var modifiedAt: Date
    var audioHash: String?
    var fileHash: String?
    var durationSec: Double?
    var sampleRate: Double?
    var channels: Int?
    var bitDepth: Int?
    var formatName: String?
    var bpm: Double?
    var musicalKey: String?
    var waveform: Data?
    var peakDb: Double?
    var rmsDb: Double?
    var clippedSamples: Int?
    var status: SampleStatus
    var rating: Int?
    var isFavorite: Bool?
    var tagNames: String?

    var contentHash: String? { audioHash ?? fileHash }
    var tags: [String] {
        guard let tagNames, !tagNames.isEmpty else { return [] }
        return tagNames.split(separator: "\u{1F}").map(String.init)
    }
}
