# Repository Guidelines

## Project Structure & Module Organization

Spacemonger-Mac is a macOS 14+ SwiftUI application. Production code lives in `Sources/SpaceMonger/`. The main data flow is `FolderScanner.swift` (filesystem traversal) → `FolderNode.swift` (in-memory tree) → `TreemapLayout.swift` (rectangle calculation) → `TreemapView.swift` (rendering and interaction). `ContentView.swift` provides the app shell, while `SpaceMongerApp.swift` is the entry point. App metadata is in `Info.plist`. Treat `project.yml` as the XcodeGen source of truth; `Spacemonger-Mac.xcodeproj` is generated and committed. There is currently no test or asset directory.

## Build, Test, and Development Commands

- `xcodegen generate` regenerates the Xcode project after changing targets, sources, or build settings in `project.yml`.
- `xcodebuild -project Spacemonger-Mac.xcodeproj -scheme SpaceMonger -configuration Debug build CODE_SIGNING_ALLOWED=NO` performs the standard local/CI verification build.
- `xcodebuild -project Spacemonger-Mac.xcodeproj -scheme SpaceMonger -configuration Release build CODE_SIGNING_ALLOWED=NO -derivedDataPath ./build` creates an unsigned release build under `build/`.
- `open Spacemonger-Mac.xcodeproj` opens the project for interactive development and debugging.

The scheme is `SpaceMonger`, even though the product name is Spacemonger-Mac.

## Coding Style & Naming Conventions

Follow existing Swift conventions: four-space indentation, one primary type per file, `UpperCamelCase` types, and `lowerCamelCase` properties and functions. Prefer `let`, early `guard` exits, and explicit access control for implementation details. Keep UI state changes on the main actor and filesystem scanning off the UI thread. Use `///` comments for public intent and short inline comments only for non-obvious behavior. No formatter or linter is configured, so preserve the style of surrounding code.

## Testing Guidelines

No automated test target or coverage threshold exists yet. Before submitting changes, run the unsigned Debug build and manually exercise folder selection, scan cancellation/progress, treemap zooming, the Free Space toggle, and Move to Trash where relevant. If adding tests, define a test target in `project.yml`, regenerate the project, and name files after the subject, for example `TreemapLayoutTests.swift`.

## Commit & Pull Request Guidelines

History is minimal and does not establish a strict convention. Use concise, imperative commit subjects such as `Fix volume boundary detection`, keeping each commit focused. Pull requests should explain the user-visible impact, list verification performed, link related issues, and include screenshots or a short recording for SwiftUI changes. Call out filesystem-safety changes explicitly; never replace Trash-based deletion with permanent removal or allow scans to follow symlinks, aliases, `.nofollow` directories, or other mounted volumes.
