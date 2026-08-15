# Spacemonger-Mac

A native macOS disk-usage visualizer, built with Swift and SwiftUI.

## Inspiration

This project was inspired by [SpaceMonger](https://github.com/seanofw/spacemonger1) —
specifically SpaceMonger 1.4, a Windows disk-usage treemap tool whose source
code Sean Werkema (seanofw) published for digital preservation. SpaceMonger
was a great, fast, no-frills way to see what's eating your disk space, but it
never had a Mac version.

Spacemonger-Mac is not a fork or a line-for-line port — the original is
MFC/Win32 C++ with no Mac equivalent for its UI layer, so that part was
rebuilt from scratch in SwiftUI. What *was* carried over faithfully is the
core idea and the treemap layout algorithm: a recursive greedy bisection
(split children into two similarly-sized groups, split the rectangle along
whichever axis best fits the current aspect ratio, recurse) reimplemented in
`TreemapLayout.swift` from reading the original's `FolderView.cpp` /
`FolderTree.cpp`. Behaviors like rounding file sizes up to the volume's
allocation block size, skipping symlinks/mount points during a scan, and
sending deleted files to the Trash (not permanently removing them) also
mirror the original's approach.

License note: the original SpaceMonger 1.4 source is available for reference
under the terms in its own repository; no original source files are included
here.

## Features

- Recursive folder/volume scanning with live progress
- Treemap visualization (click a folder to zoom in, chevron/path bar to zoom out)
- Free Space toggle for whole-volume scans
- Right-click → Move to Trash on any file or folder
- Hover tooltip with exact byte count and modification date
- Skips mounted cloud/network volumes (Google Drive, OneDrive, etc.) and
  directories marked with a `.nofollow` sentinel, so scans don't wander off
  local disk

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Spacemonger-Mac.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project Spacemonger-Mac.xcodeproj -scheme SpaceMonger -configuration Release build
```
