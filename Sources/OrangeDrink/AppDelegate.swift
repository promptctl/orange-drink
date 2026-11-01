import AppKit
import OSLog

/// The app's delegate. SwiftUI's adaptor takes one, so this hands each callback to the type whose job it is.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "appDelegate")

    private let termination: TerminationLog
    private let panel: any Panel
    private let record: @MainActor (String) -> Void

    init(termination: TerminationLog, panel: any Panel, record: @escaping @MainActor (String) -> Void) {
        self.termination = termination
        self.panel = panel
        self.record = record
    }

    override convenience init() {
        self.init(termination: TerminationLog(), panel: StatusItemPanel(item: .live), record: { Self.log.notice("\($0, privacy: .public)") })
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        termination.applicationWillFinishLaunching(notification)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("launch finished")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.applicationShouldTerminate(sender)
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let click = WidgetClick(userActivity) else {
            record("user activity \(userActivity.activityType) is not a widget click")
            return false
        }
        let wasOpen = panel.isOpen
        panel.open()
        record(click.line(panelWasOpen: wasOpen))
        return true
    }
}
