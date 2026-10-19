import SwiftUI

// [LAW:one-source-of-truth] project.yml's `name` is the app's name; CFBundleName derives from
// it, and the generated Info.plist always carries it, so absence here is a broken build, not
// a case to default past.
private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String

@main
struct OrangeDrinkApp: App {
    @State private var battery = BatteryModel(readings: BatteryMonitor.readings())

    var body: some Scene {
        MenuBarExtra(appName, systemImage: "cup.and.saucer.fill") {
            Button("Quit \(appName)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
