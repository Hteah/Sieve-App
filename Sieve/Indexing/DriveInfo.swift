import Foundation

/// Which external drive a folder lives on, worked out from its path alone -- so it still answers
/// while the drive is unplugged. macOS mounts every non-boot volume (USB / Thunderbolt drives,
/// SD cards, network shares) at `/Volumes/<name>`; folders on the Mac itself resolve to `/Users/…`
/// and friends.
enum DriveInfo {
    static let volumesPrefix = "/Volumes/"

    /// "SAMPLES SSD" for "/Volumes/SAMPLES SSD/One Shots"; nil for anything not under /Volumes.
    static func externalDriveName(forPath path: String) -> String? {
        guard path.hasPrefix(volumesPrefix) else { return nil }
        let rest = path.dropFirst(volumesPrefix.count)
        let name = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The mount point of a drive: /Volumes/<name>.
    static func volumeURL(forDrive name: String) -> URL {
        URL(fileURLWithPath: volumesPrefix + name, isDirectory: true)
    }
}

extension Root {
    /// The external drive this root is on (see `DriveInfo`), or nil for a folder on the Mac.
    var externalDriveName: String? { DriveInfo.externalDriveName(forPath: lastResolvedPath) }
}
