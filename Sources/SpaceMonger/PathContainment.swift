import Foundation

/// Pure path-component containment check, split out from `TreemapView`'s
/// delete-time validation so it can be unit tested without touching the
/// filesystem. Deliberately compares path components rather than string
/// prefixes — concatenating a plain "/" onto a resolved root produces "//"
/// at the volume root, which fails a naive `hasPrefix` check for every real
/// child path.
enum PathContainment {
    static func isContained(_ target: [String], within root: [String]) -> Bool {
        target.starts(with: root)
    }
}
