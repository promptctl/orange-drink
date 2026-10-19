import SwiftUI

/// The three-part flow chart: the charger on the left, the battery and the laptop on the
/// right, and a band from the charger to each as thick as the power it carries.
struct PowerFlowView: View {
    let flow: PowerFlow

    private let tile: CGFloat = 54, gap: CGFloat = 6, run: CGFloat = 90

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text("Power Flow").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 0) {
                Tile(symbol: "powerplug.fill", text: flow.charger, tint: .primary)
                    .frame(width: tile, height: tile * 2 + gap)
                bands
                VStack(spacing: gap) {
                    Tile(symbol: "battery.100.bolt", text: nil, tint: .green).frame(width: tile, height: tile)
                    Tile(symbol: "laptopcomputer", text: nil, tint: .secondary).frame(width: tile, height: tile)
                }
            }
            VStack(spacing: 2) {
                Label(flow.caption, systemImage: "bolt.fill").font(.callout).foregroundStyle(.green)
                Text(flow.workload).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The tile heights are the whole width of the bands: a band is `share` of them, centred on its tile.
    private var bands: some View {
        let height = tile * 2 + gap
        return Canvas { context, size in
            func ribbon(to y: CGFloat, share: Double, color: Color) {
                guard share > 0 else { return }
                let thickness = max(2, (height / 2 - 4) * 2 * share)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: height / 2))
                path.addCurve(to: CGPoint(x: size.width, y: y),
                              control1: CGPoint(x: size.width / 2, y: height / 2), control2: CGPoint(x: size.width / 2, y: y))
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: thickness)
            }
            ribbon(to: tile / 2, share: flow.battery.share, color: .green)
            ribbon(to: tile * 1.5 + gap, share: flow.system.share, color: .gray)
        }
        .overlay(alignment: .topLeading) { Text(flow.battery.label).font(.caption.monospaced()).foregroundStyle(.green).offset(x: 24, y: 4) }
        .overlay(alignment: .bottomLeading) { Text(flow.system.label).font(.caption.monospaced()).foregroundStyle(.secondary).offset(x: 24, y: -4) }
        .frame(maxWidth: .infinity).frame(height: height)
    }
}

private struct Tile: View {
    let symbol: String
    let text: String?
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            if let text { Text(text).font(.caption.monospaced().bold()) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
