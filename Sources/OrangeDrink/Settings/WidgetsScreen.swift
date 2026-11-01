import Observation
import SwiftUI
import WidgetKit

/// The sizes the Widgets screen's pills offer. [LAW:types-are-the-program] Its own type, because `WidgetFamily` also
/// holds sizes the pills don't: All Batteries' Extra Large, and the families of other platforms.
enum WidgetPreviewSize: CaseIterable {
    case small, medium, large

    var family: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        }
    }

    var title: Phrase {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The widget's size on the desktop.
    var points: CGSize {
        switch self {
        case .small: CGSize(width: 158, height: 158)
        case .medium: CGSize(width: 338, height: 158)
        case .large: CGSize(width: 338, height: 354)
        }
    }
}

/// What the Widgets screen previews, forgotten when the screen closes. An object, so a test presses a control and reads
/// what it did with no window, where a value in `@State` needs one.
@Observable @MainActor final class WidgetPreviewChoice {
    var kind = WidgetKind.allBatteries
    var size = WidgetPreviewSize.small
}

extension WidgetKind {
    fileprivate var symbol: String {
        switch self {
        case .allBatteries: "square.grid.2x2"
        case .macBattery: MacBattery.glyph
        case .deviceBattery: "earbuds"
        }
    }
}

/// One outlined capsule of the type picker.
struct WidgetTypeButton: View {
    let kind: WidgetKind
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                Text(kind.title)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.veil(isSelected ? 0.15 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.veil(isSelected ? 0.3 : 0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A widget as the desktop shows it: the real view at its real size, drawn from what the app has on hand for the shelf.
/// [LAW:one-source-of-truth] It holds the two values the shelf publishes, so it says what a placed widget says.
struct WidgetPreview: View {
    /// WidgetKit keeps this margin inside a widget.
    static let margin: CGFloat = 16

    let kind: WidgetKind
    let size: WidgetPreviewSize
    let mac: MacBattery
    let devices: WidgetDevices
    @Environment(\.appLanguage) private var language

    var body: some View {
        widget
            .padding(Self.margin)
            .frame(width: size.points.width, height: size.points.height)
            .background { AdaptiveColor(light: .white, dark: Color(white: 0.1)) }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.veil(0.1), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(("Widget preview" as Phrase).text(in: language))
    }

    @ViewBuilder var widget: some View {
        switch kind {
        case .allBatteries:
            AllBatteriesView(entry: AllBatteriesEntry(date: .now, mac: .success(.running(mac)), devices: .success(.running(devices)),
                                                      settings: AllBatteriesSettings(AllBatteriesIntent())),
                             appName: appName, family: size.family)
        case .macBattery:
            MacBatteryView(entry: MacBatteryEntry(date: .now, battery: .success(.running(mac))), appName: appName)
        case .deviceBattery:
            // Nothing here has a widget's settings, so it shows the device first in the widgets' ranking.
            DeviceBatteryView(entry: DeviceBatteryEntry(date: .now, shelf: .success(.running(devices)), chosen: WidgetDevices.choices(in: .running(devices)).first?.address),
                              appName: appName, family: size.family)
        }
    }
}

/// design-docs/widgets.md: a live preview of each widget, how to add one, and where its settings are. The widgets
/// themselves are set up in macOS's widget editor, so nothing here is saved.
struct WidgetsScreen: View {
    let battery: BatteryModel
    let devices: DevicesModel
    let settings: DeviceSettingsModel
    @State var choice = WidgetPreviewChoice()

    /// The type picker's order.
    private static let types: [WidgetKind] = [.allBatteries, .macBattery, .deviceBattery]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SettingsSectionHeader(symbol: "square.grid.2x2", color: .primary, title: "Widget Types")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("Live preview").font(.caption)
                    }
                    .foregroundStyle(.green)
                }
                typesCard
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "plus.square.on.square", color: .primary, title: "Add a Widget")
                SettingCard {
                    step(1, "Right-click your desktop and choose **Edit Widgets…**, or open Notification Center (click the clock) and scroll to the bottom.")
                    step(2, "Search for **\(appName)** and drag a widget wherever you like. Each size is its own entry in the gallery.")
                    step(3, "Right-click a placed widget → **Edit Widget** to choose devices, style and names. Click a widget to open \(appName).")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(symbol: "info.circle", color: .primary, title: "Good to Know")
                SettingCard {
                    SettingRow(icon: ("slider.horizontal.3", .gray), title: "Every widget has its own settings",
                               description: "Right-click a placed widget → Edit Widget. That's where you choose the devices, the style, names, and which device a Device Battery widget shows. Add the same widget twice with different settings if you like.") {
                        EmptyView()
                    }
                }
            }
        }
        .padding(24)
    }

    private var typesCard: some View {
        SettingCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(Self.types, id: \.self) { kind in
                        WidgetTypeButton(kind: kind, isSelected: choice.kind == kind) { choice.kind = kind }
                    }
                }
                SegmentedPills(selection: Bindable(choice).size, options: WidgetPreviewSize.allCases, accent: .gray, title: \.title)
                // [LAW:one-source-of-truth] The two derivations the shelf is published from, read here in `body` so each
                // reading and each change to the list redraws the preview.
                WidgetPreview(kind: choice.kind, size: choice.size, mac: MacBattery(battery.state), devices: WidgetDevices(devices.list, pinned: settings.value.pinned))
                    .frame(maxWidth: .infinity)
                // The design doc words this for All Batteries alone.
                if choice.kind == .allBatteries {
                    Divider()
                    allBatteriesExplanation
                }
            }
            .padding(16)
        }
    }

    private var allBatteriesExplanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Mac and all your devices in one widget. Small, medium, large and extra large: the bigger the size, the more devices fit.")
                .font(.callout).foregroundStyle(.secondary)
            Text("What you can modify (right-click the widget → Edit Widget):").fontWeight(.bold).padding(.top, 4)
            modification("ipad.and.iphone", "**Devices:** Automatic (as many as fit), Custom (your order), or Same as menu bar")
            modification("paintbrush", "**Style:** Rings, List or Bars")
            modification("textformat", "Show device names · Include this Mac")
            modification("circle.lefthalf.filled", "**Appearance:** Color or Monochrome")
        }
    }

    private func modification(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            Text(text).font(.callout)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(.cyan, in: Circle())
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(12)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 46) }
        .accessibilityElement(children: .combine)
    }
}
