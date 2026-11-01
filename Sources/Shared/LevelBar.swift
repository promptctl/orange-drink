import SwiftUI

/// A thin rounded bar on a dark track, filled to a fraction: the one level bar, in the panel and the widgets.
struct LevelBar: View {
    let fraction: Double, tint: Color

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.veil(0.12))
                Capsule().fill(tint).frame(width: bar.size.width * min(fraction, 1))
            }
        }
        .frame(height: 8)
    }
}

extension Color {
    /// A wash of the text colour over the surface: the faint lift cards, tracks and buttons have in
    /// either appearance (white on dark, black on light).
    static func veil(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
}
