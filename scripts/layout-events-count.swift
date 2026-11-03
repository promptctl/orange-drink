// How often NotificationCenter posts AXLayoutChanged, the event BatteryNotificationDismissal runs a pass on during a low
// battery warning (Sources/.../SystemNotifications/LiveNotificationCenter.swift).
//
//   swift scripts/layout-events-count.swift [seconds, default 300]
//
// Read-only: it observes the event and reads no element, so it can run while the Mac is in use and shows nothing. It needs
// the invoking process trusted for Accessibility (System Settings > Privacy & Security > Accessibility). NotificationCenter's
// process also hosts the desktop widgets, so the conditions are read here too: whether the screen was locked, and how many
// on-screen windows NotificationCenter owned, at the start and at the end.
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

let bundleID = "com.apple.notificationcenterui"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("layout-events-count: \(message)\n".utf8)); exit(2)
}

guard CommandLine.arguments.count <= 2 else { fail("usage: layout-events-count.swift [seconds]") }
let seconds = CommandLine.arguments.count == 2 ? Double(CommandLine.arguments[1]) : 300
guard let seconds, seconds > 0 else { fail("usage: layout-events-count.swift [seconds]") }
guard AXIsProcessTrusted() else { fail("this process is not trusted for Accessibility") }
guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
    fail("\(bundleID) is not running")
}

struct Conditions {
    let locked: Bool
    /// On-screen windows NotificationCenter owns, by window layer: widgets and banners are among them.
    let windowLayers: [Int]

    static func read(of pid: pid_t) -> Conditions {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let layers = listed.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }.compactMap { $0[kCGWindowLayer as String] as? Int }
        return Conditions(locked: session["CGSSessionScreenIsLocked"] as? Bool ?? false, windowLayers: layers.sorted())
    }

    var line: String { "screen \(locked ? "locked" : "unlocked"), \(windowLayers.count) NotificationCenter windows on screen, layers \(windowLayers)" }
}

/// What posted an event, as "role/subrole": AXSystemDialog is the subrole of the window a low battery alert is in.
func source(of element: AXUIElement) -> String {
    func read(_ attribute: String) -> String {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String ?? "-" : "unreadable"
    }
    return "\(read(kAXRoleAttribute))/\(read(kAXSubroleAttribute))"
}

// The callback is a C function, so what it adds to is a global.
nonisolated(unsafe) var arrivals: [(at: TimeInterval, source: String)] = []

var created: AXObserver?
let creating = AXObserverCreate(pid, { _, element, _, _ in arrivals.append((ProcessInfo.processInfo.systemUptime, source(of: element))) }, &created)
guard creating == .success, let observer = created else { fail("AXObserverCreate returned AXError \(creating.rawValue)") }
let added = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXLayoutChangedNotification as CFString, nil)
guard added == .success else { fail("AXObserverAddNotification returned AXError \(added.rawValue)") }
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

let before = Conditions.read(of: pid)
let start = ProcessInfo.processInfo.systemUptime
print("layout-events-count: watching pid \(pid) for \(Int(seconds)) s; at start \(before.line)")
while ProcessInfo.processInfo.systemUptime - start < seconds {
    CFRunLoopRunInMode(.defaultMode, min(1, seconds), false)
}
let after = Conditions.read(of: pid)
let elapsed = ProcessInfo.processInfo.systemUptime - start

// A NotificationCenter that restarted took the observer with it, so its events after that went uncounted.
let last = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
guard last == pid else {
    print("layout-events-count: FAIL NotificationCenter was pid \(pid) at the start and \(last.map(String.init) ?? "not running") at the end; the count is void")
    exit(1)
}

let counted = arrivals.filter { $0.at >= start }
let minutes = Int((elapsed / 60).rounded(.up))
let perMinute = (0..<minutes).map { minute in counted.filter { Int(($0.at - start) / 60) == minute }.count }
let bySource = counted.reduce(into: [String: Int]()) { $0[$1.source, default: 0] += 1 }
// The dismissal's wake keeps only the newest, so events that arrive together cost at most two passes; a burst is a run of
// events each less than a second after the one before.
let bursts = counted.indices.filter { $0 == 0 || counted[$0].at - counted[$0 - 1].at >= 1 }.count
print("layout-events-count: \(counted.count) events in \(String(format: "%.0f", elapsed)) s, " +
      "\(String(format: "%.2f", Double(counted.count) / (elapsed / 60))) a minute")
print("layout-events-count: \(bursts) bursts, \(String(format: "%.2f", Double(bursts) / (elapsed / 60))) a minute")
print("layout-events-count: per minute \(perMinute)")
print("layout-events-count: by source \(bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
print("layout-events-count: at end \(after.line)")
