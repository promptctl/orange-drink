// Finds the notifications on screen through NotificationCenter's accessibility tree and says which are the system's
// low battery notification. It needs Accessibility trust.
//   banners dump           the notification window's tree, attributes and actions
//   banners list           each notification with its verdict
//   banners close          closes the low battery notifications, and nothing else, and prints what it did
//   banners closer <n> <secs> watches that long and, once n notifications show and one is low battery, closes that one,
//                          prints what was showing at that moment and just after, and fails unless the others stayed
//   banners observe <secs> prints each accessibility notification NotificationCenter sends, to show what could wake a closer
//   banners wait <n> <secs> returns when exactly n notifications are showing, and fails if that never comes
//   banners panel          presses the clock in the menu bar, which opens the Notification Center panel
//   banners words          prints the low battery notification's title and body, a line each, for another app to post
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let read = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    // A failed read is not an empty tree: every "gone" and "nothing posted" in output.txt stands on this.
    guard read != .cannotComplete else { fatalError("reading \(name): the app did not answer") }
    return read == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    return AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
}
func walk(_ element: AXUIElement, depth: Int = 0, visit: (AXUIElement, Int) -> Void) {
    visit(element, depth)
    children(element).forEach { walk($0, depth: depth + 1, visit: visit) }
}

let start = Date()

func notificationCenterApp() -> NSRunningApplication {
    guard AXIsProcessTrusted() else { fatalError("this process is not trusted for Accessibility") }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
    else { fatalError("NotificationCenter is not running") }
    return app
}
// Only this window: the desktop widgets' windows are NotificationCenter's too, and their trees loop.
func notificationWindows() -> [AXUIElement] {
    (attribute(AXUIElementCreateApplication(notificationCenterApp().processIdentifier), kAXWindowsAttribute) as! [AXUIElement])
        .filter { string($0, kAXSubroleAttribute) == "AXSystemDialog" }
}

struct Notification {
    let element: AXUIElement, subrole: String, title: String, body: String, description: String, stacking: String, actions: [String]
}

func notifications() -> [Notification] {
    var found: [Notification] = []
    for window in notificationWindows() {
        walk(window) { element, _ in
            guard let subrole = string(element, kAXSubroleAttribute), subrole.hasPrefix("AXNotificationCenter") else { return }
            func text(_ identifier: String) -> String {
                children(element).first { string($0, kAXIdentifierAttribute) == identifier }.flatMap { string($0, kAXValueAttribute) } ?? ""
            }
            found.append(Notification(element: element, subrole: subrole, title: text("title"), body: text("body"),
                                      description: string(element, kAXDescriptionAttribute) ?? "",
                                      stacking: string(element, "AXStackingIdentifier") ?? "-", actions: actions(element)))
        }
    }
    return found
}

// The bundle macOS posts the notification under holds its display name, which is what shows as its title, and its body,
// in every language macOS speaks. All of them are read, so nothing here has to know which language NotificationCenter is
// showing. LOW_BATTERY_TITLE is not what shows: in Brazilian Portuguese it differs, and the display name is on screen.
func lowBatteryTable(_ name: String) -> [String: Any] {
    let bundle = "/System/Library/UserNotifications/Bundles/com.apple.controlcenter.notifications.low-battery.bundle"
    return NSDictionary(contentsOf: URL(fileURLWithPath: "\(bundle)/Contents/Resources/\(name).loctable"))! as! [String: Any]
}
struct Words: Hashable { let title: String, body: String }
let bodies = lowBatteryTable("Localizable")
// Beside its languages each table has one entry, LocProvenance, with no words in it.
let lowBatteryWords = Set(lowBatteryTable("InfoPlist").flatMap { language, names -> [Words] in
    guard let title = (names as? [String: String])?["CFBundleDisplayName"], let words = bodies[language] as? [String: String] else { return [] }
    return ["LOW_BATTERY_BODY", "LOW_BATTERY_LOCKDOWN_BODY"].compactMap { key in words[key].map { Words(title: title, body: $0) } }
})

// Words alone would also catch another app that posts the same ones, so the subrole and the description have to agree.
// This notification is always an alert, and an app's is a banner unless its user chose Alerts. macOS 14 makes the
// description the title. macOS 15 and 26 make it "title, body", and join the two in the Mac's language: "、" in Japanese,
// a space in Chinese, "،" and bidi marks in Arabic. So with the words taken out, nothing that could be a name may be left.
// An app's notification with these words reads "Script Editor" or "Script Editor, Low Battery, ...". macOS 26 gives a
// notification no attribute that names its poster, so an app displayed as "Low Battery" or in punctuation alone, set to
// Alerts, posting these exact words should still pass. No run posted as one.
func isSystemLowBattery(_ notification: Notification) -> Bool {
    let rest = notification.description.replacingOccurrences(of: notification.title, with: "").replacingOccurrences(of: notification.body, with: "")
    return notification.subrole == "AXNotificationCenterAlert"
        && lowBatteryWords.contains(Words(title: notification.title, body: notification.body))
        && notification.description.contains(notification.title)
        && !rest.contains { $0.isLetter || $0.isNumber || $0.isSymbol }
}

func close(_ notification: Notification) -> AXError {
    // Its custom actions are Show Details and Close, named in the Mac's language ("Name:Fermer"), so position is what's
    // read. Any other shape stays showing: its last action might open the poster.
    let custom = notification.actions.filter { $0.hasPrefix("Name:") }
    guard custom.count == 2 else { return .actionUnsupported }
    return AXUIElementPerformAction(notification.element, custom[1] as CFString)
}

func describe(_ notification: Notification) -> String {
    "\(isSystemLowBattery(notification) ? "BATTERY" : "other") \(notification.subrole) title=\(notification.title) "
        + "body=\(notification.body) description=\(notification.description) stacking=\(notification.stacking) "
        + "actions=\(notification.actions.map { $0.components(separatedBy: "\n")[0] })"
}

switch CommandLine.arguments.dropFirst().first {
case "dump":
    notificationWindows().forEach { walk($0) { element, depth in
        var list: CFArray?
        AXUIElementCopyAttributeNames(element, &list)
        let values = (list as? [String] ?? []).filter { !["AXPath", "AXChildren", "AXParent"].contains($0) }.compactMap { name -> String? in
            attribute(element, name).map { "\(name)=\($0)".replacingOccurrences(of: "\n", with: " ") }
        }
        print(String(repeating: "  ", count: depth) + values.joined(separator: " | ") + " actions=\(actions(element))")
    } }
case "list":
    let started = Date()
    let shown = notifications()
    shown.forEach { print(describe($0)) }
    print("\(shown.count) notifications, \(lowBatteryWords.count) sets of words, scan took \(Int(Date().timeIntervalSince(started) * 1000)) ms")
case "close":
    for notification in notifications() where isSystemLowBattery(notification) {
        print("closing \(notification.subrole): \(close(notification).rawValue) (0 is success)")
    }
case "closer":
    let wanted = Int(CommandLine.arguments[2])!, deadline = Date().addingTimeInterval(TimeInterval(CommandLine.arguments[3])!)
    while Date() < deadline {
        let shown = notifications()
        if shown.count >= wanted, let battery = shown.first(where: isSystemLowBattery) {
            shown.forEach { print("showing: " + describe($0)) }
            print("closing \(battery.subrole): \(close(battery).rawValue) (0 is success)")
            let closed = Date()
            while notifications().contains(where: isSystemLowBattery) {
                guard -closed.timeIntervalSinceNow < 3 else { print("still in the tree after 3s"); exit(1) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            print(String(format: "gone from the tree after %.2fs", -closed.timeIntervalSinceNow))
            let after = notifications()
            after.forEach { print("after: " + describe($0)) }
            print("\(after.count) notifications after")
            guard after.count == shown.count - 1, after.allSatisfy({
                $0.subrole == "AXNotificationCenterBanner" && $0.title == battery.title && $0.body == battery.body
            }) else {
                print("another app's notification did not stay")
                exit(1)
            }
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    print("\(wanted) notifications with a low battery one never showed")
    exit(1)
case "observe":
    let pid = notificationCenterApp().processIdentifier
    var observer: AXObserver?
    AXObserverCreate(pid, { _, element, name, _ in
        print(String(format: "%.2fs", -start.timeIntervalSinceNow), name, string(element, kAXRoleAttribute) ?? "-", string(element, kAXSubroleAttribute) ?? "-")
    }, &observer)
    let application = AXUIElementCreateApplication(pid)
    for name in [kAXLayoutChangedNotification, kAXWindowCreatedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification] {
        print(name, AXObserverAddNotification(observer!, application, name as CFString, nil).rawValue)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer!), .defaultMode)
    RunLoop.current.run(until: Date().addingTimeInterval(TimeInterval(CommandLine.arguments[2])!))
case "wait":
    let wanted = Int(CommandLine.arguments[2])!, deadline = Date().addingTimeInterval(TimeInterval(CommandLine.arguments[3])!)
    while notifications().count != wanted {
        guard Date() < deadline else { print("\(wanted) notifications never showed"); exit(1) }
        Thread.sleep(forTimeInterval: 0.1)
    }
case "panel":
    let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first!
    let extras = attribute(AXUIElementCreateApplication(controlCenter.processIdentifier), "AXExtrasMenuBar") as! AXUIElement
    let clock = children(extras).first { string($0, kAXIdentifierAttribute) == "com.apple.menuextra.clock" }!
    print("pressing the clock: \(AXUIElementPerformAction(clock, kAXPressAction as CFString).rawValue) (0 is success)")
case "words":
    let battery = notifications().first(where: isSystemLowBattery)!
    print(battery.title)
    print(battery.body)
default:
    fatalError("usage: banners dump | list | close | closer <count> <seconds> | observe <seconds> | wait <count> <seconds> | panel | words")
}
