import Foundation
import Darwin

/// Progress callback invoked periodically during a scan (roughly 5x/sec,
/// same throttling interval the original used for its scan dialog).
struct ScanProgress {
    let currentPath: String
    let filesFound: Int
    let foldersFound: Int
}

enum ScanError: Error {
    case cancelled
}

/// Recursively walks a directory tree, mirroring CFolder::LoadFolder /
/// LoadFolderInitial from the original: sizes are rounded up to the volume's
/// allocation block size (the Mac analogue of Windows' cluster size), and
/// symlinks / mount points are skipped rather than followed, so the scan
/// can't loop or wander onto another volume.
final class FolderScanner {
    private let fileManager = FileManager.default
    private var filesFound = 0
    private var foldersFound = 0
    private var lastProgressTime = Date.distantPast
    private let progressInterval: TimeInterval = 0.2
    private var isCancelled = false
    /// The starting volume's device ID, used to detect when a directory is
    /// actually a mounted volume nested under the scan root (a cloud-sync
    /// mount like Google Drive or OneDrive, an external disk, a network
    /// share). The original never crossed drive letters either — this is
    /// the Mac equivalent, since mounts here don't get their own drive
    /// letter, they just appear as an ordinary-looking subfolder.
    private var rootDeviceID: dev_t?

    func cancel() {
        isCancelled = true
    }

    /// Scans `url` (a volume root or any directory) and returns its tree.
    /// `onProgress` is called on the calling thread's queue — callers running
    /// this on a background queue should hop back to the main actor themselves.
    func scan(url: URL, onProgress: @escaping (ScanProgress) -> Void) throws -> FolderNode {
        filesFound = 0
        foldersFound = 0
        isCancelled = false
        rootDeviceID = deviceID(for: url)

        let blockSize = allocationBlockSize(for: url)
        let root = FolderNode(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                               size: 0, isDirectory: true)
        try scanDirectory(url: url, into: root, blockSize: blockSize, onProgress: onProgress)
        root.finalize()
        return root
    }

    private func allocationBlockSize(for url: URL) -> UInt64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           values.volumeAvailableCapacity != nil {
            // APFS/HFS+ don't expose a fixed "cluster size" the way FAT/NTFS
            // did; 4096 bytes matches APFS's default block size and is a
            // reasonable stand-in for the original's rounding behavior.
            return 4096
        }
        return 4096
    }

    private func roundUp(_ size: UInt64, to blockSize: UInt64) -> UInt64 {
        guard blockSize > 0 else { return size }
        let remainder = size % blockSize
        return remainder == 0 ? size : size + (blockSize - remainder)
    }

    private func deviceID(for url: URL) -> dev_t? {
        var s = stat()
        return url.withUnsafeFileSystemRepresentation { rep -> dev_t? in
            guard let rep, stat(rep, &s) == 0 else { return nil }
            return s.st_dev
        }
    }

    /// True if `url` is on a different volume than where the scan started —
    /// i.e. it's a mount point, not a real subfolder. Matches `find -xdev`.
    private func crossesVolumeBoundary(_ url: URL) -> Bool {
        guard let rootDeviceID, let dev = deviceID(for: url) else { return false }
        return dev != rootDeviceID
    }

    /// True if `url` contains a ".nofollow" marker directly inside it — the
    /// de facto convention FUSE-backed cloud-sync mounts (Google Drive,
    /// some OneDrive/network-share setups) use to tell backup/indexing
    /// tools not to traverse in, since it's a virtual filesystem rather
    /// than real local storage.
    private func hasNoFollowMarker(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".nofollow").path)
    }

    private func scanDirectory(url: URL, into node: FolderNode, blockSize: UInt64,
                                onProgress: @escaping (ScanProgress) -> Void) throws {
        if isCancelled { throw ScanError.cancelled }

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isAliasFileKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: resourceKeys, options: [])
        } catch {
            // Permission-denied or vanished directory: treat as empty, same
            // as the original silently skipping entries it can't enumerate.
            return
        }

        for childURL in contents {
            if isCancelled { throw ScanError.cancelled }

            guard let values = try? childURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }

            // Skip symlinks and aliases so the scan can't leave this volume
            // or loop back on itself — mirrors the reparse-point handling
            // in the original's LoadFolder.
            if values.isSymbolicLink == true || values.isAliasFile == true { continue }

            if values.isDirectory == true {
                // Skip mounted cloud/network volumes and directories that
                // explicitly opt out of traversal — recursing into them
                // would scan someone else's filesystem, not local disk.
                if crossesVolumeBoundary(childURL) || hasNoFollowMarker(childURL) { continue }

                foldersFound += 1
                let child = FolderNode(name: childURL.lastPathComponent, size: 0, isDirectory: true,
                                        modificationDate: values.contentModificationDate)
                try scanDirectory(url: childURL, into: child, blockSize: blockSize, onProgress: onProgress)
                node.addChild(child)
            } else {
                filesFound += 1
                let rawSize = UInt64(values.fileSize ?? 0)
                let roundedSize = roundUp(rawSize, to: blockSize)
                let child = FolderNode(name: childURL.lastPathComponent, size: roundedSize, isDirectory: false,
                                        modificationDate: values.contentModificationDate)
                node.addChild(child)
            }

            let now = Date()
            if now.timeIntervalSince(lastProgressTime) > progressInterval {
                lastProgressTime = now
                onProgress(ScanProgress(currentPath: childURL.path, filesFound: filesFound, foldersFound: foldersFound))
            }
        }
    }

    /// Adds a synthetic node representing unused space on the volume, so the
    /// treemap for a whole-volume scan shows free space alongside used space
    /// — same as the original's AddFile(..., "<<<<<<<<<<<<<<<<<<<<", freespace, ...).
    static func addFreeSpaceMarker(to root: FolderNode, volumeURL: URL) {
        guard let free = freeSpace(at: volumeURL), free > 0 else { return }
        let marker = FolderNode(name: "Free Space", size: free, isDirectory: false, isFreeSpaceMarker: true)
        root.addChild(marker)
    }

    static func freeSpace(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let free = values.volumeAvailableCapacity else { return nil }
        return UInt64(free)
    }

    /// Total volume capacity, used for the "X Gb Total - Y Gb Free" header
    /// text the original showed in its title bar.
    static func totalSpace(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity else { return nil }
        return UInt64(total)
    }
}
