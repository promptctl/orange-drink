import SwiftUI

/// Everything the full-screen alert shows, decided before any view exists.
///
/// [LAW:one-source-of-truth] Its words are the pill's, built by `PillContent`, so the cover and the
/// pill an alert would otherwise show say the same thing.
struct CoverContent: Equatable, Sendable {
    let headline: Phrase
    /// nil when the pill would leave its second line out.
    let subline: Phrase?
    let severity: Alert.Severity
    /// How far the ring is filled: the remaining charge, 0...1.
    let progress: Double

    init(_ alert: Alert, reading: BatteryReading) {
        let pill = PillContent(alert, reading: reading)
        headline = pill.headline
        subline = pill.subline
        severity = pill.severity
        progress = pill.progress
    }
}

/// The content of the cover up, which every display's view reads, so a newer reading rewrites them all in place.
@MainActor @Observable final class CoverShown {
    var content: CoverContent
    init(_ content: CoverContent) { self.content = content }
}

/// The full-screen alert of design-docs/alerts.md: a dark translucent cover with the charge ring,
/// the headline, its second line, and one "Dismiss" button centred on it.
struct CoverView: View {
    private static let ring: CGFloat = 14

    let shown: CoverShown
    let onDismiss: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        let content = shown.content
        return ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Color(white: 0.22), lineWidth: Self.ring)
                    Circle().trim(from: 0, to: content.progress)
                        .stroke(content.severity.color, style: StrokeStyle(lineWidth: Self.ring, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 168, height: 168)
                .accessibilityHidden(true)
                content.headline.text(in: language).font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
                CoverSubline(subline: content.subline)
                Button(action: onDismiss) {
                    ("Dismiss" as Phrase).text(in: language).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 32).padding(.vertical, 12)
                        .background(Capsule().fill(Color(white: 0.25)))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
    }
}

/// The cover's second line. While macOS recalculates its estimate there is none, and an invisible line
/// of the same font holds its place, so the headline does not move between readings.
struct CoverSubline: View {
    let subline: Phrase?
    @Environment(\.appLanguage) private var language

    var body: some View {
        let line = subline.map { $0.text(in: language) } ?? Text(verbatim: " ")
        line.font(.system(size: 22)).foregroundStyle(.white.opacity(0.65))
            .opacity(subline == nil ? 0 : 1)
            .accessibilityHidden(subline == nil)
    }
}
