import SwiftUI

enum ScanState {
    case idle
    case scanning(ScanProgress)
    /// `inaccessibleDirectoryCount`: how many directories couldn't be read
    /// (permission denied, vanished mid-scan) and were silently counted as
    /// empty rather than skipped entirely — surfaced so the treemap isn't
    /// mistaken for a complete picture of disk usage.
    case done(FolderNode, inaccessibleDirectoryCount: Int)
    case failed(String)
}

struct ContentView: View {
    @State private var scanState: ScanState = .idle
    @State private var zoomedNode: FolderNode?
    @State private var scanRootURL: URL?
    @State private var layoutSettings = LayoutSettings()
    @State private var showAbout = false
    /// The scanner backing whatever scan is currently running, so Cancel
    /// targets the right one. A fresh `FolderScanner` is created per scan
    /// rather than reused, since nothing about it is safe to share across
    /// overlapping scans.
    @State private var activeScanner: FolderScanner?
    @State private var scanTask: Task<Void, Never>?
    /// Bumped every time a new scan starts; a scan's callbacks check this
    /// before touching `scanState` so a stale scan (superseded by Open or
    /// Reload while it was still running) can't clobber a newer one's
    /// results after the fact.
    @State private var scanGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            headerLine
            content
        }
        .frame(minWidth: 700, minHeight: 500, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    /// Icon-and-label buttons mirroring the original's toolbar: Open,
    /// Reload, Zoom Full, Free Space (toggle), and About. "Zoom In/Out" and
    /// "Run or Open" from the original aren't included — click-to-zoom
    /// already covers granular zooming, and launching arbitrary files from
    /// a disk-usage tool isn't a core feature worth the extra surface area.
    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 4) {
            toolbarButton("Open", systemImage: "folder") { pickFolder() }
            toolbarButton("Reload", systemImage: "arrow.clockwise", disabled: scanRootURL == nil) {
                if let url = scanRootURL { startScan(url: url) }
            }
            toolbarButton("Zoom Full", systemImage: "arrow.up.left.and.arrow.down.right",
                          disabled: rootNode == nil || zoomedNode === rootNode) {
                if let root = rootNode { zoomedNode = root }
            }
            Divider().frame(height: 20)
            toolbarButton("Free Space", systemImage: layoutSettings.showFreeSpace ? "checkmark.square" : "square") {
                layoutSettings.showFreeSpace.toggle()
            }
            Divider().frame(height: 20)
            toolbarButton("About", systemImage: "info.circle") { showAbout = true }
            Spacer()
        }
        .padding(6)
    }

    private func toolbarButton(_ title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.system(size: 15))
                Text(title).font(.system(size: 9))
            }
            .frame(width: 56, height: 36)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }

    private var rootNode: FolderNode? {
        if case .done(let root, _) = scanState { return root }
        return nil
    }

    private var inaccessibleDirectoryCount: Int {
        if case .done(_, let count) = scanState { return count }
        return 0
    }

    @ViewBuilder
    private var headerLine: some View {
        if let root = rootNode, let url = scanRootURL {
            HStack(spacing: 6) {
                Button {
                    if let zoomed = zoomedNode, zoomed !== root {
                        zoomedNode = zoomed.parent ?? root
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(zoomedNode === root)

                Text(url.path)
                Text("—")
                if let total = FolderScanner.totalSpace(at: url) {
                    Text("\(ByteFormatter.string(from: total)) Total")
                }
                if let free = FolderScanner.freeSpace(at: url) {
                    Text("\(ByteFormatter.string(from: free)) Free")
                }
                if inaccessibleDirectoryCount > 0 {
                    Label("\(inaccessibleDirectoryCount) folders couldn’t be read — scan may be incomplete",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scanState {
        case .idle:
            ContentUnavailableView("No Folder Scanned",
                systemImage: "internaldrive",
                description: Text("Choose a folder or volume to visualize its disk usage."))
        case .scanning(let progress):
            VStack(spacing: 12) {
                ProgressView()
                Text(progress.currentPath).font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(progress.filesFound) files, \(progress.foldersFound) folders")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { activeScanner?.cancel() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let root, _):
            if let zoomed = zoomedNode, let rootURL = scanRootURL {
                TreemapView(root: root, rootURL: rootURL, zoomedNode: Binding(
                    get: { zoomed },
                    set: { zoomedNode = $0 }
                ), settings: $layoutSettings)
            }
        case .failed(let message):
            ContentUnavailableView("Scan Failed", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(url: url)
    }

    private func startScan(url: URL) {
        // Starting a new scan (via Open or Reload) supersedes whatever scan
        // was already running — cancel it and bump the generation so its
        // callbacks become no-ops instead of racing the new one.
        scanTask?.cancel()
        activeScanner?.cancel()
        scanGeneration += 1
        let generation = scanGeneration

        scanState = .scanning(ScanProgress(currentPath: url.path, filesFound: 0, foldersFound: 0))

        let newScanner = FolderScanner()
        activeScanner = newScanner

        scanTask = Task.detached(priority: .userInitiated) {
            do {
                let root = try newScanner.scan(url: url) { progress in
                    Task { @MainActor in
                        guard generation == scanGeneration else { return }
                        if case .scanning = scanState {
                            scanState = .scanning(progress)
                        }
                    }
                }
                FolderScanner.addFreeSpaceMarker(to: root, volumeURL: url)
                root.finalize()
                let inaccessibleCount = newScanner.inaccessibleDirectoryCount
                await MainActor.run {
                    guard generation == scanGeneration else { return }
                    scanState = .done(root, inaccessibleDirectoryCount: inaccessibleCount)
                    zoomedNode = root
                    scanRootURL = url
                    activeScanner = nil
                }
            } catch is ScanError {
                await MainActor.run {
                    guard generation == scanGeneration else { return }
                    scanState = .idle
                    activeScanner = nil
                }
            } catch {
                await MainActor.run {
                    guard generation == scanGeneration else { return }
                    scanState = .failed(error.localizedDescription)
                    activeScanner = nil
                }
            }
        }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 40))
            Text("Spacemonger-Mac").font(.title2).bold()
            Text("A Mac port of the disk-usage treemap concept from SpaceMonger 1.4 (seanofw/spacemonger1), reimplemented natively in Swift/SwiftUI.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 280)
            Button("Close") { dismiss() }
        }
        .padding(24)
    }
}
