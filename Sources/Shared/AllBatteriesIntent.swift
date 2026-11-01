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

/// Which devices an All Batteries widget draws. The raw values are what a placed widget's settings save.
enum WidgetDeviceChoice: String, CaseIterable, AppEnum {
    case automatic, custom, sameAsMenuBar

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Devices"
    static let caseDisplayRepresentations: [WidgetDeviceChoice: DisplayRepresentation] = [.automatic: "Automatic", .custom: "Custom", .sameAsMenuBar: "Same as menu bar"]
}

/// What Edit Widget sets on a placed All Batteries widget.
struct AllBatteriesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "All Batteries"
    static let description = IntentDescription("How this widget draws your batteries.")
    static let isDiscoverable = false

    @Parameter(title: "Devices", default: .automatic) var devices: WidgetDeviceChoice
    @Parameter(title: "Chosen devices") var chosen: [DeviceEntity]?
    @Parameter(title: "Style", default: .rings) var style: WidgetStyle
    @Parameter(title: "Show device names", default: false) var showNames: Bool
    @Parameter(title: "Include this Mac", default: true) var includeMac: Bool
    @Parameter(title: "Appearance", default: .color) var appearance: WidgetAppearance

    /// Edit Widget offers the chosen devices only to Custom, the one choice that reads them. An option either arm leaves
    /// out is gone from Edit Widget for that arm, and `When` needs its root and value spelled out to compile.
    static var parameterSummary: some ParameterSummary {
        When(\AllBatteriesIntent.$devices, .equalTo, WidgetDeviceChoice.custom) {
            Summary { \.$devices; \.$chosen; \.$style; \.$showNames; \.$includeMac; \.$appearance }
        } otherwise: {
            Summary { \.$devices; \.$style; \.$showNames; \.$includeMac; \.$appearance }
        }
    }
}

/// Which devices a placed widget lists. [LAW:types-are-the-program] Chosen addresses exist only on the choice that reads them.
enum WidgetDeviceSelection: Equatable, Sendable, CustomStringConvertible {
    /// As many as fit, in the panel's ranking.
    case automatic
    /// These addresses, in the user's order, each once.
    case custom([String])
    /// The devices pinned to the menu bar, in the bar's order.
    case sameAsMenuBar

    /// What the widget's log carries, which is public: how many were chosen, never their addresses.
    var description: String {
        switch self {
        case .automatic: "automatic"
        case .custom(let addresses): "custom \(addresses.count)"
        case .sameAsMenuBar: "sameAsMenuBar"
        }
    }
}

/// A placed All Batteries widget's settings, read once from what Edit Widget holds. [LAW:one-source-of-truth] A value,
/// because an intent's parameters are shared references, and made only from an intent, so the intent alone says the defaults.
struct AllBatteriesSettings: Equatable, Sendable {
    let devices: WidgetDeviceSelection
    let style: WidgetStyle
    let showNames: Bool
    let includeMac: Bool
    let appearance: WidgetAppearance

    init(_ intent: AllBatteriesIntent) {
        (style, showNames, includeMac, appearance) = (intent.style, intent.showNames, intent.includeMac, intent.appearance)
        var seen = Set<String>()
        devices = switch intent.devices {
        case .automatic: .automatic
        case .custom: .custom((intent.chosen ?? []).map(\.id).filter { seen.insert($0).inserted })
        case .sameAsMenuBar: .sameAsMenuBar
        }
    }

    /// One battery as these settings draw it. [LAW:dataflow-not-control-flow] Past here a name is a value, or none.
    func drawn(_ battery: WidgetBattery, named name: String) -> WidgetBattery {
        var drawn = battery
        (drawn.name, drawn.appearance) = (showNames ? name : nil, appearance)
        return drawn
    }
}
