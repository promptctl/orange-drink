// How often NotificationCenter posts AXLayoutChanged, the event BatteryNotificationDismissal runs a pass on during a low
// battery warning (Sources/.../SystemNotifications/LiveNotificationCenter.swift).
//
//   swift scripts/layout-events-count.swift [seconds, default 300]
//   swift scripts/layout-events-count.swift --replay seconds < events     (lines of "<seconds into the run> <source>")
//
// It changes nothing in NotificationCenter, so it can run while the Mac is in use and shows nothing. It does read the role and
// subrole of the element posting each event, from inside the callback, so a NotificationCenter slow to answer delays the
// callbacks after it. It needs the invoking process trusted for Accessibility (System Settings > Privacy & Security >
// Accessibility). NotificationCenter's process also hosts the desktop widgets, so the conditions are read here too: the
// screen's lock state every second, and how many on-screen windows NotificationCenter owned at the start and at the end.
// A run whose conditions did not hold (NotificationCenter restarted, the screen was locked, the Mac slept) prints why and
// exits 1 with no count, because that count answers a different question. --replay summarizes recorded events and observes
// nothing; make layout-events-count-test runs it.
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

let bundleID = "com.apple.notificationcenterui"
let usage = "usage: layout-events-count.swift [seconds] | --replay seconds < events"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("layout-events-count: \(message)\n".utf8)); exit(2)
}

typealias Event = (at: TimeInterval, source: String)

/// What a run's events add up to. The dismissal's wake keeps only the newest, so events that arrive together cost at most two
/// passes: a cluster is the events within a second of the first of them, and is what bounds the passes.
func summary(of events: [Event], over elapsed: TimeInterval) -> [String] {
    let events = events.sorted { $0.at < $1.at }
    let minutes = max(1, Int((elapsed / 60).rounded(.up)))
    let perMinute = (0..<minutes).map { minute in events.filter { min(Int($0.at / 60), minutes - 1) == minute }.count }
    let bySource = events.reduce(into: [String: Int]()) { $0[$1.source, default: 0] += 1 }
    var clusters = 0
    var clusterStart = -TimeInterval.infinity
    for event in events where event.at - clusterStart >= 1 { clusters += 1; clusterStart = event.at }
    func aMinute(_ count: Int) -> String { String(format: "%.2f", Double(count) / (elapsed / 60)) }
    return [
        "\(events.count) events in \(String(format: "%.0f", elapsed)) s, \(aMinute(events.count)) a minute",
        "\(clusters) clusters, \(aMinute(clusters)) a minute",
        "per minute \(perMinute)",
        "by source \(bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })",
    ]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let replaying = arguments.first == "--replay"
let numbers = replaying ? Array(arguments.dropFirst()) : arguments
let requested: Double? = numbers.isEmpty ? 300 : Double(numbers[0])
guard numbers.count <= 1, !(replaying && numbers.isEmpty), let seconds = requested, seconds.isFinite, seconds > 0, seconds <= 86_400
else { fail(usage) }

if replaying {
    var events: [Event] = []
    while let line = readLine() {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let at = Double(parts[0]) else { fail("not an event, \"<seconds> <source>\": \(line)") }
        events.append((at, parts[1]))
    }
    summary(of: events, over: seconds).forEach { print("layout-events-count: \($0)") }
    exit(0)
}

guard AXIsProcessTrusted() else { fail("this process is not trusted for Accessibility") }
guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
    fail("\(bundleID) is not running")
}

struct Conditions {
    let locked: Bool
    /// On-screen windows NotificationCenter owns, by window layer: widgets and banners are among them.
    let windowLayers: [Int]

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func read(of pid: pid_t) -> Conditions {
        let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let layers = listed.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }.compactMap { $0[kCGWindowLayer as String] as? Int }
        return Conditions(locked: screenLocked, windowLayers: layers.sorted())
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
nonisolated(unsafe) var arrivals: [Event] = []

var created: AXObserver?
let creating = AXObserverCreate(pid, { _, element, _, _ in arrivals.append((ProcessInfo.processInfo.systemUptime, source(of: element))) }, &created)
guard creating == .success, let observer = created else { fail("AXObserverCreate returned AXError \(creating.rawValue)") }
let added = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXLayoutChangedNotification as CFString, nil)
guard added == .success else { fail("AXObserverAddNotification returned AXError \(added.rawValue)") }
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

let before = Conditions.read(of: pid)
let start = ProcessInfo.processInfo.systemUptime
let wallStart = Date()
var lockedSeconds = 0
print("layout-events-count: watching pid \(pid) for \(Int(seconds)) s; at start \(before.line)")
while ProcessInfo.processInfo.systemUptime - start < seconds {
    CFRunLoopRunInMode(.defaultMode, min(1, seconds), false)
    if Conditions.screenLocked { lockedSeconds += 1 }
}
let after = Conditions.read(of: pid)
let elapsed = ProcessInfo.processInfo.systemUptime - start
// systemUptime stops while the Mac sleeps and the wall clock does not, so the gap between them is the time asleep.
let asleep = Date().timeIntervalSince(wallStart) - elapsed
let last = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier

// A NotificationCenter that restarted took the observer with it, so its events after that went uncounted.
var voids: [String] = []
if last != pid { voids.append("NotificationCenter was pid \(pid) at the start and \(last.map(String.init) ?? "not running") at the end") }
if lockedSeconds > 0 { voids.append("the screen was locked in \(lockedSeconds) of the once-a-second looks") }
if asleep > 2 { voids.append("the Mac slept for about \(String(format: "%.0f", asleep)) s") }
guard voids.isEmpty else {
    print("layout-events-count: FAIL \(voids.joined(separator: "; ")); the count is void")
    exit(1)
}

summary(of: arrivals.filter { $0.at >= start }.map { ($0.at - start, $0.source) }, over: elapsed).forEach { print("layout-events-count: \($0)") }
print("layout-events-count: at end \(after.line)")
