import SwiftUI
import Darwin

/// Renders the treemap for `root` and handles click-to-zoom, mirroring the
/// original's double-click-to-zoom-in / right-click-to-zoom-out behavior
/// (here: single click to zoom in, the toolbar "Up" button to zoom out).
struct TreemapView: View {
    let root: FolderNode
    let rootURL: URL
    @Binding var zoomedNode: FolderNode
    @Binding var settings: LayoutSettings
    @State private var hoveredRect: DisplayRect?
    @State private var hoverLocation: CGPoint = .zero
    @State private var pendingDelete: DisplayRect?
    @State private var deleteError: String?
    // Bumped after a successful delete to force the treemap to recompute —
    // FolderNode is a reference type, so mutating the tree in place doesn't
    // otherwise trigger a re-render.
    @State private var refreshTick = 0

    /// Height of the always-visible header bar naming the currently zoomed
    /// folder — the red "TV Series" strip in the original screenshots.
    private let headerHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(x: 0, y: headerHeight, width: geometry.size.width,
                                 height: max(0, geometry.size.height - headerHeight))
            let rects = TreemapLayout.layout(root: zoomedNode, in: bounds, settings: settings)
            let _ = refreshTick

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let headerRect = CGRect(x: 0, y: 0, width: geometry.size.width, height: headerHeight)
                    context.fill(Path(headerRect), with: .color(BoxColors.color(depth: 0)))
                    let headerText = Text(zoomedNode.name).font(.system(size: 10, weight: .semibold))
                    context.draw(context.resolve(headerText),
                                 at: CGPoint(x: headerRect.minX + 4, y: headerRect.midY), anchor: .leading)

                    for item in rects {
                        draw(item, in: &context)
                    }
                }
                // Tap-to-zoom and hover-tooltip both live on this single
                // top layer — splitting them across the Canvas and a
                // separate overlay meant the overlay silently ate every tap
                // before it could reach the Canvas's own gesture.
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let hit = rects.last(where: { $0.rect.contains(location) && $0.isFolder }) {
                        zoomedNode = hit.node
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredRect = rects.last(where: { $0.rect.contains(location) })
                        hoverLocation = location
                    case .ended:
                        hoveredRect = nil
                    }
                }
                .contextMenu {
                    if let target = hoveredRect, !target.node.isFreeSpaceMarker {
                        Button(role: .destructive) {
                            pendingDelete = target
                        } label: {
                            Label("Move “\(target.node.name)” to Trash", systemImage: "trash")
                        }
                    }
                }

                if let hovered = hoveredRect {
                    tooltip(for: hovered)
                        // Follows the cursor with a small offset rather than
                        // sitting over the box's center, so it doesn't block
                        // the thing you're trying to read.
                        .position(x: min(hoverLocation.x + 70, geometry.size.width - 70),
                                  y: max(hoverLocation.y - 24, 16))
                        .allowsHitTesting(false)
                }
            }
        }
        .confirmationDialog(
            "Move “\(pendingDelete?.node.name ?? "")” to Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = pendingDelete { delete(target) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let target = pendingDelete {
                Text(target.node.isDirectory
                     ? "This folder and everything in it will be moved to the Trash."
                     : "This file will be moved to the Trash.")
            }
        }
        .alert("Couldn’t Delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Resolves a node's absolute path by walking from `rootURL` down through
    /// its ancestor chain (the tree only stores names, not full paths).
    private func fileURL(for node: FolderNode) -> URL {
        var url = rootURL
        for component in node.path.dropFirst() {
            url.appendPathComponent(component)
        }
        return url
    }

    /// Moves the node's underlying file/folder to the Trash — the Mac
    /// equivalent of the original's SHFileOperation(FO_DELETE, FOF_ALLOWUNDO),
    /// which sent deletions to the Recycle Bin rather than deleting outright.
    private func delete(_ item: DisplayRect) {
        let url = fileURL(for: item.node)
        if let reason = validationFailureReason(for: item.node, at: url) {
            deleteError = reason
            return
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            item.node.removeFromParent()
            if zoomedNode === item.node {
                zoomedNode = item.node.parent ?? root
            }
            refreshTick += 1
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Verifies the on-disk object still matches what was scanned, and that
    /// deleting it can't reach outside the scanned root. Time passes between
    /// scanning and clicking Delete — something could have been renamed,
    /// replaced with a symlink, or swapped out from under an ancestor path
    /// component in the meantime. Returns a user-facing reason the delete
    /// should be refused, or nil if it's safe to proceed.
    private func validationFailureReason(for node: FolderNode, at url: URL) -> String? {
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
            return "\(node.name) has changed since it was scanned (it's now a symbolic link). Rescan and try again."
        }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              let isDirectory = values.isDirectory else {
            return "\(node.name) no longer exists at that location. Rescan and try again."
        }
        if isDirectory != node.isDirectory {
            return "\(node.name) has changed since it was scanned. Rescan and try again."
        }

        // Resolve away any symlinked ancestor directories and confirm the
        // real path is still inside the scanned root, not somewhere a
        // swapped-out ancestor could have redirected it to.
        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            return "\(node.name) is no longer inside the scanned folder. Rescan and try again."
        }

        return nil
    }

    /// Colors cycle starting one step past the header bar's red, so a
    /// folder's own header row is never the same hue as the "you are here"
    /// bar above it — matches the red→orange→yellow→green progression in
    /// the original screenshots (TV Series / Chopped / Season N / episode).
    private func draw(_ item: DisplayRect, in context: inout GraphicsContext) {
        let color = item.node.isFreeSpaceMarker ? BoxColors.freeSpace : BoxColors.color(depth: item.depth + 1)
        let path = Path(item.rect)
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 0.5)

        // Folder titles sit directly on the box's own fill color — no
        // separate overlay bar — with a thin rule marking where the
        // reserved title strip ends and the children begin.
        if item.isFolder && item.rect.height > settings.titleBarHeight {
            let titleBottom = item.rect.minY + settings.titleBarHeight
            var rule = Path()
            rule.move(to: CGPoint(x: item.rect.minX, y: titleBottom))
            rule.addLine(to: CGPoint(x: item.rect.maxX, y: titleBottom))
            context.stroke(rule, with: .color(.black.opacity(0.5)), lineWidth: 0.5)

            let text = Text(item.node.name).font(.system(size: 9)).foregroundColor(.black.opacity(0.8))
            context.draw(context.resolve(text),
                         at: CGPoint(x: item.rect.minX + 3, y: item.rect.minY + settings.titleBarHeight / 2),
                         anchor: .leading)
        } else if item.rect.width > 26 && item.rect.height > 12 {
            let text = Text(item.node.name).font(.system(size: 9)).foregroundColor(.black.opacity(0.7))
            context.draw(context.resolve(text), at: CGPoint(x: item.rect.minX + 2, y: item.rect.minY + 1), anchor: .topLeading)
        }
    }

    /// Small, flat, pale-yellow tooltip — matches the original's compact
    /// info popup rather than a heavyweight blurred/shadowed card.
    private func tooltip(for item: DisplayRect) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.node.name).font(.system(size: 10, weight: .semibold))
            Text(ByteFormatter.exactString(from: item.node.size)).font(.system(size: 9))
            if let date = item.node.modificationDate {
                Text(date.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color(red: 1.0, green: 1.0, blue: 0.88))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.4), lineWidth: 0.5))
        .fixedSize()
        .foregroundColor(.black)
    }
}

enum ByteFormatter {
    static func string(from bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Exact byte count with thousands separators, matching the original's
    /// tooltip (e.g. "14,790,955,008 bytes").
    static func exactString(from bytes: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(count) bytes"
    }
}
