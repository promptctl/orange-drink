// Presses one control of a running app, as a person would, through its accessibility tree: the enabled element of the
// app's windows and menu bar items whose title or description is exactly the name given. A control that only exists
// while something is open names the control that opens it, which is a toggle, so it is pressed only when the first is
// absent from the tree, and once.
//
//   swift scripts/update-press.swift <pid> <name> [<name of the control that shows it>]
//
// Exits 0 once pressed, 1 when no such control appeared in time, 2 when it could not look. It asserts nothing:
// scripts/update-check reads what the press did. It needs the invoking process to be trusted for Accessibility.
import ApplicationServices
import Foundation

let waitSeconds = 60.0

func stop(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("update-press: \(message)\n".utf8))
    exit(status)
}

guard (3...4).contains(CommandLine.arguments.count), let pid = pid_t(CommandLine.arguments[1]) else {
    stop("usage: update-press.swift <pid> <name> [<name of the control that shows it>]", status: 2)
}
guard AXIsProcessTrusted() else { stop("this process is not trusted for Accessibility", status: 2) }
let name = CommandLine.arguments[2]
var opener = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement, _ name: String) -> [AXUIElement] { attribute(element, name) as? [AXUIElement] ?? [] }

func tree(_ element: AXUIElement) -> [AXUIElement] { [element] + children(element, kAXChildrenAttribute).flatMap(tree) }

func pressable(_ element: AXUIElement) -> Bool {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(element, &actions) == .success else { return false }
    return (actions as? [String] ?? []).contains(kAXPressAction) && attribute(element, kAXEnabledAttribute) as? Bool == true
}

func controls(named name: String) -> [AXUIElement] {
    // The menu bar items' parent is one element, where the windows are a list. An app with no item has none.
    let bar = attribute(app, "AXExtrasMenuBar").map { [$0 as! AXUIElement] } ?? []
    return (children(app, kAXWindowsAttribute) + bar).flatMap(tree).filter { element in
        [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute(element, $0) as? String == name }
    }
}

func press(_ control: AXUIElement, _ name: String) {
    let result = AXUIElementPerformAction(control, kAXPressAction as CFString)
    // An app a press ends never replies, which reads as cannotComplete; scripts/update-check reads what the press did.
    guard result == .success || result == .cannotComplete else { stop("pressing \"\(name)\" returned \(result.rawValue)", status: 1) }
}

// [LAW:no-ambient-temporal-coupling] The wait is on the control being there and enabled, polled to a deadline.
let end = Date(timeIntervalSinceNow: waitSeconds)
while true {
    let found = controls(named: name)
    if let control = found.first(where: pressable) {
        press(control, name)
        exit(0)
    }
    // Present but disabled is open already, and pressing the toggle would close it.
    if found.isEmpty, let name = opener, let control = controls(named: name).first(where: pressable) {
        press(control, name)
        opener = nil
    }
    guard Date() < end else { stop("pid \(pid) showed no enabled \"\(name)\" within \(Int(waitSeconds)) s", status: 1) }
    Thread.sleep(forTimeInterval: 0.25)
}
