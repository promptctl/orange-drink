import OSLog
import SwiftUI

/// What a settings view edits one kept value with: its current value, a change to it, and bindings
/// that make a change when a control sets them.
///
/// [LAW:single-enforcer] Every settings edit goes through `perform`, so "a change that cannot be kept is
/// shown, not dropped" is enforced here and nowhere else.
@MainActor struct SettingEdits<Value> {
    /// What happened to one change, as the log, the failure line, and the tests read it.
    enum Event: Equatable {
        /// The change was kept; `value` is the setting as it now stands.
        case saved(setting: String, value: String)
        /// The change could not be kept, and the setting is as it was.
        case notSaved(setting: String, reason: String)

        /// [LAW:effects-at-boundaries] The log line, a pure function of the event.
        var line: String {
            switch self {
            case .saved(let setting, let value): "\(setting) saved: \(value)"
            case .notSaved(let setting, let reason): "\(setting) not saved: \(reason)"
            }
        }

        /// What the view shows above its controls after this change: nothing once a change is kept.
        var failure: String? {
            switch self {
            case .saved: nil
            case .notSaved(_, let reason): reason
            }
        }
    }

    let setting: String
    let read: () -> Value
    let update: ((inout Value) -> Void) throws -> Void
    let record: (Event) -> Void

    var value: Value { read() }

    func perform(_ edit: (inout Value) -> Void) {
        do {
            try update(edit)
            record(.saved(setting: setting, value: String(describing: read())))
        } catch {
            record(.notSaved(setting: setting, reason: error.localizedDescription))
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<Value, T> & Sendable) -> Binding<T> {
        Binding(get: { read()[keyPath: keyPath] }, set: { new in perform { $0[keyPath: keyPath] = new } })
    }
}

private let settingsLog = Logger(subsystem: IOKitBattery.logSubsystem, category: "settings")

/// A part of a settings screen that edits one kept value: its content, and above it, in red, why the last
/// change could not be kept.
///
/// [LAW:no-silent-failure] The editor draws the failure itself, so no content can hold the edits and drop
/// what they report.
struct SettingEditor<Value, Content: View>: View {
    let setting: String
    let read: () -> Value
    let update: ((inout Value) -> Void) throws -> Void
    @ViewBuilder let content: (SettingEdits<Value>) -> Content
    @State private var failure: String?

    init(setting: String, read: @escaping () -> Value, update: @escaping ((inout Value) -> Void) throws -> Void,
         @ViewBuilder content: @escaping (SettingEdits<Value>) -> Content) {
        self.setting = setting
        self.read = read
        self.update = update
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure {
                Label("Could not save: \(failure)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            content(SettingEdits(setting: setting, read: read, update: update) { event in
                settingsLog.notice("\(event.line, privacy: .public)")
                failure = event.failure
            })
        }
    }
}

extension SettingEditor where Value: Stored {
    init(_ model: StoredModel<Value>, @ViewBuilder content: @escaping (SettingEdits<Value>) -> Content) {
        self.init(setting: Value.storageKey, read: { model.value }, update: model.update, content: content)
    }
}
