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

    // Equality/hashing skip the multi-KB `waveform` blob (compare its size instead) and the
    // 64-char hash strings. SwiftUI's Table calls `==` per row while diffing a re-sorted list,
    // and byte-comparing every row's waveform there is what made sorting large lists stall.
    static func == (lhs: SampleRow, rhs: SampleRow) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.rating == rhs.rating
            && lhs.isFavorite == rhs.isFavorite
            && lhs.tagNames == rhs.tagNames
            && lhs.filename == rhs.filename
            && lhs.parentDir == rhs.parentDir
            && lhs.relativePath == rhs.relativePath
            && lhs.rootId == rhs.rootId
            && lhs.fileSize == rhs.fileSize
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.durationSec == rhs.durationSec
            && lhs.sampleRate == rhs.sampleRate
            && lhs.bitDepth == rhs.bitDepth
            && lhs.channels == rhs.channels
            && lhs.formatName == rhs.formatName
            && lhs.peakDb == rhs.peakDb
            && lhs.rmsDb == rhs.rmsDb
            && lhs.clippedSamples == rhs.clippedSamples
            && lhs.bpm == rhs.bpm
            && lhs.musicalKey == rhs.musicalKey
            && lhs.waveform?.count == rhs.waveform?.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(modifiedAt)
        hasher.combine(rating)
        hasher.combine(tagNames)
    }
}
