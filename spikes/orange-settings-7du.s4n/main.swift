import SwiftUI
import AppKit
import Carbon.HIToolbox

enum IOKitBattery { static let logSubsystem = "spike" }
enum NSPinnedStatusItem { static let buttonID = NSUserInterfaceItemIdentifier("pinned-device") }

@MainActor let defaults = UserDefaults(suiteName: "spike.s4n")!
@MainActor let sections = PanelSections(defaults: defaults)
@MainActor let keyboard = PanelKeyboard(sections: sections, events: NSKeyEvents())

@main struct S: App {
    let hk: OpenPanelHotKey
    var body: some Scene {
        MenuBarExtra("s4n") {
            Text("panel").padding(40)
                .onAppear { keyboard.panelDidOpen(shown: { [.batteryInformation, .connectedDevices] }) }
                .onDisappear { keyboard.panelDidClose() }
        }.menuBarExtraStyle(.window)
    }
    init() {
        defaults.removePersistentDomain(forName: "spike.s4n")
        hk = try! OpenPanelHotKey(hotKeys: CarbonHotKeys.shared(), panel: StatusItemPanel())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { post(kVK_ANSI_J, [.maskControl, .maskAlternate]); step(0) } }
    }
}

@MainActor func post(_ code: Int, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

@MainActor func state() -> String { "panel open=\(StatusItemPanel().isOpen) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")  batteryInformation=\(sections.isOpen(.batteryInformation)) connectedDevices=\(sections.isOpen(.connectedDevices))" }

// Letters are typed only while the panel is this app's key window, so they cannot land in another app.
let script: [(String, Int?)] = [("opened by the hot key", nil), ("press i", kVK_ANSI_I), ("press i again", kVK_ANSI_I), ("press d", kVK_ANSI_D), ("press d again", kVK_ANSI_D), ("press x (no shortcut)", kVK_ANSI_X), ("closed by the hot key", -1), ("reopened by the hot key", -2), ("press i after reopening", kVK_ANSI_I), ("press d after reopening", kVK_ANSI_D)]
@MainActor func step(_ n: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated {
        let code = n > 0 ? script[n].1 : nil
        // Letters are typed only while the panel is this app's key window.
        if let code, code > 0 {
            guard NSApp.keyWindow.map({ String(describing: type(of: $0)).hasPrefix("MenuBarExtraWindow") }) == true else { print("panel is not the key window; stopping"); exit(1) }
            post(code)
        } else if code != nil {
            post(kVK_ANSI_J, [.maskControl, .maskAlternate])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated {
            print("\(script[n].0): \(state())")
            if n + 1 < script.count { step(n + 1) } else {
                post(kVK_ANSI_J, [.maskControl, .maskAlternate])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { print("finally closed by the hot key: \(state())"); exit(0) } }
            }
        } }
    } }
}
