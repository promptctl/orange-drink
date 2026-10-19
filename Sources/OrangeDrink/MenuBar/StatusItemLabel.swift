import SwiftUI

/// The menu bar icon: the Battery Indicator for a reading, and a symbol that says why there is
/// none otherwise, so a missing battery or a dead subscription is never a stale percentage.
struct StatusItemLabel: View {
    let state: BatteryModel.State

    var body: some View {
        switch state {
        case .known(let reading?): Image(nsImage: BatteryIndicator(reading).image)
        case .unknown: Image(systemName: "battery.0percent")
        case .known(nil): Image(systemName: "powerplug")
        case .ended: Image(systemName: "exclamationmark.triangle")
        }
    }
}
