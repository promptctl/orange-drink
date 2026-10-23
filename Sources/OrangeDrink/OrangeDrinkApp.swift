import SwiftUI
import OSLog
import WidgetKit

// [LAW:one-source-of-truth] project.yml's `name` is the app's name; CFBundleName derives from
// it, and the generated Info.plist always carries it, so absence here is a broken build, not
// a case to default past.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String

@main
struct OrangeDrinkApp: App {
    @NSApplicationDelegateAdaptor(TerminationLog.self) private var terminationLog
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
    @State private var chargeLimit: ChargeLimitModel
    @State private var sections: PanelSections
    @State private var lowPowerMode: LowPowerMode
    private let keyboard: PanelKeyboard
    private let history: Result<BatteryHistory, any Error>
    private let appEnergy: Result<AppEnergyHistory, any Error>

    init() {
        // [LAW:no-silent-failure] Alerts the app cannot load are a launch that says so.
        let alerts: AlertCenter
        let appearance: NotificationAppearanceModel
        let deviceSettings: DeviceSettingsModel
        let menuBarIcon: MenuBarIconModel
        let look: AppAppearanceModel
        let language: AppLanguageModel
        let shortcutsModel: ShortcutsModel
        let chargeLimit: ChargeLimitModel
        let pills: PillController
        let sounds = AlertSounds()
        do {
            appearance = try NotificationAppearanceModel(defaults: .standard)
            deviceSettings = try DeviceSettingsModel(defaults: .standard)
            menuBarIcon = try MenuBarIconModel(defaults: .standard)
            look = try AppAppearanceModel(defaults: .standard)
            language = try AppLanguageModel(defaults: .standard)
            shortcutsModel = try ShortcutsModel(defaults: .standard)
            chargeLimit = try ChargeLimitModel(defaults: .standard)
            pills = PillController(appearance: appearance, language: language)
            pills.follow(screen: ScreenMonitor.hidden(), layout: ScreenMonitor.layout())
            alerts = try AlertCenter(defaults: .standard, deliver: {
                pills.deliver($0, reading: $1)
                sounds.deliver($0)
            }, deliverDevice: {
                pills.deliver($0)
                sounds.deliver($0)
            })
        } catch {
            fatalError("stored alert, appearance, device, menu bar, app appearance, app language, shortcut, or charge limit settings do not decode: \(error)")
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
        let lowPowerMode = LowPowerMode(helper: HelperAccess(daemon: HelperRegistration.daemon))
        _lowPowerMode = State(initialValue: lowPowerMode)
        keyboard = PanelKeyboard(sections: sections, lowPowerMode: lowPowerMode, shortcuts: shortcutsModel, events: NSKeyEvents())
        _language = State(initialValue: language)
        _chargeLimit = State(initialValue: chargeLimit)
        // [LAW:no-silent-failure] A history that cannot be opened is logged, and the app runs without it;
        // the Battery screen holds the failure, so it can say so instead of showing an empty chart.
        let store = Result { try HistoryStore(url: HistoryStore.defaultURL()) }
        let changes = HistoryChanges()
        let history = store.map { BatteryHistory(store: $0, changes: changes) }
        switch history {
        case .success(let recording): recording.follow(screen: ScreenMonitor.changes())
        case .failure(let error): log.error("no battery history: \(error)")
        }
        self.history = history
        // [LAW:one-source-of-truth] project.yml signs every build into the app group, so a missing
        // container is a broken build, not a case to run past.
        let widgets: MacBatteryPublisher
        do {
            widgets = MacBatteryPublisher(directory: try WidgetShelf.groupContainer()) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetShelf.macBatteryKind)
            }
        } catch { fatalError("no widget shelf: \(error)") }
        // [LAW:no-ambient-temporal-coupling] The one place the app's state is saved at its normal end: a menu
        // Quit, logout, shutdown, and SIGTERM (routed to terminate by SignalTermination) arrive here; a
        // crash or SIGKILL does not. The helper's record is released at exit() instead, which the test
        // host's end reaches without this notification.
        SignalTermination.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if case .success(let recording) = history { recording.flush() }
                widgets.publish(.appNotRunning)
            }
        }
        // [LAW:no-silent-failure] App energy needs the history store and the system's responsibility symbol;
        // without either the app runs without it, and says so in the log.
        appEnergy = Result { try AppEnergyHistory(store: store.get(), changes: changes, source: RusageEnergySource()) }
        if case .failure(let error) = appEnergy { log.error("no app energy history: \(error)") }
        _battery = State(initialValue: BatteryModel(
            readings: BatteryMonitor.readings(), onState: { state in
                widgets.publish(MacBattery(state))
                guard case .known(let reading) = state else { return }
                alerts.observe(reading)
                if case .success(let recording) = history { recording.observe(reading) }
            }))
        HelperRegistration.holdUntilExit()
        #if DEBUG
        ComponentGallery.showIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(battery: battery, devices: devices, deviceSettings: deviceSettings, appEnergy: appEnergy, sections: sections, lowPowerMode: lowPowerMode, keyboard: keyboard, look: look, language: language)
        } label: {
            StatusItemLabel(state: battery.state, icon: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("\(appName) Settings", id: SettingsWindow.id) { SettingsView(alerts: alerts, appearance: appearance, look: look, language: language, shortcuts: shortcuts, menuBarIcon: menuBarIcon, devices: devices, deviceSettings: deviceSettings, chargeLimit: chargeLimit, battery: battery, history: history, appEnergy: appEnergy) }
    }
}

enum SettingsWindow { static let id = "settings" }
