/// The Menu Bar screen's choices: which icon, and how it is dressed. Each one is a value the
/// icon is drawn from; nothing in the drawing branches on where the value came from.
///
/// [LAW:one-source-of-truth] The settings screen (orange-settings-7du.rfu) edits this and the
/// status item draws from it, so the two cannot disagree about what a choice means.
struct MenuBarIconConfig: Equatable, Sendable {
    enum Style: Equatable, Sendable { case batteryIndicator, minimal, logo }
    /// What the icon prints beside or inside the battery. The logo prints nothing.
    enum Display: Equatable, Sendable { case percentage, timeRemaining, iconOnly }
    /// The glyph's own colour, chosen to match the menu bar: a light glyph for a dark bar.
    enum Color: Equatable, Sendable { case light, dark }
    enum Size: Equatable, Sendable, CaseIterable {
        case standard, large, extraLarge
        var scale: Double { switch self { case .standard: 1; case .large: 1.25; case .extraLarge: 1.5 } }
    }

    var style: Style = .batteryIndicator
    var display: Display = .percentage
    var color: Color = .light
    var size: Size = .standard
    /// Off keeps the icon neutral and turns it red only when critical.
    var statusColors = true
}
