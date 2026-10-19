import SwiftUI

extension MenuBarIconConfig.Style {
    func title(appName: String) -> Phrase {
        switch self {
        case .batteryIndicator: "Battery Indicator"
        case .minimal: "Minimal"
        case .logo: "\(appName) Logo"
        }
    }

    /// design-docs/menu-bar.md's descriptions.
    func description(appName: String) -> Phrase {
        switch self {
        case .batteryIndicator: "Shows battery level and charging status – \(appName)'s opinionated design"
        case .minimal: "Minimalistic iPhone-style battery indicator"
        case .logo: "Static \(appName) logo icon"
        }
    }
}

extension MenuBarIconConfig.Display {
    var title: Phrase {
        switch self {
        case .percentage: "Percentage"
        case .timeRemaining: "Time Remaining"
        case .iconOnly: "Icon Only"
        }
    }
}

extension MenuBarIconConfig.Color {
    var title: Phrase {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

extension MenuBarIconConfig.Size {
    var title: Phrase {
        switch self {
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}

/// design-docs/menu-bar.md: the icon's style and dressing, and a live preview of the result.
struct MenuBarScreen: View {
    let model: MenuBarIconModel
    let devices: DevicesModel
    let deviceSettings: DeviceSettingsModel
    @State private var saveFailure: String?
    @Environment(\.appLanguage) private var language

    var body: some View {
        let config = model.value
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "macwindow", color: .cyan, title: "Menu Bar Icon")
            if let saveFailure {
                Label("Could not save: \(saveFailure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            SettingCard {
                ForEach(MenuBarIconConfig.Style.allCases, id: \.self) { style in
                    RadioRow(title: style.title(appName: appName), description: style.description(appName: appName), isSelected: config.style == style) {
                        perform { $0.style = style }
                    }
                }
                Group {
                    SettingRow(icon: ("checklist", .purple), title: "Display", description: "Choose what to display in the menu bar icon") {
                        PopUpButton(selection: Binding(get: { config.renderedDisplay }, set: { display in perform { $0.display = display } }), options: config.style.displays, title: { $0.title.text(in: language) })
                    }
                    SettingRow(icon: ("circle.lefthalf.filled", .orange), title: "Color", description: "Match your menu bar style") {
                        PopUpButton(selection: binding(\.color), options: MenuBarIconConfig.Color.allCases, title: { $0.title.text(in: language) })
                    }
                    SettingRow(icon: ("textformat.size", .blue), title: "Size", description: "Make the icon and its text larger and easier to read") {
                        PopUpButton(selection: binding(\.size), options: MenuBarIconConfig.Size.allCases, title: { $0.title.text(in: language) })
                    }
                    SettingRow(icon: ("paintpalette.fill", .green), title: "Status colors",
                               description: "Green when charging, orange for low battery. Off keeps the icon neutral and only turns it red when critical.") {
                        AccentSwitch(isOn: binding(\.statusColors), tint: .indigo, label: "Status colors")
                    }
                }
                .padding(.leading, 12)
            }
            Text("Preview").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            MenuBarPreview(config: config).frame(maxWidth: .infinity)
            PinnedDevicesCard(devices: devices, settings: deviceSettings).padding(.top, 16)
        }
        .padding(24)
        .background(SettingsBackground())
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MenuBarIconConfig, Value>) -> Binding<Value> {
        Binding(get: { model.value[keyPath: keyPath] }, set: { value in perform { $0[keyPath: keyPath] = value } })
    }

    /// [LAW:no-silent-failure] A change that cannot be kept is shown, not dropped.
    private func perform(_ edit: (inout MenuBarIconConfig) -> Void) {
        do {
            try model.update(edit)
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
        }
    }
}

/// A mockup of the top of a Mac's screen with the app's icon on a dark menu bar, drawn from the
/// choices exactly as the status item draws them, and the two tips for finding and clearing icons.
struct MenuBarPreview: View {
    let config: MenuBarIconConfig
    @Environment(\.appLanguage) private var language

    /// The sample the preview shows: 75% and charging with 1:22 to go, so every Display value has
    /// something to print and the Status colors switch has a colour to turn on and off.
    static let samplePercent = 75
    static let samplePower = PowerSource.adapter(nil, .charging(timeToFull: .seconds(82 * 60)))

    /// [LAW:one-source-of-truth] The same `MenuBarIcon` the status item is made of, handed the
    /// sample and the mockup's own dark bar.
    static func icon(_ config: MenuBarIconConfig) -> MenuBarIcon {
        MenuBarIcon(BatteryIndicator(percent: samplePercent, power: samplePower, display: config.renderedDisplay, statusColors: config.statusColors),
                    config, on: .dark)
    }

    private static let size = CGSize(width: 270, height: 190)

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.25, blue: 0.18), Color(red: 0.02, green: 0.08, blue: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.35)).frame(height: 22)
            HStack {
                Image(systemName: "apple.logo").font(.system(size: 11)).foregroundStyle(.white)
                Spacer()
                Image(nsImage: Self.icon(config).image)
            }
            .padding(.horizontal, 10).frame(height: 22)
            Arrow().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: Self.size.width, height: Self.size.height)
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                tip(1, "Control \(appName) from the menu bar", "Don't see it?", glyph: "questionmark.circle", help: Self.overflowHelp)
                tip(2, "Remove default battery icon from menu bar", "Click to see quick tutorial", glyph: "questionmark.circle", help: Self.tutorialHelp)
            }
            .padding(10)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark) // the mockup is a fixed dark scene, whatever the app looks like
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(("Menu bar preview" as Phrase).text(in: language))
    }

    static let overflowHelp: Phrase = "If you can't find the icon, your menu bar may be full: macOS hides the icons that don't fit, or that land behind the notch. Quit or move other menu bar apps to make room, or hold ⌘ and drag icons you don't need out of the bar."
    static let tutorialHelp: Phrase = "Open System Settings → Control Center, find Battery, and turn off “Show in Menu Bar” to remove the system's own battery icon."

    private func tip(_ number: Int, _ title: Phrase, _ hint: Phrase, glyph: String, help: Phrase) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                PhraseText(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 3) {
                    PhraseText(hint).font(.system(size: 9)).foregroundStyle(.secondary)
                    InfoButton(text: help, glyph: glyph, label: hint).font(.system(size: 9))
                }
            }
        }
    }
}

/// A hand-drawn arrow curving up from the lower middle to the icon in the bar.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let start = CGPoint(x: rect.width * 0.5, y: rect.height * 0.62)
        let tip = CGPoint(x: rect.width - 24, y: 30)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: tip, control: CGPoint(x: rect.width * 0.9, y: rect.height * 0.62))
        path.move(to: CGPoint(x: tip.x - 6, y: tip.y + 8))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + 6, y: tip.y + 8))
        return path
    }
}
