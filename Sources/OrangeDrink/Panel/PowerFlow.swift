import Foundation

/// The Power Flow diagram for one reading: where the adapter's power goes.
///
/// [LAW:types-are-the-program] There is no diagram without an adapter and its telemetry, so it
/// is made or it is nil; no view draws a half-known one.
struct PowerFlow: Equatable {
    struct Band: Equatable {
        let label: String
        /// This band's share of the diagram's full width, 0...1; the two bands are in the
        /// proportion of the watts they carry.
        let share: Double
    }

    /// "59W": the adapter's rating, absent when the adapter reports none.
    let charger: String?
    let battery: Band
    let system: Band
    /// "Charging at 10 W" while charge flows into the battery.
    let caption: Phrase
    /// A plain-language class for the system's draw.
    let workload: Phrase

    init?(_ reading: BatteryReading) {
        guard case .adapter(let rating, let charging) = reading.power, let input = reading.systemPowerIn else { return nil }
        let toBattery = max(0, reading.batteryPower.value)
        let toSystem = max(0, input.value - toBattery)
        // Bands are drawn against the rating, or against what flows when the adapter gives none
        // or the telemetry reads above it, so the two never add up to more than the whole.
        let whole = max(rating?.value ?? 0, toBattery + toSystem)
        charger = rating.map { "\(Int($0.value.rounded()))W" }
        battery = Band(label: String(format: "%.1f W", toBattery), share: whole == 0 ? 0 : toBattery / whole)
        system = Band(label: String(format: "%.1f W", toSystem), share: whole == 0 ? 0 : toSystem / whole)
        if case .charging = charging {
            caption = "Charging at \(Int(toBattery.rounded())) W"
        } else {
            caption = "Not charging"
        }
        workload = Self.workload(watts: toSystem)
    }

    /// Where the system's draw falls, from a Mac at rest to one working flat out.
    static func workload(watts: Double) -> Phrase {
        switch watts {
        case ..<8: "Idle: little running"
        case ..<25: "Light workload: browsing or documents"
        case ..<60: "Active workload: multitasking or media"
        default: "Heavy workload: editing, building, or gaming"
        }
    }
}
