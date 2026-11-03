import AppKit

/// The status item for one reading and one set of choices: what shape is drawn and how.
///
/// [LAW:types-are-the-program] The two battery shapes cannot lack a reading; the logo's is optional
/// because a Mac with no battery still shows the logo, as an outline with nothing in it.
struct MenuBarIcon: Equatable {
    enum Shape: Equatable {
        /// The outline with the text printed inside it.
        case indicator(BatteryIndicator)
        /// The outline alone, with the text beside it.
        case minimal(BatteryIndicator)
        /// The glyph, filled to the charge and glowing while charging.
        case logo(MenuBarIconConfig.Glyph, BatteryIndicator?)
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
        let shape: Shape = switch config.style {
        case .batteryIndicator: .indicator(battery)
        case .minimal: .minimal(battery)
        case .logo: .logo(config.glyph, battery)
        }
        self.init(shape: shape, config, on: bar)
    }

    init(_ reading: BatteryReading, _ config: MenuBarIconConfig, on bar: Bar) {
        self.init(BatteryIndicator(reading, display: config.renderedDisplay, statusColors: config.statusColors), config, on: bar)
    }

    /// The logo on a Mac with no battery: the outline, empty.
    init(noBattery config: MenuBarIconConfig, on bar: Bar) {
        self.init(shape: .logo(config.glyph, nil), config, on: bar)
    }

    private init(shape: Shape, _ config: MenuBarIconConfig, on bar: Bar) {
        self.shape = shape
        color = config.color.ink(on: bar)
        size = config.size
    }

    var battery: BatteryIndicator? {
        switch shape {
        case .indicator(let battery), .minimal(let battery): battery
        case .logo(_, let battery): battery
        }
    }
}
