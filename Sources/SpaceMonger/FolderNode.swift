import Foundation
import Darwin

/// A scanned file or folder in the tree.
///
/// Mirrors the original CFolder from SpaceMonger 1: an entry has a name,
/// an on-disk size (rounded up to the filesystem's allocation block size,
/// same idea as the Windows "cluster size" rounding), and — for folders —
/// children sorted by descending size so the layout algorithm can do its
/// greedy split without re-sorting.
final class FolderNode {
    let name: String
    /// Size in bytes, rounded up to the volume's allocation block size for
    /// files; for folders this is the sum of all descendants.
    private(set) var size: UInt64
    let isDirectory: Bool
    let modificationDate: Date?
    weak var parent: FolderNode?
    private(set) var children: [FolderNode] = []

    /// The device and inode number captured (via `lstat`, not following
    /// symlinks) at scan time. A rename or a same-type replacement (e.g. one
    /// directory swapped for another directory) doesn't change size/type,
    /// so those checks alone can't catch it — a mismatched inode can. Not
    /// available for the synthetic Free Space entry, which has no real path.
    let deviceID: dev_t?
    let inode: ino_t?

    /// True for the synthetic "Free Space" entry SpaceMonger adds so a
    /// scanned volume's treemap accounts for unused space too.
    let isFreeSpaceMarker: Bool

    init(name: String, size: UInt64, isDirectory: Bool, modificationDate: Date? = nil,
         deviceID: dev_t? = nil, inode: ino_t? = nil, isFreeSpaceMarker: Bool = false) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.deviceID = deviceID
        self.inode = inode
        self.isFreeSpaceMarker = isFreeSpaceMarker
    }

    func addChild(_ child: FolderNode) {
        children.append(child)
        child.parent = self
        size += child.size
    }

    /// Sorts children by descending size, recursively. Mirrors CFolder::Finalize
    /// (which used a radix sort for O(n) performance on huge folders; Swift's
    /// introsort is fast enough at the sizes real folders actually reach).
    func finalize() {
        children.sort { $0.size > $1.size }
        for child in children {
            child.finalize()
        }
    }

    var path: [String] {
        var components: [String] = []
        var node: FolderNode? = self
        while let n = node {
            components.append(n.name)
            node = n.parent
        }
        return components.reversed()
    }

    /// Detaches this node from its parent and subtracts its size from every
    /// ancestor, keeping the tree consistent after the underlying file/folder
    /// has actually been deleted on disk. Mirrors the bookkeeping in the
    /// original's OnFileDelete, which patched sizes back up the folder chain
    /// after SHFileOperation succeeded.
    func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var ancestor: FolderNode? = parent
        while let node = ancestor {
            // Saturating subtraction: the invariant (a child's size never
            // exceeds its ancestors') always holds today by construction,
            // but UInt64 underflow is an instant crash if that's ever wrong,
            // so this costs nothing and removes that failure mode outright.
            node.size = node.size > size ? node.size - size : 0
            ancestor = node.parent
        }
        self.parent = nil
    }
}
