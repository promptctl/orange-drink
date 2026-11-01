// What scripts/widget-click-check does to a VM's desktop and reads back from it. Posting an event needs the trust a process
// `tart exec` starts has.
//   desktop click <x> <y>                    one left click at that point, in points from the top left of the display
//   desktop double-click <x> <y> <gap ms>    two, in one process because two `tart exec` calls cannot hold a gap
//   desktop windows <owner>                  one line per window of that owner on screen: layer, then x y width height
//   desktop covering <x> <y>...              one line per owner of a window over any of those points
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("desktop: \(message)\n".utf8))
    exit(1)
}

func press(at point: CGPoint, clickCount: Int64) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { fail("no \(type) event") }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

func moveTo(_ point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { fail("no move event") }
    event.post(tap: .cghidEventTap)
    usleep(200_000)
}

func point(_ x: String, _ y: String) -> CGPoint {
    guard let x = Double(x), let y = Double(y) else { fail("not a point: \(x) \(y)") }
    return CGPoint(x: x, y: y)
}

struct Window {
    let owner: String
    let layer: Int
    let bounds: CGRect
}

// The window list promises a layer and bounds, so one without is a list that cannot be read. An owner's name is optional.
func onScreenWindows() -> [Window] {
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { fail("no window list") }
    return list.map { window in
        guard let layer = window[kCGWindowLayer as String] as? Int,
              let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { fail("unreadable window: \(window)") }
        return Window(owner: window[kCGWindowOwnerName as String] as? String ?? "?", layer: layer, bounds: bounds)
    }
}

func windows(of owner: String) {
    for window in onScreenWindows() where window.owner == owner {
        print(window.layer, window.bounds.minX, window.bounds.minY, window.bounds.width, window.bounds.height)
    }
}

// A widget sits at a negative layer, and from the Dock's layer, 20, up are overlays that cover the whole display and take no
// click. So what can sit over a widget is layers 0 to 19: apps' windows and their alerts.
func covering(_ points: [CGPoint]) {
    let over = onScreenWindows().filter { (0..<20).contains($0.layer) && points.contains(where: $0.bounds.contains) }
    for owner in Set(over.map(\.owner)) { print(owner) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("click", 3):
    let target = point(arguments[1], arguments[2])
    moveTo(target)
    press(at: target, clickCount: 1)
case ("double-click", 4):
    guard let gap = useconds_t(arguments[3]) else { fail("not a gap: \(arguments[3])") }
    let target = point(arguments[1], arguments[2])
    moveTo(target)
    press(at: target, clickCount: 1)
    usleep(gap * 1000)
    press(at: target, clickCount: 2)
case ("windows", 2):
    windows(of: arguments[1])
case ("covering", let count) where count > 1 && count % 2 == 1:
    covering(stride(from: 1, to: count, by: 2).map { point(arguments[$0], arguments[$0 + 1]) })
default:
    fail("usage: click <x> <y> | double-click <x> <y> <gap ms> | windows <owner> | covering <x> <y>...")
}
