import Foundation
import GRDB
import Testing
@testable import Sieve

struct ExternalDrivesTests {
    @Test func driveNameComesFromTheVolumesPath() {
        #expect(DriveInfo.externalDriveName(forPath: "/Volumes/SAMPLES SSD/One Shots") == "SAMPLES SSD")
        #expect(DriveInfo.externalDriveName(forPath: "/Volumes/X") == "X")
        #expect(DriveInfo.externalDriveName(forPath: "/Volumes/X/") == "X")
        #expect(DriveInfo.externalDriveName(forPath: "/Users/h/Samples") == nil)
        #expect(DriveInfo.externalDriveName(forPath: "/Volumes") == nil)
        #expect(DriveInfo.externalDriveName(forPath: "/Volumes/") == nil)
        #expect(DriveInfo.volumeURL(forDrive: "SAMPLES SSD").path == "/Volumes/SAMPLES SSD")
    }

    /// Roots on /Volumes/A (at its top and in a sub-folder), one on /Volumes/AB (must not match "A"
    /// by prefix) and one on the Mac. The drive scope returns only drive A's samples, minus any
    /// that are unavailable.
    @Test func driveScopeSelectsOnlyThatDrivesSamples() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { d in
            let now = Date()
            for (name, path) in [("sub", "/Volumes/A/x"), ("top", "/Volumes/A"), ("other", "/Volumes/AB/y"), ("mac", "/Users/h/z")] {
                var root = Root(name: name, bookmarkData: Data(), lastResolvedPath: path, volumeUUID: nil)
                try root.insert(d)
                for file in ["1.wav", "2.wav"] {
                    var s = Sample(rootId: root.id!, relativePath: "\(name)-\(file)", fileSize: 100, modifiedAt: now, createdAt: now)
                    s.indexedAt = now
                    try s.insert(d)
                }
            }
            try d.execute(sql: "UPDATE sample SET status = 'unavailable' WHERE relativePath = 'top-2.wav'")
        }
        let rows = try await db.reader.read { try Queries.request(for: SampleFilter(scope: .drive("A"))).fetchAll($0) }
        #expect(rows.map(\.filename).sorted() == ["sub-1.wav", "sub-2.wav", "top-1.wav"])
    }
}
