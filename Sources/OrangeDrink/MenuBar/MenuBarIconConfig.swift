/// The Menu Bar screen's choices: which icon, and how it is dressed. Each one is a value the
/// icon is drawn from; nothing in the drawing branches on where the value came from.
///
/// [LAW:one-source-of-truth] The settings screen edits this (through a `StoredModel`) and the
/// status item and the screen's preview draw from it, so none of them can disagree about what a
/// choice means. Stored by case name, never by the pop-up's title, so retitling or translating
/// the screen leaves what is on disk valid.
struct MenuBarIconConfig: Stored {
    static let storageKey = "menubar.icon"

    enum Style: String, Codable, Equatable, Sendable, CaseIterable {
        case batteryIndicator, minimal, logo

        /// The Display values this style renders; the logo prints nothing.
        var displays: [Display] {
            switch self {
            case .batteryIndicator, .minimal: Display.allCases
            case .logo: [.iconOnly]
            }
        }
    }
    /// What the icon prints beside or inside the battery. The logo prints nothing.
    enum Display: String, Codable, Equatable, Sendable, CaseIterable { case percentage, timeRemaining, iconOnly }
    /// The glyph's own colour. Automatic matches the menu bar it sits in, which only the status
    /// item knows when it draws: a light glyph for a dark bar and a dark one for a light bar.
    enum Color: String, Codable, Equatable, Sendable, CaseIterable {
        case automatic, light, dark

        func ink(on bar: MenuBarIcon.Bar) -> MenuBarIcon.Ink {
            switch (self, bar) {
            case (.light, _), (.automatic, .dark): .light
            case (.dark, _), (.automatic, .light): .dark
            }
        }
    }
    enum Size: String, Codable, Equatable, Sendable, CaseIterable {
        case standard, large, extraLarge
        var scale: Double { switch self { case .standard: 1; case .large: 1.25; case .extraLarge: 1.5 } }
    }

    var style: Style = .batteryIndicator
    var display: Display = .percentage
    var color: Color = .automatic
    var size: Size = .standard
    /// Off keeps the icon neutral and turns it red only when critical.
    var statusColors = true

    init() {}

    /// [LAW:parse-dont-validate] A field a later release adds is absent from what an earlier one
    /// stored; it decodes to its default instead of failing every existing install's launch.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(Style.self, forKey: .style) ?? style
        display = try values.decodeIfPresent(Display.self, forKey: .display) ?? display
        color = try values.decodeIfPresent(Color.self, forKey: .color) ?? color
        size = try values.decodeIfPresent(Size.self, forKey: .size) ?? size
        statusColors = try values.decodeIfPresent(Bool.self, forKey: .statusColors) ?? statusColors
    }

    /// The Display this style actually renders: the stored choice when it can, else the style's
    /// first. The stored choice is left alone, so returning to a battery style restores it.
    var renderedDisplay: Display { style.displays.contains(display) ? display : style.displays[0] }
}

typealias MenuBarIconModel = StoredModel<MenuBarIconConfig>
