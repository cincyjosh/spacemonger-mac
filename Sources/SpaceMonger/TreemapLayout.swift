import Foundation
import CoreGraphics

/// A laid-out rectangle for one node, ready to draw.
struct DisplayRect: Identifiable {
    let id = UUID()
    let node: FolderNode
    let depth: Int
    let rect: CGRect
    /// True if this rect represents a folder header (its children are laid
    /// out inside it); false for a plain file box.
    let isFolder: Bool
}

/// Controls how "wide" vs "tall" the recursive split favors, and the
/// minimum box size below which children stop being subdivided and are
/// drawn as a single leftover block. Mirrors theApp.m_settings.bias/density
/// in the original.
struct LayoutSettings {
    /// -8...8: negative biases toward taller splits, positive toward wider.
    var bias: Int = 0
    /// Minimum width/height (in points) a box must have to be subdivided further.
    var minWidth: CGFloat = 20
    var minHeight: CGFloat = 14
    /// Height reserved for a folder's title bar, and inset around its children.
    var titleBarHeight: CGFloat = 12
    var childInset: CGFloat = 1
    /// When false, the synthetic "Free Space" entry is excluded from the size
    /// split (but stays in the tree) — mirrors the original's Free Space
    /// toolbar toggle, which used `showfreespace` the same way.
    var showFreeSpace: Bool = true
}

/// Direct port of CFolderView::BuildFolderLayout / SizeFolders.
///
/// This is NOT the "squarified" treemap algorithm most modern treemap
/// libraries use. It's a simpler recursive greedy bisection: split the
/// children into two groups of roughly equal total size (since children
/// arrive pre-sorted descending by size, alternating them between the two
/// groups is a good-enough greedy balance), then split the rectangle
/// horizontally or vertically — whichever the current aspect ratio (and the
/// user's bias setting) favors — proportionally to each group's size, and
/// recurse into each half. A folder that lands in a box big enough to hold
/// its own title bar becomes an expandable container; a box too small just
/// shows as a single leaf block.
enum TreemapLayout {
    static func layout(root: FolderNode, in rect: CGRect, settings: LayoutSettings) -> [DisplayRect] {
        var results: [DisplayRect] = []
        buildFolderLayout(rect: rect, folder: root, depth: 0, settings: settings, into: &results)
        return results
    }

    private static func buildFolderLayout(rect: CGRect, folder: FolderNode, depth: Int,
                                           settings: LayoutSettings, into results: inout [DisplayRect]) {
        guard !folder.children.isEmpty else { return }
        sizeFolders(rect: rect, folder: folder, children: folder.children, depth: depth,
                    settings: settings, into: &results)
    }

    private static func sizeFolders(rect: CGRect, folder: FolderNode, children: [FolderNode], depth: Int,
                                     settings: LayoutSettings, into results: inout [DisplayRect]) {
        guard !children.isEmpty, rect.width > 0, rect.height > 0 else { return }

        // Split into two groups of roughly equal total size. Children are
        // already sorted descending by size, so greedily assigning each one
        // to whichever running group is currently smaller gives a balanced
        // split without needing to search for an optimal partition.
        var group1: [FolderNode] = []
        var group2: [FolderNode] = []
        var sum1: UInt64 = 0
        var sum2: UInt64 = 0
        for child in children where child.size > 0 && (settings.showFreeSpace || !child.isFreeSpaceMarker) {
            if sum1 <= sum2 {
                group1.append(child)
                sum1 += child.size
            } else {
                group2.append(child)
                sum2 += child.size
            }
        }

        let total = sum1 + sum2
        guard total > 0 else { return }

        // Decide split axis from the current aspect ratio, nudged by the
        // user's bias setting (mirrors wbias/hbias in the original).
        let wBias = settings.bias > 0 ? CGFloat(settings.bias) + 8 : 8
        let hBias = settings.bias < 0 ? CGFloat(-settings.bias) + 8 : 8

        var rect1 = CGRect.zero
        var rect2 = CGRect.zero
        if (rect.width * wBias) / 8 > (rect.height * hBias) / 8 {
            let split = rect.width * CGFloat(sum1) / CGFloat(total)
            rect1 = CGRect(x: rect.minX, y: rect.minY, width: split, height: rect.height)
            rect2 = CGRect(x: rect.minX + split, y: rect.minY, width: rect.width - split, height: rect.height)
        } else {
            let split = rect.height * CGFloat(sum1) / CGFloat(total)
            rect1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: split)
            rect2 = CGRect(x: rect.minX, y: rect.minY + split, width: rect.width, height: rect.height - split)
        }

        placeGroup(group1, in: rect1, folder: folder, depth: depth, settings: settings, into: &results)
        placeGroup(group2, in: rect2, folder: folder, depth: depth, settings: settings, into: &results)
    }

    private static func placeGroup(_ group: [FolderNode], in rect: CGRect, folder: FolderNode, depth: Int,
                                    settings: LayoutSettings, into results: inout [DisplayRect]) {
        guard !group.isEmpty else { return }

        let bigEnough = rect.width > settings.minWidth && rect.height > settings.minHeight

        if group.count > 1 && bigEnough {
            sizeFolders(rect: rect, folder: folder, children: group, depth: depth, settings: settings, into: &results)
            return
        }

        guard let node = group.first else { return }

        guard bigEnough else {
            // Too small to subdivide or even label individually — draw as a
            // single leftover block for whatever's left in this group.
            results.append(DisplayRect(node: node, depth: depth, rect: rect, isFolder: false))
            return
        }

        if node.isDirectory && !node.children.isEmpty {
            results.append(DisplayRect(node: node, depth: depth, rect: rect, isFolder: true))
            let inset = settings.childInset
            let innerRect = CGRect(
                x: rect.minX + inset,
                y: rect.minY + settings.titleBarHeight,
                width: rect.width - inset * 2,
                height: rect.height - settings.titleBarHeight - inset)
            if innerRect.width > 0 && innerRect.height > 0 {
                buildFolderLayout(rect: innerRect, folder: node, depth: depth + 1, settings: settings, into: &results)
            }
        } else {
            results.append(DisplayRect(node: node, depth: depth, rect: rect, isFolder: node.isDirectory))
        }
    }
}
