import CoreGraphics

/// The measures of the grid, and how many cells a row of it holds: what the up and down
/// arrows need to know. The same rule as SwiftUI's adaptive columns.
enum GridLayout {
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 14

    /// - Parameter width: of the grid, its padding included.
    static func columns(width: CGFloat, cellWidth: Double) -> Int {
        max(1, Int((width - 2 * padding + spacing) / (CGFloat(cellWidth) + spacing)))
    }
}
