import Foundation
import Darwin

/// Everything needed to validate-and-delete a scanned item, captured as
/// plain Sendable values rather than references into the live tree —
/// `FolderNode`/`DisplayRect` aren't Sendable, and capturing them into a
/// detached task (even just to read from) is a real data-race hazard the
/// Swift 6 concurrency checker correctly flags, not a style nitpick.
struct DeletionRequest: Sendable {
    let targetURL: URL
    let targetName: String
    let targetIsDirectory: Bool
    let targetDeviceID: dev_t?
    let targetInode: ino_t?
    let rootURL: URL
    let rootDeviceID: dev_t?
    let rootInode: ino_t?
}

/// Refusal reason shown to the user when a delete is not safe to perform.
struct DeletionRefused: Error {
    let message: String
}

/// Validates a deletion target and performs the actual Trash move in one
/// synchronous, uninterrupted pass. Splitting "validate" and "trash" into
/// separate steps (even just scheduling one on a background task after the
/// other ran on the main actor) reopens the exact TOCTOU window the
/// validation exists to close — something could change in the gap between
/// the two. Doing both back-to-back here, on the same background thread,
/// keeps that window as small as it can possibly be.
enum DeletionValidator {
    static func validateAndTrash(_ request: DeletionRequest) throws {
        let url = request.targetURL

        // Reject if the leaf itself is now a symlink — trashing it could
        // silently follow the link to somewhere never actually scanned.
        // Checked with lstat (not `.isSymbolicLinkKey`, which some resource
        // value lookups can resolve through) so the symlink itself is what's
        // inspected, not whatever it points to.
        var linkStat = stat()
        let isSymlink = url.withUnsafeFileSystemRepresentation { rep -> Bool in
            guard let rep, lstat(rep, &linkStat) == 0 else { return false }
            return (linkStat.st_mode & S_IFMT) == S_IFLNK
        }
        if isSymlink {
            throw DeletionRefused(message: "\(request.targetName) has changed since it was scanned (it's now a symbolic link). Rescan and try again.")
        }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              let isDirectory = values.isDirectory else {
            throw DeletionRefused(message: "\(request.targetName) no longer exists at that location. Rescan and try again.")
        }
        if isDirectory != request.targetIsDirectory {
            throw DeletionRefused(message: "\(request.targetName) has changed since it was scanned. Rescan and try again.")
        }

        // Same type isn't enough — a directory can be swapped for a
        // different directory of the same name without changing type or
        // (necessarily) size. Compare the (device, inode) pair captured at
        // scan time against what's actually at this path right now. Fails
        // closed: if identity wasn't captured during the scan, there's
        // nothing to verify against, so refuse rather than skip the check.
        guard let expectedDevice = request.targetDeviceID, let expectedInode = request.targetInode else {
            throw DeletionRefused(message: "\(request.targetName) couldn’t be safely identified when it was scanned. Rescan and try again.")
        }
        guard let currentIdentity = identity(at: url), currentIdentity == (expectedDevice, expectedInode) else {
            throw DeletionRefused(message: "\(request.targetName) has been replaced since it was scanned. Rescan and try again.")
        }

        // The scanned root itself could have been replaced wholesale (e.g.
        // the folder was deleted and a new one created at the same path).
        if let expectedRootDevice = request.rootDeviceID, let expectedRootInode = request.rootInode {
            guard let currentRootIdentity = identity(at: request.rootURL),
                  currentRootIdentity == (expectedRootDevice, expectedRootInode) else {
                throw DeletionRefused(message: "The scanned folder itself has changed. Rescan and try again.")
            }
        }

        // Resolve away any symlinked ancestor directories and confirm the
        // real path is still inside the scanned root, not somewhere a
        // swapped-out ancestor could have redirected it to.
        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = request.rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard PathContainment.isContained(resolvedTarget.pathComponents, within: resolvedRoot.pathComponents) else {
            throw DeletionRefused(message: "\(request.targetName) is no longer inside the scanned folder. Rescan and try again.")
        }

        // Everything checked out immediately above this call — the Mac
        // equivalent of the original's SHFileOperation(FO_DELETE,
        // FOF_ALLOWUNDO), which sent deletions to the Recycle Bin rather
        // than deleting outright.
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func identity(at url: URL) -> (dev_t, ino_t)? {
        var s = stat()
        return url.withUnsafeFileSystemRepresentation { rep -> (dev_t, ino_t)? in
            guard let rep, lstat(rep, &s) == 0 else { return nil }
            return (s.st_dev, s.st_ino)
        }
    }
}
