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
