import AppKit

/// The status item for one reading and one set of choices: what shape is drawn and how.
///
/// [LAW:types-are-the-program] The logo has no battery state, so it carries none: a Logo icon
/// cannot be made to depend on the charge, and the two battery shapes cannot lack a fill.
struct MenuBarIcon: Equatable {
    enum Shape: Equatable {
        /// The outline with the text printed inside it.
        case indicator(BatteryIndicator)
        /// The outline alone, with the text beside it.
        case minimal(BatteryIndicator)
        case logo
    }

    let shape: Shape
    let color: MenuBarIconConfig.Color
    let size: MenuBarIconConfig.Size

    init(_ reading: BatteryReading, _ config: MenuBarIconConfig) {
        let battery = BatteryIndicator(reading, display: config.display, statusColors: config.statusColors)
        shape = switch config.style {
        case .batteryIndicator: .indicator(battery)
        case .minimal: .minimal(battery)
        case .logo: .logo
        }
        color = config.color
        size = config.size
    }

    /// The logo is the same at every charge, so it is made without a reading.
    init(logo config: MenuBarIconConfig) {
        shape = .logo
        color = config.color
        size = config.size
    }

    var battery: BatteryIndicator? {
        switch shape {
        case .indicator(let battery), .minimal(let battery): battery
        case .logo: nil
        }
    }
}
