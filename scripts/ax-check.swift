// The shared settings components, read the way VoiceOver reads them: through the accessibility
// tree of the running app's component gallery (Sources/.../ComponentGallery.swift).
//
//   swift scripts/ax-check.swift <pid of the app launched with -ComponentGallery>
//
// Exits 0 when every assertion holds, 1 with each failure named when not. This lives outside
// `make test` because SwiftUI builds its accessibility tree only for a client of the running
// app, and the test host cannot be that client. It needs the invoking process to be trusted for
// Accessibility (System Settings > Privacy & Security > Accessibility).
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ax-check.swift <pid>\n".utf8)); exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("ax-check: this process is not trusted for Accessibility\n".utf8)); exit(2)
}

struct Node {
    let element: AXUIElement
    let role: String
    /// Everything a client can read out for the element.
    let words: [String]
    let selected: Bool?
    let children: [Node]
    var all: [Node] { [self] + children.flatMap(\.all) }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func node(_ element: AXUIElement) -> Node {
    let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(node)
    let words = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXAttributedDescription", kAXHelpAttribute, kAXIdentifierAttribute]
        .compactMap { attribute(element, $0) }
        .compactMap { ($0 as? String) ?? ($0 as? NSAttributedString)?.string }
    return Node(element: element, role: attribute(element, kAXRoleAttribute) as? String ?? "", words: words,
                selected: attribute(element, kAXSelectedAttribute) as? Bool, children: children)
}

let app = AXUIElementCreateApplication(pid)
func gallery() -> Node? {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .first { attribute($0, kAXTitleAttribute) as? String == "Component Gallery" }
        .map(node)
}

var failures: [String] = []
func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

// The gallery opens a moment after launch.
var window = gallery()
for _ in 0..<50 where window == nil { Thread.sleep(forTimeInterval: 0.2); window = gallery() }
guard let window else { print("ax-check: the Component Gallery window never appeared"); exit(1) }

let all = window.all
let words = Set(all.flatMap(\.words))
for expected in ["Section Title", "Switch Row", "Switch description", "Popup Row", "Popup description",
                 "Info Row", "Info description", "Pills Row", "Pills description"] {
    expect(words.contains(expected), "\"\(expected)\" is not exposed")
}
expect(all.contains { $0.role == "AXCheckBox" || $0.role == "AXSwitch" }, "no switch control")
expect(all.contains { $0.role == "AXMenuButton" || $0.role == "AXPopUpButton" }, "no pop-up button")
expect(all.contains { $0.role == "AXButton" && $0.words.contains("Info") }, "no info button")

func pill(_ title: String) -> Node? { gallery()?.all.first { $0.role == "AXButton" && $0.words.contains(title) } }
for title in ["Day", "Week", "Month"] { expect(pill(title) != nil, "no \(title) pill") }
expect(pill("Week")?.selected == true && pill("Month")?.selected != true, "Week should start selected")
if let month = pill("Month") {
    AXUIElementPerformAction(month.element, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.5)
    expect(pill("Month")?.selected == true, "pressing Month did not select it")
    expect(pill("Week")?.selected != true, "Week stayed selected after Month was pressed")
}

if failures.isEmpty { print("ax-check: ok"); exit(0) }
failures.forEach { print("ax-check: FAIL \($0)") }
exit(1)
