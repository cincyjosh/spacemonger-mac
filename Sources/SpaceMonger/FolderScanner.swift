import Foundation
import Darwin

/// Progress callback invoked periodically during a scan (roughly 5x/sec,
/// same throttling interval the original used for its scan dialog).
struct ScanProgress {
    let currentPath: String
    let filesFound: Int
    let foldersFound: Int
}

/// Recursively walks a directory tree, mirroring CFolder::LoadFolder /
/// LoadFolderInitial from the original: sizes are rounded up to the volume's
/// allocation block size (the Mac analogue of Windows' cluster size), and
/// symlinks / mount points are skipped rather than followed, so the scan
/// can't loop or wander onto another volume.
///
/// Cancellation rides on the caller's own `Task` (`ContentView` tracks the
/// scan as `scanTask` and calls `.cancel()` on it) rather than a custom
/// cancel flag — `scanDirectory` periodically calls
/// `Task.checkCancellation()`, which reads the currently-executing task's
/// cancellation state and throws `CancellationError` if it's been
/// cancelled. That's the same check whether called from sync or async code,
/// as long as it's still running within that task's frame, so there's no
/// lock needed here at all.
///
/// `@unchecked Sendable`: crosses from the main actor (created in
/// `ContentView`) into a background `Task.detached`, but every property is
/// only touched from within that one scan's own call stack — each scan gets
/// its own `FolderScanner` instance rather than sharing one, so there's no
/// actual concurrent access for the compiler to not be able to see.
final class FolderScanner: @unchecked Sendable {
    private let fileManager = FileManager.default
    private var filesFound = 0
    private var foldersFound = 0
    private var lastProgressTime = Date.distantPast
    private let progressInterval: TimeInterval = 0.2
    /// The starting volume's device ID, used to detect when a directory is
    /// actually a mounted volume nested under the scan root (a cloud-sync
    /// mount like Google Drive or OneDrive, an external disk, a network
    /// share). The original never crossed drive letters either — this is
    /// the Mac equivalent, since mounts here don't get their own drive
    /// letter, they just appear as an ordinary-looking subfolder.
    private var rootDeviceID: dev_t?
    /// Count of directories that couldn't be enumerated (permission denied,
    /// vanished mid-scan, etc.) and were silently treated as empty. Exposed
    /// so the UI can tell the user the scan may be incomplete, rather than
    /// presenting a folder that came up empty as if that were its real
    /// contents.
    private(set) var inaccessibleDirectoryCount = 0

    /// Scans `url` (a volume root or any directory) and returns its
    /// (unsorted) tree — call `finalize()` on the result once, after any
    /// additional nodes (e.g. the free-space marker) have been added, rather
    /// than here, so the tree isn't sorted twice.
    /// `onProgress` is called on the calling thread's queue — callers running
    /// this on a background queue should hop back to the main actor themselves.
    func scan(url: URL, onProgress: @escaping (ScanProgress) -> Void) throws -> FolderNode {
        filesFound = 0
        foldersFound = 0
        inaccessibleDirectoryCount = 0
        rootDeviceID = deviceID(for: url)
        let rootIdentity = lstatIdentity(for: url)

        let blockSize = allocationBlockSize(for: url)
        let root = FolderNode(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                               size: 0, isDirectory: true,
                               deviceID: rootIdentity?.0, inode: rootIdentity?.1)
        try scanDirectory(url: url, into: root, blockSize: blockSize, onProgress: onProgress)
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

    /// Captures the (device, inode) pair identifying this exact filesystem
    /// object right now, via `lstat` (so a symlink is identified as itself,
    /// not as whatever it points to). Stored on the `FolderNode` so a delete
    /// later can confirm it's still removing the same object it scanned,
    /// not something else of the same name/type that replaced it.
    private func lstatIdentity(for url: URL) -> (dev_t, ino_t)? {
        var s = stat()
        return url.withUnsafeFileSystemRepresentation { rep -> (dev_t, ino_t)? in
            guard let rep, lstat(rep, &s) == 0 else { return nil }
            return (s.st_dev, s.st_ino)
        }
    }

    /// True if `url` is on a different volume than where the scan started —
    /// i.e. it's a mount point, not a real subfolder. Matches `find -xdev`.
    /// Fails closed: if volume identity can't be established at all (`stat`
    /// failure), the directory is treated as a boundary and skipped rather
    /// than silently allowed through.
    private func crossesVolumeBoundary(_ url: URL) -> Bool {
        guard let rootDeviceID, let dev = deviceID(for: url) else { return true }
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
        try Task.checkCancellation()

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isAliasFileKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: resourceKeys, options: [])
        } catch {
            // Permission-denied or vanished directory: treated as empty,
            // same as the original silently skipping entries it can't
            // enumerate — but counted, so the UI can flag the scan as
            // possibly incomplete instead of presenting this as the folder's
            // real (empty) contents.
            inaccessibleDirectoryCount += 1
            return
        }

        for childURL in contents {
            try Task.checkCancellation()

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

                let identity = lstatIdentity(for: childURL)
                foldersFound += 1
                let child = FolderNode(name: childURL.lastPathComponent, size: 0, isDirectory: true,
                                        modificationDate: values.contentModificationDate,
                                        deviceID: identity?.0, inode: identity?.1)
                try scanDirectory(url: childURL, into: child, blockSize: blockSize, onProgress: onProgress)
                node.addChild(child)
            } else {
                let identity = lstatIdentity(for: childURL)
                filesFound += 1
                let rawSize = UInt64(values.fileSize ?? 0)
                let roundedSize = roundUp(rawSize, to: blockSize)
                let child = FolderNode(name: childURL.lastPathComponent, size: roundedSize, isDirectory: false,
                                        modificationDate: values.contentModificationDate,
                                        deviceID: identity?.0, inode: identity?.1)
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
    /// Only applies to an actual volume-root scan: adding a whole volume's
    /// free space to an ordinary subfolder would make that folder look
    /// comparable in size to all the free space on the disk, which is
    /// meaningless — an arbitrary folder isn't what's using (or not using)
    /// that space.
    static func addFreeSpaceMarker(to root: FolderNode, volumeURL: URL) {
        guard isVolumeRoot(volumeURL) else { return }
        guard let free = freeSpace(at: volumeURL), free > 0 else { return }
        let marker = FolderNode(name: "Free Space", size: free, isDirectory: false, isFreeSpaceMarker: true)
        root.addChild(marker)
    }

    static func isVolumeRoot(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volumeURL = values.volume else { return false }
        return url.standardizedFileURL.path == volumeURL.standardizedFileURL.path
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
