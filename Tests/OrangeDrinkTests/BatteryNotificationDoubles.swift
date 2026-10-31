import ApplicationServices
import Foundation
import IOKit.ps
import os
@testable import OrangeDrink

/// An element of the stand-in tree. `kids` is a variable so a test can close a cycle.
final class RecordedElement: AccessibleElement, @unchecked Sendable {
    var strings: [String: String]
    var kids: [any AccessibleElement]
    var actionNames: [String]
    /// A read of one of these names fails, for AXChildren and actions as well as strings.
    var failing: [String: AXError] = [:]
    var pressed: @Sendable (String) -> AXError = { _ in .success }

    init(strings: [String: String] = [:], kids: [any AccessibleElement] = [], actions: [String] = []) {
        self.strings = strings
        self.kids = kids
        actionNames = actions
    }

    /// The window notifications show in, or another of NotificationCenter's.
    static func window(subrole: String = NotificationCenterLook.notificationWindow, _ kids: [any AccessibleElement]) -> RecordedElement {
        RecordedElement(strings: ["AXSubrole": subrole], kids: kids)
    }

    /// A notification, one level down in a scroll area as on macOS 26.
    static func notification(_ values: NotificationValues, pressed: @escaping @Sendable (String) -> AXError = { _ in .success }) -> RecordedElement {
        let element = RecordedElement(strings: ["AXSubrole": values.subrole, "AXDescription": values.description], kids: [
            RecordedElement(strings: ["AXIdentifier": "title", "AXValue": values.title]),
            RecordedElement(strings: ["AXIdentifier": "body", "AXValue": values.body]),
        ], actions: values.actions)
        element.pressed = pressed
        return RecordedElement(kids: [element])
    }

    func string(_ attribute: String) -> ElementRead<String> {
        if let error = failing[attribute] { return .failed(error) }
        return strings[attribute].map { .value($0) } ?? .absent
    }

    var children: ElementRead<[any AccessibleElement]> {
        if let error = failing["AXChildren"] { return .failed(error) }
        return .value(kids)
    }

    var actions: ElementRead<[String]> {
        if let error = failing["actions"] { return .failed(error) }
        return .value(actionNames)
    }

    func press(_ action: String) -> AXError { pressed(action) }
}

/// macOS as BatteryNotificationDismissal sees it: the level, trust, NotificationCenter, and the tables. Pressing an alert
/// closes it unless a test says otherwise.
final class FakeMac: @unchecked Sendable {
    struct State {
        var level = kIOPSLowBatteryWarningNone
        var trusted = true
        var notificationCenter: pid_t? = 501
        var showing: [NotificationValues] = []
        var words: Result<Set<LowBatteryWords>, LowBatteryTables.Failure> = .success(NotificationFixtures.words)
        /// What a press returns, and whether it takes the notification away.
        var pressReturns = AXError.success
        var pressCloses = true
        /// What shows after a press, for a notification that changes rather than goes.
        var pressLeaves: NotificationValues?
        var windowsRead: ElementRead<[any AccessibleElement]>?
        var failLookAfterPress: AXError?
        var observeFails: AXError?

        var presses: [String] = []
        var trustAsks: [Bool] = []
        var looks = 0
        var tableReads = 0
        var watched: pid_t?
        var watches: [pid_t] = []
        var onChange: (@Sendable () -> Void)?
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    func with<Value: Sendable>(_ body: @Sendable (inout State) -> Value) -> Value { state.withLock(body) }

    var presses: [String] { with { $0.presses } }
    var looks: Int { with { $0.looks } }
    var promptAsks: Int { with { $0.trustAsks.filter(\.self).count } }

    /// NotificationCenter's layout changing, which reaches only an app watching it.
    func layoutChanged() { with { $0.onChange }?() }

    private func windows() -> ElementRead<[any AccessibleElement]> {
        let (override, showing, failure) = with { state in
            state.looks += 1
            return (state.windowsRead, state.showing, state.presses.isEmpty ? nil : state.failLookAfterPress)
        }
        if let failure { return .failed(failure) }
        if let override { return override }
        return .value([RecordedElement.window(showing.map { values -> any AccessibleElement in
            RecordedElement.notification(values) { [self] action in
                with { state in
                    state.presses.append(action)
                    if state.pressCloses { state.showing.removeAll { $0 == values } }
                    if let left = state.pressLeaves { state.showing = [left] }
                    return state.pressReturns
                }
            }
        })])
    }

    var effects: BatteryNotificationDismissal.Effects {
        BatteryNotificationDismissal.Effects(
            level: { self.with { $0.level } },
            trust: { prompt in self.with { $0.trustAsks.append(prompt); return $0.trusted } },
            notificationCenter: { self.with { $0.notificationCenter } },
            windows: { _ in self.windows() },
            observe: { pid, onChange in
                self.with { state in
                    if let error = state.observeFails { return .failure(.init(error: error)) }
                    state.watched = pid
                    state.watches.append(pid)
                    state.onChange = onChange
                    return .success(.init(pid: pid, stop: { self.with { $0.watched = nil; $0.onChange = nil } }))
                }
            },
            tables: { self.with { $0.tableReads += 1; return $0.words } })
    }
}
