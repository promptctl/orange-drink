// What scripts/battery-notification-check reads and presses in a VM, through the accessibility API. It needs Accessibility
// trust, which a process `tart exec` starts has.
//   notification-tree list    one line per notification: subrole, title, body, and description, tab-separated
//   notification-tree answer <button>
//                             presses that button in the Bluetooth prompt, and fails if none is showing
//   notification-tree closes <line> <seconds>
//                             watches until `line` from `list` has shown and gone, with another notification showing that
//                             has its title and body. Prints that one, and fails if that never comes
//   notification-tree goes <line> <seconds>
//                             watches for `line` from `list` to show, and fails unless it is gone within that many
//                             seconds of showing. Prints how long it showed
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("notification-tree: \(message)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let read = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    // A failed read is not an empty tree: every "gone" this check reads stands on this. These are what the app calls absent.
    guard [.success, .noValue, .attributeUnsupported, .invalidUIElement].contains(read) else { fail("reading \(name) failed with AXError \(read.rawValue)") }
    return read == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func application(_ bundleIdentifier: String) -> AXUIElement? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first.map { AXUIElementCreateApplication($0.processIdentifier) }
}
func windows(_ application: AXUIElement) -> [AXUIElement] { attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

func walk(_ element: AXUIElement, depth: Int = 0, visit: (AXUIElement) -> Void) {
    guard depth < 16 else { fail("the tree went past depth 16") }
    visit(element)
    children(element).forEach { walk($0, depth: depth + 1, visit: visit) }
}

guard AXIsProcessTrusted() else { fail("this process is not trusted for Accessibility") }

func notifications() -> [String] {
    guard let center = application("com.apple.notificationcenterui") else { fail("NotificationCenter is not running") }
    var lines: [String] = []
    for window in windows(center) where string(window, kAXSubroleAttribute) == "AXSystemDialog" {
        walk(window) { element in
            guard let subrole = string(element, kAXSubroleAttribute), subrole.hasPrefix("AXNotificationCenter") else { return }
            func text(_ identifier: String) -> String {
                children(element).first { string($0, kAXIdentifierAttribute) == identifier }.flatMap { string($0, kAXValueAttribute) } ?? ""
            }
            lines.append([subrole, text("title"), text("body"), string(element, kAXDescriptionAttribute) ?? ""].joined(separator: "\t"))
        }
    }
    return lines
}

switch CommandLine.arguments.dropFirst().first {
case "list":
    notifications().forEach { print($0) }
case "closes":
    let line = CommandLine.arguments[2], deadline = Date().addingTimeInterval(TimeInterval(CommandLine.arguments[3])!)
    let words = line.split(separator: "\t", omittingEmptySubsequences: false)[1...2].joined(separator: "\t")
    var seen = false
    while Date() < deadline {
        let showing = notifications()
        if showing.contains(line) {
            seen = true
        } else if seen, let other = showing.first(where: { $0.contains(words) }) {
            print(other)
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fail(seen ? "it closed, and nothing with its words was left showing" : "it never showed")
case "goes":
    let line = CommandLine.arguments[2], limit = TimeInterval(CommandLine.arguments[3])!
    var shown: Date?
    var deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if notifications().contains(line) {
            if shown == nil {
                shown = Date()
                deadline = Date().addingTimeInterval(limit)
            }
        } else if let shown {
            print(String(format: "it showed for %.2f s", Date().timeIntervalSince(shown)))
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fail(shown == nil ? "it never showed" : "it was still showing after \(limit) s")
case "answer":
    let title = CommandLine.arguments[2]
    guard let prompt = application("com.apple.UserNotificationCenter").flatMap({ windows($0).first }),
          let button = children(prompt).first(where: { string($0, kAXTitleAttribute) == title })
    else { fail("no prompt with a \(title) button is showing") }
    let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard pressed == .success else { fail("pressing \(title) failed with AXError \(pressed.rawValue)") }
default:
    fail("usage: notification-tree list | answer <button> | closes <line> <seconds> | goes <line> <seconds>")
}
