import Foundation

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

    /// True for the synthetic "Free Space" entry SpaceMonger adds so a
    /// scanned volume's treemap accounts for unused space too.
    let isFreeSpaceMarker: Bool

    init(name: String, size: UInt64, isDirectory: Bool, modificationDate: Date? = nil, isFreeSpaceMarker: Bool = false) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
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
            node.size -= size
            ancestor = node.parent
        }
        self.parent = nil
    }
}
