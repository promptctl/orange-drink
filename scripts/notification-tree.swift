// What scripts/battery-notification-check reads and presses in a VM, through the accessibility API. It needs Accessibility
// trust, which a process `tart exec` starts has.
//   notification-tree list    one line per notification: subrole, title, body, and description, tab-separated
//   notification-tree allow   presses Allow in the Bluetooth prompt, and fails if none is showing
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("notification-tree: \(message)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let read = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    // A failed read is not an empty tree: every "gone" this check reads stands on this.
    guard ![.cannotComplete, .apiDisabled, .notImplemented].contains(read) else { fail("reading \(name) failed with AXError \(read.rawValue)") }
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

switch CommandLine.arguments.dropFirst().first {
case "list":
    guard let center = application("com.apple.notificationcenterui") else { fail("NotificationCenter is not running") }
    for window in windows(center) where string(window, kAXSubroleAttribute) == "AXSystemDialog" {
        walk(window) { element in
            guard let subrole = string(element, kAXSubroleAttribute), subrole.hasPrefix("AXNotificationCenter") else { return }
            func text(_ identifier: String) -> String {
                children(element).first { string($0, kAXIdentifierAttribute) == identifier }.flatMap { string($0, kAXValueAttribute) } ?? ""
            }
            print([subrole, text("title"), text("body"), string(element, kAXDescriptionAttribute) ?? ""].joined(separator: "\t"))
        }
    }
case "allow":
    guard let prompt = application("com.apple.UserNotificationCenter").flatMap({ windows($0).first }),
          let allow = children(prompt).first(where: { string($0, kAXTitleAttribute) == "Allow" })
    else { fail("no prompt with an Allow button is showing") }
    let pressed = AXUIElementPerformAction(allow, kAXPressAction as CFString)
    guard pressed == .success else { fail("pressing Allow failed with AXError \(pressed.rawValue)") }
default:
    fail("usage: notification-tree list | allow")
}
