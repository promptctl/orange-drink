import SwiftUI

@main
struct OrangeDrinkApp: App {
    var body: some Scene {
        MenuBarExtra("OrangeDrink", systemImage: "cup.and.saucer.fill") {
            Button("Quit OrangeDrink") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
