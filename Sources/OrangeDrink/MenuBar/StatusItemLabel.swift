import SwiftUI

/// What the status item shows: the chosen icon for a reading, or a symbol that says why there is
/// none, so a missing battery or a dead subscription is never a stale percentage.
enum StatusItemContent: Equatable {
    case icon(MenuBarIcon)
    case symbol(String)

    init(_ state: BatteryModel.State, _ config: MenuBarIconConfig, on bar: MenuBarIcon.Bar) {
        self = switch (state, config.style) {
        // The logo has no battery state to be wrong about.
        case (_, .logo): .icon(MenuBarIcon(logo: config, on: bar))
        case (.known(let reading?), _): .icon(MenuBarIcon(reading, config, on: bar))
        case (.unknown, _): .symbol("battery.0percent")
        case (.known(nil), _): .symbol("powerplug")
        case (.ended, _): .symbol("exclamationmark.triangle")
        }
    }
}

struct StatusItemLabel: View {
    let state: BatteryModel.State
    let icon: MenuBarIconModel
    /// The menu bar's own appearance, which the glyph's "automatic" colour matches.
    @Environment(\.colorScheme) private var barScheme

    /// What this label shows on a bar: the single place the saved choices meet the battery's state.
    func content(on bar: MenuBarIcon.Bar) -> StatusItemContent {
        StatusItemContent(state, icon.value, on: bar)
    }

    var body: some View {
        Group {
            switch content(on: barScheme == .dark ? .dark : .light) {
            case .icon(let icon): Image(nsImage: icon.image)
            case .symbol(let name): Image(systemName: name)
            }
        }
        .accessibilityLabel(appName)
    }
}
