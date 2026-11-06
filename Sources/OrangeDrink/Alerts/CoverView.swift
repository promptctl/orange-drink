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
    private(set) var content: CoverContent
    /// How many times the cover has come into sight; each time, VoiceOver is moved to Dismiss.
    private(set) var seen = 0
    init(_ content: CoverContent) { self.content = content }

    func cameIntoSight() { seen += 1 }

    /// Every write redraws every display, so content equal to what is shown is not written.
    /// - Returns: whether the cover changed.
    @discardableResult func show(_ new: CoverContent) -> Bool {
        guard new != content else { return false }
        content = new
        return true
    }
}

/// The full-screen alert of design-docs/alerts.md: a dark translucent cover with the charge ring,
/// the headline, its second line, and one "Dismiss" button centred on it.
struct CoverView: View {
    private static let ring: CGFloat = 14

    let shown: CoverShown
    /// The primary display's cover, which holds keyboard focus, takes VoiceOver's too.
    let takesVoiceOverFocus: Bool
    let onDismiss: () -> Void
    @Environment(\.appLanguage) private var language
    @AccessibilityFocusState private var dismissFocused: Bool

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
                .accessibilityFocused($dismissFocused)
                .padding(.top, 12)
            }
        }
        // VoiceOver hears the headline and second line from the controller's announcement, then lands here.
        // A cover drawn behind the lock screen waits to be seen. Each time it is seen, focus is let go
        // and taken again, as writing true over true would not move VoiceOver.
        .onAppear { dismissFocused = takesVoiceOverFocus && shown.seen > 0 }
        .onChange(of: shown.seen) {
            dismissFocused = false
            Task { @MainActor in dismissFocused = takesVoiceOverFocus }
        }
    }
}

/// The cover's second line. While macOS recalculates its estimate there is none, and an invisible
/// estimate in the same language and font holds its place, so the headline does not move between readings.
struct CoverSubline: View {
    static let stand: Phrase = PillContent.untilEmpty("9min")

    let subline: Phrase?
    @Environment(\.appLanguage) private var language

    var body: some View {
        (subline ?? Self.stand).text(in: language).font(.system(size: 22)).foregroundStyle(.white.opacity(0.65))
            .opacity(subline == nil ? 0 : 1)
            .accessibilityHidden(subline == nil)
    }
}
