import SwiftUI

/// Fixed palette cycling by depth, same idea as the original's BoxColors
/// table (a hand-picked cycle of pastel hues so sibling boxes are visually
/// distinct without any per-file-type logic).
enum BoxColors {
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.50, blue: 0.50),
        Color(red: 1.00, green: 0.75, blue: 0.50),
        Color(red: 1.00, green: 1.00, blue: 0.60),
        Color(red: 0.50, green: 1.00, blue: 0.50),
        Color(red: 0.50, green: 1.00, blue: 1.00),
        Color(red: 0.75, green: 0.75, blue: 1.00),
        Color(red: 0.75, green: 0.75, blue: 0.75),
        Color(red: 1.00, green: 0.50, blue: 1.00),
    ]

    static func color(depth: Int) -> Color {
        palette[depth % palette.count]
    }

    static let freeSpace = Color.gray.opacity(0.3)
}
