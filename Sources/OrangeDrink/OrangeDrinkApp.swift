import SwiftUI

@main
struct OrangeDrinkApp: App {
    var body: some Scene {
        MenuBarExtra("OrangeDrink", systemImage: "battery.100percent") {
            Button("Quit OrangeDrink") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
