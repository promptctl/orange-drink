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

    /// The glyph's colour once it is settled: "automatic" is a choice, never a colour.
    enum Ink: Equatable { case light, dark }
    /// The menu bar the glyph is drawn on.
    enum Bar: Equatable { case light, dark }

    let shape: Shape
    let color: Ink
    let size: MenuBarIconConfig.Size

    /// [LAW:dataflow-not-control-flow] The status item and the Menu Bar screen's preview both draw
    /// through this one init, differing only in the indicator and the bar they hand it.
    init(_ battery: BatteryIndicator, _ config: MenuBarIconConfig, on bar: Bar) {
        shape = switch config.style {
        case .batteryIndicator: .indicator(battery)
        case .minimal: .minimal(battery)
        case .logo: .logo
        }
        color = config.color.ink(on: bar)
        size = config.size
    }

    init(_ reading: BatteryReading, _ config: MenuBarIconConfig, on bar: Bar) {
        self.init(BatteryIndicator(reading, display: config.display, statusColors: config.statusColors), config, on: bar)
    }

    /// The logo is the same at every charge, so it is made without a reading.
    init(logo config: MenuBarIconConfig, on bar: Bar) {
        shape = .logo
        color = config.color.ink(on: bar)
        size = config.size
    }

    var battery: BatteryIndicator? {
        switch shape {
        case .indicator(let battery), .minimal(let battery): battery
        case .logo: nil
        }
    }
}
