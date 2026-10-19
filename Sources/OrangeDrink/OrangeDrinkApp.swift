import SwiftUI

// [LAW:one-source-of-truth] project.yml's `name` is the app's name; CFBundleName derives from
// it, and the generated Info.plist always carries it, so absence here is a broken build, not
// a case to default past.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String

@main
struct OrangeDrinkApp: App {
    @State private var battery: BatteryModel
    @State private var devices: DevicesModel
    @State private var deviceSettings: DeviceSettingsModel
    private let pinnedItems: PinnedItemsController
    @State private var alerts: AlertCenter
    @State private var appearance: NotificationAppearanceModel
    @State private var menuBarIcon: MenuBarIconModel
    @State private var sections = PanelSections()

    init() {
        // [LAW:no-silent-failure] Alerts the app cannot load are a launch that says so.
        let alerts: AlertCenter
        let appearance: NotificationAppearanceModel
        let deviceSettings: DeviceSettingsModel
        let menuBarIcon: MenuBarIconModel
        let pills: PillController
        let sounds = AlertSounds()
        do {
            appearance = try NotificationAppearanceModel(defaults: .standard)
            deviceSettings = try DeviceSettingsModel(defaults: .standard)
            menuBarIcon = try MenuBarIconModel(defaults: .standard)
            pills = PillController(appearance: appearance)
            alerts = try AlertCenter(store: AlertSettingsStore(defaults: .standard), deliver: {
                pills.deliver($0, reading: $1)
                sounds.deliver($0)
            }, deliverDevice: {
                pills.deliver($0)
                sounds.deliver($0)
            })
        } catch {
            fatalError("stored alert, appearance, device, or menu bar settings do not decode: \(error)")
        }
        let devices = DevicesModel(events: BluetoothDevices.appEvents(), onChange: {
            alerts.observe(devices: $0, watching: deviceSettings.value.alerting)
        })
        _devices = State(initialValue: devices)
        pinnedItems = PinnedItemsController()
        pinnedItems.follow(devices: devices, settings: deviceSettings)
        _deviceSettings = State(initialValue: deviceSettings)
        _alerts = State(initialValue: alerts)
        _appearance = State(initialValue: appearance)
        _menuBarIcon = State(initialValue: menuBarIcon)
        _battery = State(initialValue: BatteryModel(
            readings: BatteryMonitor.readings(), onReading: { alerts.observe($0) }))
        #if DEBUG
        ComponentGallery.showIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(battery: battery, devices: devices, deviceSettings: deviceSettings, sections: sections)
        } label: {
            StatusItemLabel(state: battery.state, icon: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("\(appName) Settings", id: SettingsWindow.id) { SettingsView(alerts: alerts, appearance: appearance, menuBarIcon: menuBarIcon, devices: devices, deviceSettings: deviceSettings) }
    }
}

enum SettingsWindow { static let id = "settings" }
