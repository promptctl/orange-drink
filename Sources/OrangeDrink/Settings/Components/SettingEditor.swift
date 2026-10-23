import OSLog
import SwiftUI

/// What happened to one settings edit, as the log, the failure line, and the tests read it.
enum SettingEvent: Equatable {
    /// The change was kept; `value` is the setting as it now stands.
    case saved(setting: String, value: String)
    /// The change could not be kept, and the setting is as it was.
    case notSaved(setting: String, reason: String)

    /// What the view shows above its controls after this change: nothing once a change is kept.
    var failure: String? {
        switch self {
        case .saved: nil
        case .notSaved(_, let reason): reason
        }
    }

    static let logCategory = "settings"
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: logCategory)

    /// A value can name the user's devices, so it is private; which setting, and why a save failed, are not.
    fileprivate func emit() {
        switch self {
        case .saved(let setting, let value): Self.log.notice("\(setting, privacy: .public) saved: \(value, privacy: .private)")
        case .notSaved(let setting, let reason): Self.log.error("\(setting, privacy: .public) not saved: \(reason, privacy: .public)")
        }
    }
}

/// What a settings view edits one kept value with: its current value, a change to it, and bindings
/// that make a change when a control sets them.
///
/// [LAW:single-enforcer] Every screen that edits a kept value directly goes through `perform`, so "a change
/// that cannot be kept is logged and shown, not dropped" is enforced here for all of them. (Shortcuts are
/// recorded through ShortcutsController, which also registers them with the system and refuses taken keys.)
@MainActor struct SettingEdits<Value> {
    let setting: String
    let read: () -> Value
    let update: ((inout Value) -> Void) throws -> Void
    let record: (SettingEvent) -> Void

    var value: Value { read() }

    func perform(_ edit: (inout Value) -> Void) {
        let event: SettingEvent
        do {
            try update(edit)
            event = .saved(setting: setting, value: String(describing: read()))
        } catch {
            event = .notSaved(setting: setting, reason: error.localizedDescription)
        }
        event.emit()
        record(event)
    }

    func binding<T>(_ keyPath: WritableKeyPath<Value, T> & Sendable) -> Binding<T> {
        Binding(get: { read()[keyPath: keyPath] }, set: { new in perform { $0[keyPath: keyPath] = new } })
    }
}

extension SettingEdits where Value: Stored {
    /// The edits of a stored value, named in the log by the key it is kept under.
    init(_ model: StoredModel<Value>, record: @escaping (SettingEvent) -> Void) {
        self.init(setting: Value.storageKey, read: { model.value }, update: model.update, record: record)
    }
}

/// A part of a settings screen that edits one kept value: its content, and above it, in red, why the last
/// change could not be kept.
///
/// [LAW:no-silent-failure] The editor draws the failure itself, so no content can hold the edits and drop
/// what they report.
struct SettingEditor<Value, Content: View>: View {
    /// The edits, given where to report what each one did.
    let edits: (@escaping (SettingEvent) -> Void) -> SettingEdits<Value>
    @ViewBuilder let content: (SettingEdits<Value>) -> Content
    @State private var failure: String?

    init(setting: String, read: @escaping () -> Value, update: @escaping ((inout Value) -> Void) throws -> Void,
         @ViewBuilder content: @escaping (SettingEdits<Value>) -> Content) {
        edits = { SettingEdits(setting: setting, read: read, update: update, record: $0) }
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure {
                Label("Could not save: \(failure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            content(edits { failure = $0.failure })
        }
    }
}

extension SettingEditor where Value: Stored {
    init(_ model: StoredModel<Value>, @ViewBuilder content: @escaping (SettingEdits<Value>) -> Content) {
        edits = { SettingEdits(model, record: $0) }
        self.content = content
    }
}
