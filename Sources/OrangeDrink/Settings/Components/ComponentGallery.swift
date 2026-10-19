#if DEBUG
import AppKit
import SwiftUI

/// One of each shared settings component, in a window the UI tests drive through the accessibility
/// tree. Debug builds only, and only when launched with `-ComponentGallery`: no release build
/// carries it, and nothing else opens it.
struct ComponentGallery: View {
    enum Range: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }

    @State private var enabled = false
    @State private var size = "Default"
    @State private var range = Range.week
    @State private var radio = "First"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(symbol: "globe", color: .blue, title: "Section Title", info: "About this section")
            SettingCard {
                SettingRow(icon: ("power", .green), title: "Switch Row", description: "Switch description") {
                    AccentSwitch(isOn: $enabled, tint: .green, label: "Switch Row")
                }
                SettingRow(title: "Popup Row", description: "Popup description") {
                    PopUpButton(selection: $size, options: ["Default", "Large"], title: { Text($0) })
                }
                SettingRow(title: "Info Row", description: "Info description") { InfoButton(text: "Explains it") }
                SettingRow(title: "Pills Row", description: "Pills description") {
                    SegmentedPills(selection: $range, options: Range.allCases, accent: .indigo, title: { "\($0.rawValue)" })
                }
                ForEach(["First", "Second"], id: \.self) { option in
                    RadioRow(title: "\(option) Radio", description: "\(option) radio description", isSelected: radio == option) { radio = option }
                }
            }
        }
        .padding()
        .frame(width: 520)
        .background(SettingsBackground())
        .preferredColorScheme(.dark)
    }

    nonisolated static let launchArgument = "-ComponentGallery"

    /// Opens the gallery when the app was launched for it.
    @MainActor static func showIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Component Gallery"
        window.contentView = NSHostingView(rootView: ComponentGallery())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        // The app owns the window for its whole life; nothing else holds it.
        galleryWindow = window
    }

    @MainActor private static var galleryWindow: NSWindow?
}
#endif
