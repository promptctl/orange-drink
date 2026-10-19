import SwiftUI

/// The menu bar icon: the chosen style for a reading, and a symbol that says why there is
/// none otherwise, so a missing battery or a dead subscription is never a stale percentage.
struct StatusItemLabel: View {
    let state: BatteryModel.State
    /// The menu bar's own appearance: a dark bar takes a light glyph and a light bar a dark one.
    @Environment(\.colorScheme) private var barScheme

    /// The choices in force. Until the Menu Bar screen supplies saved ones these are the defaults,
    /// with the glyph's colour matched to the bar it sits in.
    private var config: MenuBarIconConfig {
        var config = MenuBarIconConfig()
        config.color = barScheme == .dark ? .light : .dark
        return config
    }

    var body: some View {
        if config.style == .logo {
            Image(nsImage: MenuBarIcon(logo: config).image)
        } else {
            battery
        }
    }

    @ViewBuilder private var battery: some View {
        switch state {
        case .known(let reading?): Image(nsImage: MenuBarIcon(reading, config).image)
        case .unknown: Image(systemName: "battery.0percent")
        case .known(nil): Image(systemName: "powerplug")
        case .ended: Image(systemName: "exclamationmark.triangle")
        }
    }
}
