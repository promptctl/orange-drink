import SwiftUI

extension Color {
    /// A wash of the text colour over the surface: the faint lift cards, tracks and buttons have in
    /// either appearance (white on dark, black on light).
    static func veil(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
}
