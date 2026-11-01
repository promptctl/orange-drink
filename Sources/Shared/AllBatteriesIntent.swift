import AppIntents

// Compiled into the app and its widget extension, so a test reaches what a placed widget's settings hold.

/// How an All Batteries widget draws its batteries. The raw values are what a placed widget's settings save.
enum WidgetStyle: String, CaseIterable, AppEnum {
    case rings, list, bars

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [WidgetStyle: DisplayRepresentation] = [.rings: "Rings", .list: "List", .bars: "Bars"]
}

/// How a widget colours a charging battery. The raw values are what a placed widget's settings save.
enum WidgetAppearance: String, CaseIterable, AppEnum {
    case color, monochrome

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static let caseDisplayRepresentations: [WidgetAppearance: DisplayRepresentation] = [.color: "Color", .monochrome: "Monochrome"]
}

/// What Edit Widget sets on a placed All Batteries widget.
struct AllBatteriesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "All Batteries"
    static let description = IntentDescription("How this widget draws your batteries.")
    static let isDiscoverable = false

    @Parameter(title: "Style", default: .rings) var style: WidgetStyle
    @Parameter(title: "Show device names", default: false) var showNames: Bool
    @Parameter(title: "Include this Mac", default: true) var includeMac: Bool
    @Parameter(title: "Appearance", default: .color) var appearance: WidgetAppearance
}

/// A placed All Batteries widget's settings, read once from what Edit Widget holds. [LAW:one-source-of-truth] A value,
/// because an intent's parameters are shared references, and with no init of its own, so the intent alone says the defaults.
struct AllBatteriesSettings: Equatable, Sendable {
    let style: WidgetStyle
    let showNames: Bool
    let includeMac: Bool
    let appearance: WidgetAppearance

    init(_ intent: AllBatteriesIntent) {
        (style, showNames, includeMac, appearance) = (intent.style, intent.showNames, intent.includeMac, intent.appearance)
    }

    /// One battery as these settings draw it. [LAW:dataflow-not-control-flow] Past here a name is a value, or none.
    func drawn(_ battery: WidgetBattery, named name: String) -> WidgetBattery {
        WidgetBattery(glyph: battery.glyph, level: battery.level, charging: battery.charging, name: showNames ? name : nil, appearance: appearance)
    }
}
