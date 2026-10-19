import SwiftUI

/// A thin rounded bar on a dark track, filled to a fraction: the panel's one level bar.
struct LevelBar: View {
    let fraction: Double, tint: Color

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint).frame(width: bar.size.width * min(fraction, 1))
            }
        }
        .frame(height: 8)
    }
}
