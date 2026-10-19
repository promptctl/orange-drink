import SwiftUI

// [LAW:one-source-of-truth] project.yml's `name` is the app's name; CFBundleName derives from
// it, and the generated Info.plist always carries it, so absence here is a broken build, not
// a case to default past.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String

@main
struct OrangeDrinkApp: App {
    @State private var battery = BatteryModel(readings: BatteryMonitor.readings())
    @State private var sections = PanelSections()

    init() {
        #if DEBUG
        ComponentGallery.showIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(battery: battery, sections: sections)
        } label: {
            StatusItemLabel(state: battery.state, config: MenuBarIconConfig())
        }
        .menuBarExtraStyle(.window)

        Window("\(appName) Settings", id: SettingsWindow.id) { SettingsView() }
    }
}

enum SettingsWindow { static let id = "settings" }
