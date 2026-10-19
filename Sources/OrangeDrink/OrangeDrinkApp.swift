import SwiftUI

// [LAW:one-source-of-truth] project.yml's `name` is the app's name; CFBundleName derives from
// it, and the generated Info.plist always carries it, so absence here is a broken build, not
// a case to default past.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String

@main
struct OrangeDrinkApp: App {
    @State private var battery: BatteryModel
    @State private var alerts: AlertCenter
    @State private var sections = PanelSections()

    init() {
        // [LAW:no-silent-failure] Alerts the app cannot load are a launch that says so.
        let alerts: AlertCenter
        let pills = PillController()
        let sounds = AlertSounds()
        do {
            alerts = try AlertCenter(store: AlertSettingsStore(defaults: .standard), deliver: {
                pills.deliver($0, reading: $1)
                sounds.deliver($0)
            })
        } catch {
            fatalError("stored alert settings do not decode: \(error)")
        }
        _alerts = State(initialValue: alerts)
        _battery = State(initialValue: BatteryModel(
            readings: BatteryMonitor.readings(), onReading: { alerts.observe($0) }))
        #if DEBUG
        ComponentGallery.showIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(battery: battery, sections: sections)
        } label: {
            StatusItemLabel(state: battery.state)
        }
        .menuBarExtraStyle(.window)

        Window("\(appName) Settings", id: SettingsWindow.id) { SettingsView() }
    }
}

enum SettingsWindow { static let id = "settings" }
