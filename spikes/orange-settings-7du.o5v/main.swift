import SwiftUI
import AppKit
import Carbon.HIToolbox

enum IOKitBattery { static let logSubsystem = "spike" }
enum NSPinnedStatusItem { static let buttonID = NSUserInterfaceItemIdentifier("pinned-device") }

@main struct S: App {
    let hk: OpenPanelHotKey
    var body: some Scene {
        MenuBarExtra("hk") { Text("panel").padding(40) }.menuBarExtraStyle(.window)
    }
    init() {
        hk = try! OpenPanelHotKey(hotKeys: CarbonHotKeys.shared(), panel: StatusItemPanel())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { press(1) } }
    }
}
@MainActor func press(_ n: Int) {
    print("open before press \(n): \(StatusItemPanel().isOpen)")
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_J), keyDown: down)!
        e.flags = [.maskControl, .maskAlternate]
        e.post(tap: .cghidEventTap)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
        print("open after press \(n): \(StatusItemPanel().isOpen)")
        if n < 2 { press(n + 1) } else { exit(0) }
    } }
}
