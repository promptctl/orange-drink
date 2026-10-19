import SwiftUI
import OSLog

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
    private let shortcuts: ShortcutsController
    @State private var alerts: AlertCenter
    @State private var appearance: NotificationAppearanceModel
    @State private var menuBarIcon: MenuBarIconModel
    @State private var look: AppAppearanceModel
    @State private var language: AppLanguageModel
    @State private var sections: PanelSections
    private let keyboard: PanelKeyboard

    init() {
        // [LAW:no-silent-failure] Alerts the app cannot load are a launch that says so.
        let alerts: AlertCenter
        let appearance: NotificationAppearanceModel
        let deviceSettings: DeviceSettingsModel
        let menuBarIcon: MenuBarIconModel
        let look: AppAppearanceModel
        let language: AppLanguageModel
        let shortcutsModel: ShortcutsModel
        let pills: PillController
        let sounds = AlertSounds()
        do {
            appearance = try NotificationAppearanceModel(defaults: .standard)
            deviceSettings = try DeviceSettingsModel(defaults: .standard)
            menuBarIcon = try MenuBarIconModel(defaults: .standard)
            look = try AppAppearanceModel(defaults: .standard)
            language = try AppLanguageModel(defaults: .standard)
            shortcutsModel = try ShortcutsModel(defaults: .standard)
            pills = PillController(appearance: appearance)
            alerts = try AlertCenter(store: AlertSettingsStore(defaults: .standard), deliver: {
                pills.deliver($0, reading: $1)
                sounds.deliver($0)
            }, deliverDevice: {
                pills.deliver($0)
                sounds.deliver($0)
            })
        } catch {
            fatalError("stored alert, appearance, device, menu bar, app appearance, app language, or shortcut settings do not decode: \(error)")
        }
        let devices = DevicesModel(events: BluetoothDevices.appEvents(), onChange: {
            alerts.observe(devices: $0, watching: deviceSettings.value.alerting)
        })
        _devices = State(initialValue: devices)
        pinnedItems = PinnedItemsController()
        // [LAW:no-silent-failure] A shortcut the system will not give us is logged, and the app runs without it.
        let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "hotkey")
        let hotKeys: any HotKeys
        do { hotKeys = try CarbonHotKeys.shared() } catch let error as HotKeyError {
            log.error("no global shortcuts: \(error)")
            hotKeys = UnavailableHotKeys(cause: error)
        } catch { fatalError("CarbonHotKeys.shared() throws only HotKeyError: \(error)") }
        shortcuts = ShortcutsController(model: shortcutsModel, hotKeys: hotKeys, panel: StatusItemPanel())
        do { try shortcuts.start() } catch { log.error("no global shortcut to open the panel: \(error)") }
        pinnedItems.follow(devices: devices, settings: deviceSettings)
        _deviceSettings = State(initialValue: deviceSettings)
        _alerts = State(initialValue: alerts)
        _appearance = State(initialValue: appearance)
        _menuBarIcon = State(initialValue: menuBarIcon)
        _look = State(initialValue: look)
        let sections = PanelSections()
        _sections = State(initialValue: sections)
        keyboard = PanelKeyboard(sections: sections, shortcuts: shortcutsModel, events: NSKeyEvents())
        _language = State(initialValue: language)
        _battery = State(initialValue: BatteryModel(
            readings: BatteryMonitor.readings(), onReading: { alerts.observe($0) }))
        #if DEBUG
        ComponentGallery.showIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(battery: battery, devices: devices, deviceSettings: deviceSettings, sections: sections, keyboard: keyboard, look: look, language: language)
        } label: {
            StatusItemLabel(state: battery.state, icon: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("\(appName) Settings", id: SettingsWindow.id) { SettingsView(alerts: alerts, appearance: appearance, look: look, language: language, shortcuts: shortcuts, menuBarIcon: menuBarIcon, devices: devices, deviceSettings: deviceSettings) }
    }
}

enum SettingsWindow { static let id = "settings" }
