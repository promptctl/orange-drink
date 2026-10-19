import SwiftUI

/// How the app looks: the General screen's App Appearance. Auto follows the Mac; Light and Dark hold
/// the settings window and the panel in that appearance whatever the Mac is set to.
enum AppAppearance: String, Stored, CaseIterable {
    static let storageKey = "app.appearance"

    case auto = "Auto", light = "Light", dark = "Dark"

    init() { self = .auto }

    /// [LAW:one-source-of-truth] What SwiftUI is told for this choice; `nil` hands the decision back to
    /// the system. The window and the panel both read it here, so the two cannot disagree.
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

typealias AppAppearanceModel = StoredModel<AppAppearance>

extension Color {
    /// A colour that is `light` under a light appearance and `dark` under a dark one.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    /// A wash of the text colour over the surface: the faint lift cards, tracks and buttons have in
    /// either appearance (white on dark, black on light).
    static func veil(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
}
