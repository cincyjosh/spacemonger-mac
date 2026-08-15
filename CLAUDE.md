# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Spacemonger-Mac is a native macOS disk-usage treemap visualizer (SwiftUI, macOS 14+), inspired by
[SpaceMonger 1.4](https://github.com/seanofw/spacemonger1) (a Windows/MFC tool). It is a from-scratch
reimplementation, not a port — see the README's "Inspiration" section for what was and wasn't carried
over from the original (notably: the treemap layout algorithm, block-size rounding, and
trash-not-permanent-delete behavior).

## Commands

Build tooling: [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates the `.xcodeproj` from
`project.yml` — the project file itself is also committed, so `xcodegen generate` is only needed after
editing `project.yml` (e.g. adding a source file target, changing the bundle ID, bumping the deployment
target).

```sh
# Regenerate the Xcode project after changing project.yml
xcodegen generate

# Build (Debug) from the command line, unsigned — useful for CI/agent verification
xcodebuild -project Spacemonger-Mac.xcodeproj -scheme SpaceMonger -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Build a Release .app
xcodebuild -project Spacemonger-Mac.xcodeproj -scheme SpaceMonger -configuration Release build CODE_SIGNING_ALLOWED=NO -derivedDataPath ./build

# Open in Xcode to run/debug interactively (⌘R)
open Spacemonger-Mac.xcodeproj

# Run the unit tests (TreemapLayout + FolderNode pure-logic coverage)
xcodebuild -project Spacemonger-Mac.xcodeproj -scheme SpaceMonger -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

The `SpaceMongerTests` target hosts against the app binary (`TEST_HOST`/`BUNDLE_LOADER` point at
`Spacemonger-Mac.app`, not the target's own name `SpaceMonger` — XcodeGen's default assumes those match,
which they don't here since `PRODUCT_NAME` overrides the app's name). No linter is configured.

Distribution builds need entitlements applied (App Sandbox — see below), which `CODE_SIGNING_ALLOWED=NO`
skips. Sign locally with:

```sh
codesign --force --sign - --entitlements Sources/SpaceMonger/SpaceMonger.entitlements path/to/Spacemonger-Mac.app
```

The scheme is named `SpaceMonger` (an internal leftover identifier from before the app was renamed to
Spacemonger-Mac) — use that scheme name in `-scheme` flags regardless of the product/app name.

## Architecture

The app is a single-window SwiftUI app with one data flow: scan a folder into an in-memory tree, lay
that tree out as nested rectangles, render it, and let the user zoom/delete interactively. Reading
`FolderScanner.swift` → `FolderNode.swift` → `TreemapLayout.swift` → `TreemapView.swift` in that order
follows the actual data pipeline.

- **`FolderNode.swift`** — The tree model. A `FolderNode` is a file or folder with a size (rounded up
  to the volume's allocation block size for files; the sum of children for folders) and a `weak var
  parent` back-reference. `removeFromParent()` handles the bookkeeping needed after a delete: it
  subtracts the deleted node's size from every ancestor up the chain, since `FolderNode` is a reference
  type and SwiftUI won't pick up in-place mutations on its own (see `TreemapView`'s `refreshTick`
  workaround below).

- **`FolderScanner.swift`** — Recursive filesystem walker (`FileManager`-based, runs off the main
  thread via `Task.detached`). Two boundary checks exist here that are easy to accidentally regress:
  it will not cross into a different volume (`crossesVolumeBoundary`, compared via `stat().st_dev`,
  same idea as `find -xdev`) and will not descend into a directory containing a `.nofollow` marker file
  (the convention FUSE-backed cloud-sync mounts like Google Drive use to opt out of traversal). Both
  exist because without them the scanner will happily crawl into mounted cloud/network volumes nested
  under the scan root, which is slow and not representative of local disk usage. Symlinks and alias
  files are also skipped outright to avoid loops.

- **`TreemapLayout.swift`** — Pure function, no SwiftUI/AppKit dependency: `TreemapLayout.layout(root:in:settings:)`
  turns a `FolderNode` + a `CGRect` into a flat `[DisplayRect]`. The algorithm is **not** the
  "squarified" treemap algorithm most modern treemap libraries use — it's a recursive greedy bisection
  ported from the original's `SizeFolders`/`BuildFolderLayout`: split children into two groups of
  roughly equal total size (they arrive pre-sorted descending by size, so greedy assignment is enough),
  split the rectangle along whichever axis best matches the current aspect ratio (nudged by
  `LayoutSettings.bias`), recurse into each half. `LayoutSettings.minWidth`/`minHeight` control when a
  box is too small to keep subdividing and becomes a single leaf block instead. The recursive split
  happens *before* that size check runs on each half, so a too-small box can end up representing more
  than one sibling at once — `DisplayRect.representedCount`/`representedSize` describe what a box
  actually stands for (vs. `node`, which is just the largest item in the group), and `isSingleItem`
  is false whenever a box shouldn't be treated as one identified file/folder (its label becomes "N
  items", and `TreemapView` won't offer to delete it).

- **`TreemapView.swift`** — Renders the `[DisplayRect]`s onto a single `Canvas`, and owns interaction:
  tap-to-zoom, hover tooltip, right-click → Move to Trash (via `FileManager.trashItem`, i.e. reversible,
  matching the original's `FOF_ALLOWUNDO` behavior — never a permanent delete). Tap-to-zoom, hover, and
  the context menu are deliberately all attached to the *same* view layer (`.contentShape(Rectangle())`
  chained directly onto the `Canvas`) rather than split across an overlay — an earlier version put the
  hover-tracking layer in a separate `.overlay {}` and it silently ate every tap before the `Canvas`'s
  own gesture could see it. Because `FolderNode` is a class, deleting a node mutates the tree in place;
  `refreshTick` is a dummy `@State` bumped after every delete purely to force SwiftUI to recompute
  `rects` on the next render.

  Before actually trashing anything, `validationFailureReason(for:at:)` re-checks the target against
  what was scanned: rejects if the leaf became a symlink (via `lstat`, not a resource-value lookup that
  could resolve through it), if its type changed, if its (device, inode) pair captured at scan time no
  longer matches (catches a same-type same-name replacement, which a type/size check alone can't), and
  confirms the resolved real path is still a path-component-wise descendant of the scanned root (not a
  string-prefix check — at the volume root `/`, concatenating `"/"` produces `"//"` and breaks every
  real child path). Only a box with `representedCount == 1` (`isSingleItem`) offers delete at all — see
  below.

- **`ContentView.swift`** — App shell: toolbar (Open/Reload/Zoom Full/Free Space toggle/About), the
  path+volume-space header line, and the scan-state switch (`idle` / `scanning` / `done` / `failed`).
  Owns `zoomedNode` and passes it down to `TreemapView` as a binding. Owns the scan itself as a
  cancellable `Task` plus a `scanGeneration` counter: starting a new scan (Open or Reload) cancels
  whatever was already running and bumps the generation, and every callback checks its captured
  generation against the current one before touching `scanState` — without this, a superseded scan's
  late-arriving completion could clobber a newer scan's results. Each scan gets its own `FolderScanner`
  instance rather than reusing one across scans.

- **`BoxColors.swift`** — Fixed 8-color palette cycled by depth (`depth % palette.count`), matching the
  original's `BoxColors` table. `TreemapView` colors a folder's own box using `depth + 1` so that the
  always-visible top header bar (always palette index 0 / red) never collides with the color of the
  folder immediately below it.

## Non-obvious behavior worth knowing before changing scan/layout code

- Sizes are `UInt64` bytes throughout, rounded up to a 4096-byte block size on file sizes (there's no
  real "cluster size" concept on APFS/HFS+ the way there was on the original's FAT/NTFS targets, so
  4096 is a fixed stand-in, not detected per-volume).
- The Free Space toggle doesn't remove the synthetic "Free Space" node from the tree — it's excluded
  from the layout's size split only when `LayoutSettings.showFreeSpace == false`
  (`TreemapLayout.sizeFolders`), mirroring the original's `showfreespace` flag.
- `FolderNode.path` reconstructs a node's ancestor-name chain by walking `parent` pointers; it does
  *not* include the volume/root URL. Full filesystem paths are only resolved where needed (e.g.
  `TreemapView.fileURL(for:)` for delete) by joining `rootURL` (kept separately in `ContentView`) with
  `node.path.dropFirst()`.
- `FolderScanner.crossesVolumeBoundary` fails *closed*: if `stat()` can't establish a directory's
  device identity at all, it's treated as a boundary and skipped, not silently let through.
- A directory that can't be enumerated (permission denied, vanished mid-scan) is still treated as
  empty rather than erroring out the whole scan, but it's counted
  (`FolderScanner.inaccessibleDirectoryCount`) and surfaced in `ContentView`'s header line — don't
  drop that count silently if you touch this path, since it's the only signal the user gets that a
  scan might be incomplete.
- The app runs under App Sandbox (`Sources/SpaceMonger/SpaceMonger.entitlements`, only
  `files.user-selected.read-write`) — it can only touch whatever the user picked via the `NSOpenPanel`
  in `pickFolder()` plus its subtree. Don't add filesystem access outside that flow without adding the
  matching entitlement.
