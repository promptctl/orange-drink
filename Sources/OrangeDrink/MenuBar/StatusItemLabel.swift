import SwiftUI

/// What the status item shows: the chosen icon for a reading, or a symbol that says why there is
/// none, so a missing battery or a dead subscription is never a stale percentage.
enum StatusItemContent: Equatable {
    case icon(MenuBarIcon)
    case symbol(String)

    init(_ state: BatteryModel.State, _ config: MenuBarIconConfig, on bar: MenuBarIcon.Bar) {
        self = switch (state, config.style) {
        case (.known(let reading?), _): .icon(MenuBarIcon(reading, config, on: bar))
        // A Mac with no battery still shows the logo it chose, with nothing in it.
        case (.known(nil), .logo): .icon(MenuBarIcon(noBattery: config, on: bar))
        case (.unknown, _): .symbol("battery.0percent")
        case (.known(nil), _): .symbol("powerplug")
        case (.ended, _): .symbol(MacBattery.stoppedGlyph)
        }
    }

    var halo: Halo? { if case .icon(let icon) = self { icon.halo } else { nil } }
}

struct StatusItemLabel: View {
    let state: BatteryModel.State
    let icon: MenuBarIconModel
    let language: AppLanguageModel
    let halo: StatusItemHalo
    /// The menu bar's own appearance, which the glyph's "automatic" colour matches.
    @Environment(\.colorScheme) private var barScheme

    /// What this label shows on a bar: the single place the saved choices meet the battery's state.
    func content(on bar: MenuBarIcon.Bar) -> StatusItemContent {
        StatusItemContent(state, icon.value, on: bar)
    }

    var body: some View {
        let content = content(on: barScheme == .dark ? .dark : .light)
        Group {
            switch content {
            case .icon(let icon): Image(nsImage: icon.image)
            case .symbol(let name): Image(systemName: name)
            }
        }
        // The bar shows the label as a still image, so the halo's animation lives on the button's own layer.
        .onChange(of: content.halo, initial: true) { _, wanted in halo.show(wanted) }
        .accessibilityLabel(StatusItemName(state, appName: appName).phrase.text(in: language.value))
    }
}
