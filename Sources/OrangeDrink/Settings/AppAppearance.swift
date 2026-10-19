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

extension ColorScheme {
    func pick<T>(light: T, dark: T) -> T { self == .dark ? dark : light }
}

/// [LAW:one-source-of-truth] A colour that is `light` or `dark` by the SwiftUI colour scheme, the same
/// environment `Color.primary` and `veil` follow, so a surface and the text on it cannot disagree.
struct AdaptiveColor: View {
    let light: Color
    let dark: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View { scheme.pick(light: light, dark: dark) }
}

extension Color {
    /// A wash of the text colour over the surface: the faint lift cards, tracks and buttons have in
    /// either appearance (white on dark, black on light).
    static func veil(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
}
