import AppKit
import Testing
import WidgetKit
@testable import OrangeDrink

/// What macOS passes for a click, as it was recorded from real clicks: the kind and the family in `userInfo`, and an
/// `activityType` that is the kind only for a widget with no configuration.
@MainActor private func activity(type: String = "SelectDeviceIntent", kind: String?, family: String? = "systemSmall") -> NSUserActivity {
    let activity = NSUserActivity(activityType: type)
    activity.userInfo = [kind.map { (WidgetCenter.UserInfoKey.kind, $0) }, family.map { (WidgetCenter.UserInfoKey.family, $0) }]
        .compactMap { $0 }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    return activity
}

@MainActor @Suite struct WidgetClickTests {
    @Test(arguments: [WidgetKind.macBattery, .deviceBattery, .allBatteries])
    func aClickIsReadByItsKindNotItsActivityType(kind: WidgetKind) {
        #expect(WidgetClick(activity(kind: kind.rawValue))?.kind == kind)
    }

    @Test func aClickWithNoFamilyIsStillAClick() {
        #expect(WidgetClick(activity(kind: "MacBattery", family: nil))?.kind == .macBattery)
    }

    @Test func anActivityNamingNoKindOfOursIsNotAClick() {
        #expect(WidgetClick(activity(type: "MacBattery", kind: nil)) == nil)
        #expect(WidgetClick(activity(kind: "SomeoneElsesWidget")) == nil)
    }

    /// scripts/widget-click-check reads these lines.
    @Test func theLogNamesThePathTheKindAndThePanelsState() throws {
        let click = try #require(WidgetClick(activity(kind: "AllBatteries")))
        #expect(click.line(panelWasOpen: false) == "widget click by user activity: AllBatteries, panel was closed")
        #expect(click.line(panelWasOpen: true) == "widget click by user activity: AllBatteries, panel was open")
    }
}

@MainActor @Suite struct AppDelegateTests {
    private let panel = FakePanel()
    private final class Lines { var read: [String] = [] }
    private let lines = Lines()

    private func delegate(_ termination: TerminationLog? = nil) -> AppDelegate {
        AppDelegate(termination: termination ?? TerminationLog(records: QuitRecords(url: URL(filePath: "/dev/null/quits.log"), build: "test build"), signal: SIGUSR1, terminate: {}),
                    panel: panel, record: { [lines] in lines.read.append($0) })
    }

    private func `continue`(_ activity: NSUserActivity, on delegate: AppDelegate) -> Bool {
        delegate.application(NSApplication.shared, continue: activity, restorationHandler: { _ in })
    }

    @Test func aClickShowsThePanelAndASecondLeavesItOpen() {
        let delegate = delegate()
        #expect(`continue`(activity(kind: "MacBattery"), on: delegate))
        #expect(panel.isOpen)
        #expect(`continue`(activity(kind: "DeviceBattery"), on: delegate))
        #expect(panel.isOpen)
        // Read before it is opened, or every line would say open.
        #expect(lines.read == ["widget click by user activity: MacBattery, panel was closed", "widget click by user activity: DeviceBattery, panel was open"])
    }

    @Test func anActivityThatIsNoWidgetsLeavesThePanelClosedAndSaysSo() {
        #expect(!`continue`(activity(type: "com.example.handoff", kind: nil), on: delegate()))
        #expect(!panel.isOpen)
        #expect(lines.read == ["user activity com.example.handoff is not a widget click"])
    }

    @Test func aLaunchOpensNoPanelAndSaysItFinished() {
        delegate().applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(!panel.isOpen)
        #expect(lines.read == ["launch finished"])
    }

    // [LAW:behavior-not-structure] Each callback reaches what it is for: a real signal is watched from the launch, and a
    // quit leaves its record. SIGUSR1 because the test host is the app, and TerminationTests has SIGUSR2.
    @Test(.timeLimit(.minutes(1))) func quittingStillGoesThroughTheTerminationLog() async throws {
        let quits = QuitRecords(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), build: "test build")
        defer { try? FileManager.default.removeItem(at: quits.url) }
        let (asked, ask) = AsyncStream.makeStream(of: Void.self)
        let delegate = delegate(TerminationLog(records: quits, signal: SIGUSR1, terminate: { ask.yield() }))
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        kill(getpid(), SIGUSR1)
        for await _ in asked { break }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(FileManager.default.fileExists(atPath: quits.url.path))
    }
}

@MainActor @Suite struct StatusItemPanelTests {
    private final class Bar {
        var visible: Bool
        var presses = 0
        init(visible: Bool) { self.visible = visible }
    }

    private func panel(on bar: Bar) -> StatusItemPanel {
        StatusItemPanel(item: .init(panelIsVisible: { bar.visible }, press: { bar.presses += 1 }))
    }

    @Test(arguments: [(false, 1), (true, 0)]) func openPressesTheItemOnlyWhenThePanelIsClosed(visible: Bool, presses: Int) {
        let bar = Bar(visible: visible)
        panel(on: bar).open()
        #expect(bar.presses == presses)
    }

    @Test(arguments: [(true, 1), (false, 0)]) func closePressesTheItemOnlyWhenThePanelIsOpen(visible: Bool, presses: Int) {
        let bar = Bar(visible: visible)
        panel(on: bar).close()
        #expect(bar.presses == presses)
    }
}
