import Foundation

/// What the app calls a reading's power state: the panel's charge card, the Battery screen and the status
/// item's accessibility label all say it.
///
/// [LAW:one-source-of-truth] The one mapping from a power source to its name, so none of the three can word
/// a state differently from the others.
enum ChargeStatus: Equatable {
    case charging, onBattery, notCharging, charged

    init(_ power: PowerSource) {
        self = switch power {
        case .battery: .onBattery
        case .adapter(_, .charging): .charging
        case .adapter(_, .notCharging): .notCharging
        case .adapter(_, .full): .charged
        }
    }

    var title: Phrase {
        switch self {
        case .charging: "Charging"
        case .onBattery: "On Battery"
        case .notCharging: "Not Charging"
        case .charged: "Charged"
        }
    }

    /// Names the estimate under the percentage: time until full while on an adapter, until empty on battery.
    var estimateCaption: Phrase { self == .onBattery ? "UNTIL EMPTY" : "UNTIL FULL" }
}
