import Foundation
import GRDB
import os

/// Owns the GRDB connection. One instance per app; tests create in-memory instances.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter
    private static let log = Logger(subsystem: "com.arlo.Sieve", category: "db")

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// In-memory database (tests / previews).
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// On-disk database inside the sandbox container.
    static func onDisk() throws -> AppDatabase {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Sieve", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "library.sqlite")
        var config = Configuration()
        config.busyMode = .timeout(5)
        #if DEBUG
        config.publicStatementArguments = true
        #endif
        let pool = try DatabasePool(path: url.path, configuration: config)
        log.info("opened \(url.path, privacy: .public)")
        return try AppDatabase(pool)
    }

    var reader: any DatabaseReader { writer }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = true
        #endif

        m.registerMigration("v1") { db in
            try db.create(table: "root") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("bookmarkData", .blob).notNull()
                t.column("lastResolvedPath", .text).notNull()
                t.column("volumeUUID", .text)
                t.column("isAvailable", .boolean).notNull().defaults(to: true)
                t.column("lastScanStarted", .datetime)
                t.column("lastScanCompleted", .datetime)
                t.column("fileCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("root", onDelete: .cascade).notNull()
                t.column("relativePath", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("parentDir", .text).notNull()
                t.column("ext", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("fileHash", .text)
                t.column("audioHash", .text)
                t.column("durationSec", .double)
                t.column("sampleRate", .double)
                t.column("channels", .integer)
                t.column("bitDepth", .integer)
                t.column("formatName", .text)
                t.column("bpm", .double)
                t.column("musicalKey", .text)
                t.column("waveform", .blob)
                t.column("peakDb", .double)
                t.column("rmsDb", .double)
                t.column("clippedSamples", .integer)
                t.column("status", .text).notNull().defaults(to: "present")
                t.column("lastSeenAt", .datetime).notNull()
                t.column("indexedAt", .datetime)
                t.uniqueKey(["rootId", "relativePath"])
            }
            try db.create(index: "sample_root_status", on: "sample", columns: ["rootId", "status"])
            try db.create(index: "sample_audioHash", on: "sample", columns: ["audioHash"])
            try db.create(index: "sample_fileHash", on: "sample", columns: ["fileHash"])
            try db.create(index: "sample_parentDir", on: "sample", columns: ["rootId", "parentDir"])
            try db.create(index: "sample_ext", on: "sample", columns: ["ext"])
            try db.create(index: "sample_indexedAt", on: "sample", columns: ["indexedAt"])

            try db.create(virtualTable: "sample_fts", using: FTS5()) { t in
                t.synchronize(withTable: "sample")
                t.tokenizer = .unicode61()
                t.column("filename")
                t.column("relativePath")
            }

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().collate(.nocase).unique()
                t.column("colorHex", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "annotation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentHash", .text)
                t.column("rootId", .integer)
                t.column("relativePath", .text)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "annotation_hash", on: "annotation", columns: ["contentHash"], unique: true)
            try db.create(index: "annotation_path", on: "annotation", columns: ["rootId", "relativePath"])

            try db.create(table: "annotation_tag") { t in
                t.belongsTo("annotation", onDelete: .cascade).notNull()
                t.belongsTo("tag", onDelete: .cascade).notNull()
                t.primaryKey(["annotationId", "tagId"])
            }

            try db.create(table: "file_op_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sampleId", .integer)
                t.column("rootId", .integer).notNull()
                t.column("relativePath", .text).notNull()
                t.column("op", .text).notNull()
                t.column("destinationPath", .text)
                t.column("performedAt", .datetime).notNull()
                t.column("succeeded", .boolean).notNull()
                t.column("error", .text)
            }

            // View joining samples with their annotation (by content hash, else by path) and tag names.
            try db.execute(sql: """
                CREATE VIEW sample_with_annotation AS
                SELECT s.*, a.id AS annotationId, a.rating AS rating, a.isFavorite AS isFavorite,
                       (SELECT group_concat(t.name, char(31))
                          FROM annotation_tag at JOIN tag t ON t.id = at.tagId
                         WHERE at.annotationId = a.id) AS tagNames
                FROM sample s
                LEFT JOIN annotation a
                  ON (s.audioHash IS NOT NULL AND a.contentHash = s.audioHash)
                  OR (s.audioHash IS NULL AND s.fileHash IS NOT NULL AND a.contentHash = s.fileHash)
                  OR (s.audioHash IS NULL AND s.fileHash IS NULL AND a.contentHash IS NULL
                      AND a.rootId = s.rootId AND a.relativePath = s.relativePath)
                """)
        }

        m.registerMigration("v2-folder-groups") { db in
            try db.create(table: "folder_group") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "root") { t in
                t.add(column: "groupId", .integer).references("folder_group", onDelete: .setNull)
            }
            try db.create(index: "root_groupId", on: "root", columns: ["groupId"])
        }

        m.registerMigration("v3-quick-tags") { db in
            try db.alter(table: "annotation") { t in
                t.add(column: "quickTags", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "DROP VIEW sample_with_annotation")
            try db.execute(sql: """
                CREATE VIEW sample_with_annotation AS
                SELECT s.*, a.id AS annotationId, a.rating AS rating, a.isFavorite AS isFavorite,
                       a.quickTags AS quickTags,
                       (SELECT group_concat(t.name, char(31))
                          FROM annotation_tag at JOIN tag t ON t.id = at.tagId
                         WHERE at.annotationId = a.id) AS tagNames
                FROM sample s
                LEFT JOIN annotation a
                  ON (s.audioHash IS NOT NULL AND a.contentHash = s.audioHash)
                  OR (s.audioHash IS NULL AND s.fileHash IS NOT NULL AND a.contentHash = s.fileHash)
                  OR (s.audioHash IS NULL AND s.fileHash IS NULL AND a.contentHash IS NULL
                      AND a.rootId = s.rootId AND a.relativePath = s.relativePath)
                """)
        }

        return m
    }
}
