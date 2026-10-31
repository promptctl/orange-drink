import ApplicationServices

/// One read of an accessibility element. A value that is not there and a read that failed are different facts: only the
/// second says nothing about what is showing.
enum ElementRead<Value: Sendable>: Sendable {
    case value(Value)
    case absent
    case failed(AXError)
}

/// An element of another app's accessibility tree, as far as the look and the close use one.
protocol AccessibleElement: Sendable {
    func string(_ attribute: String) -> ElementRead<String>
    var children: ElementRead<[any AccessibleElement]> { get }
    var actions: ElementRead<[String]> { get }
    func press(_ action: String) -> AXError
}

/// A notification and the element to close it through.
struct ShownNotification: Sendable {
    let values: NotificationValues
    let element: any AccessibleElement
}

/// Why a look cannot say what is showing.
enum LookFailure: Error, Equatable, Sendable {
    case notRunning
    case read(attribute: String, error: AXError)
    case pastBound

    var reason: String {
        switch self {
        case .notRunning: "NotificationCenter is not running"
        case .read(let attribute, let error): "reading \(attribute) failed with AXError \(error.rawValue)"
        case .pastBound: "the tree went past the bound"
        }
    }
}

/// What NotificationCenter is showing.
///
/// Only the `AXSystemDialog` window holds notifications. Its other windows are desktop widgets, whose trees loop, and
/// walking them overflowed the stack on a real Mac.
enum NotificationCenterLook {
    static let notificationWindow = "AXSystemDialog"
    /// [LAW:single-enforcer] The one bound on a tree another process owns. A cycle reaches the depth, so nothing keeps a
    /// visited set. A real notification sits a few levels down.
    static let depthBound = 16
    static let visitBound = 2000

    static func look(windows: ElementRead<[any AccessibleElement]>) -> Result<[ShownNotification], LookFailure> {
        Result { () throws(LookFailure) in
            var walk = Walk()
            for window in try walk.read(windows, "AXWindows") ?? [] where try walk.read(window.string("AXSubrole"), "AXSubrole") == notificationWindow {
                try walk.visit(window, depth: 0)
            }
            return walk.found
        }
    }

    private struct Walk {
        var found: [ShownNotification] = []
        private var visited = 0

        /// [LAW:parse-dont-validate] An element that goes away mid-look is absent, as it is for a notification just closed.
        func read<Value>(_ read: ElementRead<Value>, _ attribute: String) throws(LookFailure) -> Value? {
            switch read {
            case .value(let value): value
            case .absent: nil
            case .failed(let error): throw .read(attribute: attribute, error: error)
            }
        }

        mutating func visit(_ element: any AccessibleElement, depth: Int) throws(LookFailure) {
            visited += 1
            guard depth <= depthBound, visited <= visitBound else { throw .pastBound }
            let children = try read(element.children, "AXChildren") ?? []
            if let subrole = try read(element.string("AXSubrole"), "AXSubrole"), subrole.hasPrefix("AXNotificationCenter") {
                found.append(ShownNotification(values: try values(of: element, subrole: subrole, children: children), element: element))
            }
            for child in children { try visit(child, depth: depth + 1) }
        }

        private func values(of element: any AccessibleElement, subrole: String, children: [any AccessibleElement]) throws(LookFailure) -> NotificationValues {
            func text(_ identifier: String) throws(LookFailure) -> String {
                for child in children where try read(child.string("AXIdentifier"), "AXIdentifier") == identifier {
                    return try read(child.string("AXValue"), "AXValue") ?? ""
                }
                return ""
            }
            return NotificationValues(subrole: subrole, title: try text("title"), body: try text("body"),
                                      description: try read(element.string("AXDescription"), "AXDescription") ?? "",
                                      actions: try read(element.actions, "actions") ?? [])
        }
    }
}
