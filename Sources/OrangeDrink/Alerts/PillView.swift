import SwiftUI

extension Alert.Severity {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .green: .green
        }
    }
}

/// The capsule's outline from its left end, up and over the top, clockwise: the order the
/// progress stroke fills it in.
private struct PillOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r,
                    startAngle: .degrees(270), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        return path
    }
}

/// The alert pill of design-docs/general.md: near-black capsule, border as progress track,
/// battery, headline over sub-line, and a close button.
struct PillView: View {
    private static let border: CGFloat = 6

    let content: PillContent
    /// The multiple of the standard size the whole pill is drawn at.
    let scale: Double
    let onClose: () -> Void

    var body: some View {
        let color = content.severity.color
        HStack(spacing: 12) {
            PillBattery(color: color, level: content.progress)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.headline).font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                if let subline = content.subline {
                    Text(subline).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .light)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(Color(white: 0.25)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .frame(width: PillPlacement.size.width, height: PillPlacement.size.height)
        .background(Capsule().fill(Color(white: 0.06)))
        .overlay {
            let inset = Self.border / 2
            ZStack {
                PillOutline().stroke(Color(white: 0.22), lineWidth: Self.border)
                PillOutline().trim(from: 0, to: content.progress)
                    .stroke(color, style: StrokeStyle(lineWidth: Self.border, lineCap: .round))
            }
            .padding(inset)
        }
        // The pill is laid out at the standard size and scaled whole, so every part keeps its proportion.
        .scaleEffect(scale)
        .frame(width: PillPlacement.size.width * scale, height: PillPlacement.size.height * scale)
    }
}

/// A battery outline with a fill of the level in the severity colour.
private struct PillBattery: View {
    let color: Color
    let level: Double

    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1.5)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 1.5).fill(color)
                            .frame(width: max(2, (geometry.size.width - 4) * level))
                            .padding(2)
                    }
                }
                .frame(width: 26, height: 14)
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 6)
        }
    }
}
