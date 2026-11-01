import AppIntents

// Compiled into the app and its widget extension, so a test reaches what a placed widget's settings hold.

/// How an All Batteries widget draws its batteries. The raw values are what a placed widget's settings save.
enum WidgetStyle: String, CaseIterable, AppEnum {
    case rings, list, bars

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [WidgetStyle: DisplayRepresentation] = [.rings: "Rings", .list: "List", .bars: "Bars"]
}

/// What Edit Widget sets on a placed All Batteries widget.
struct AllBatteriesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "All Batteries"
    static let description = IntentDescription("How this widget draws your batteries.")

    @Parameter(title: "Style", default: .rings) var style: WidgetStyle
}
