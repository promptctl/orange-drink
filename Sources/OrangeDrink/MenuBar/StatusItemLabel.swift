import SwiftUI

/// The menu bar icon: the chosen style for a reading, and a symbol that says why there is
/// none otherwise, so a missing battery or a dead subscription is never a stale percentage.
struct StatusItemLabel: View {
    let state: BatteryModel.State
    let config: MenuBarIconConfig

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
