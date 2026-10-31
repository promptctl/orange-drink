import AppKit
import Observation
import OSLog
import ServiceManagement

/// Whether macOS starts the app at login, as the General screen's switch shows and changes it.
///
/// [LAW:one-source-of-truth] The system holds the state, and the user can change it in System Settings, so nothing here
/// is stored. `status` is a live copy of SMAppService's answer, and nil until it has first answered.
@Observable @MainActor final class LaunchAtLogin {
    /// One call on the system. A change ends in a read, so every call answers with the status.
    enum Call: Equatable, Sendable {
        case read
        case set(Bool)
    }

    /// Why a press did not reach what it asked for.
    enum Refusal: Equatable {
        /// macOS holds a login item while the app's Allow in the Background is off, as it is on a new install, since the
        /// helper's record shares that switch. The user turns it on in System Settings, and nothing here can.
        case needsApproval
        case failed(String)

        /// [LAW:one-source-of-truth] A press is judged by the status after it, not by whether it threw, since macOS can
        /// throw for an item already registered. A read asks for nothing, so it refuses nothing.
        init?(_ call: Call, status: SMAppService.Status, error: String?) {
            guard case .set(let wanted) = call, (status == .enabled) != wanted else { return nil }
            self = status == .requiresApproval ? .needsApproval : .failed(error ?? status.name)
        }

        /// What the row says under the switch, as the screen shows it and the catalog test reads it.
        func explanation(appName: String) -> Phrase {
            switch self {
            case .needsApproval: "Allow \(appName) in the background to start it at login."
            case .failed(let reason): "Couldn't change Launch at Login: \(reason)"
            }
        }
    }

    /// What happened, as the log and the tests read it. A call stays `asked` until it is `answered`, so a line with no
    /// answer after it is a call the system has not returned from, and an `ignored` shows what that held up.
    enum Event: Equatable {
        case asked(Call)
        /// Another call was unanswered, so this one was not made.
        case ignored(Call)
        case answered(Call, status: String, error: String?)
        case openedLoginItems

        /// [LAW:effects-at-boundaries] The log line, a pure function of the event. scripts/login-item-check reads `answered`.
        var line: String {
            switch self {
            case .asked(let call): "launch at login \(call.name): asked"
            case .ignored(let call): "launch at login \(call.name): ignored, another call is unanswered"
            case .answered(let call, let status, nil): "launch at login \(call.name): status \(status)"
            case .answered(let call, let status, let error?): "launch at login \(call.name): status \(status); \(error)"
            case .openedLoginItems: "opened Login Items & Extensions to allow the login item"
            }
        }
    }

    /// The system calls a `Call` makes, as one seam.
    struct Effects: Sendable {
        /// SMAppService's register and unregister: the error each gave, or nil.
        let register: @Sendable () -> NSError?
        let unregister: @Sendable () -> NSError?
        let status: @Sendable () -> SMAppService.Status

        static let live = Effects(register: { HelperRegistration.attempt(SMAppService.mainApp.register) },
                                  unregister: { HelperRegistration.attempt(SMAppService.mainApp.unregister) },
                                  status: { SMAppService.mainApp.status })

        fileprivate func answer(_ call: Call) -> (status: SMAppService.Status, error: String?) {
            let error: NSError? = switch call {
            case .read: nil
            case .set(true): register()
            case .set(false): unregister()
            }
            return (status(), error.map(HelperRegistration.describe))
        }
    }

    private(set) var status: SMAppService.Status?
    /// Why the last press did not take; any later answer replaces it, so coming back from System Settings clears advice
    /// the user may have taken, and someone who turned the item off there sees a plain switch.
    private(set) var refusal: Refusal?
    /// [LAW:no-ambient-temporal-coupling] The one call in flight, from its start to its answer, and nothing else ends it.
    private(set) var asking: Task<Void, Never>?

    /// What macOS starts at login, so the other statuses read off, the one that waits for the user's approval included.
    var isOn: Bool { status == .enabled }

    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private let record: (Event) -> Void
    @ObservationIgnored private let openLoginItemsPane: () -> Void

    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "launchAtLogin")

    /// [LAW:composability] `center` posts the app's activations. The app passes the live effects, the default center,
    /// the log, and System Settings. The first read starts here and answers off the launch's main thread.
    init(effects: Effects, center: NotificationCenter,
         record: @escaping (Event) -> Void = { event in LaunchAtLogin.log.notice("\(event.line, privacy: .public)") },
         openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.effects = effects
        self.record = record
        openLoginItemsPane = openLoginItems
        // The observer lives as long as the center; the app's model lives as long as the app.
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask(.read) }
        }
        ask(.read)
    }

    func set(_ on: Bool) {
        ask(.set(on))
    }

    /// Opens Login Items & Extensions, where the user allows the login item.
    func openLoginItems() {
        openLoginItemsPane()
        record(.openedLoginItems)
    }

    /// [LAW:single-enforcer] Every call goes through here, one at a time and off the main thread: each is a round trip to
    /// the background-task daemons with no timeout of ours, and a stuck one must stall neither launch nor the menu bar. It
    /// stays `asked`, since a call that cannot be cancelled would only be relabelled by a deadline.
    private func ask(_ call: Call) {
        guard asking == nil else {
            record(.ignored(call))
            return
        }
        record(.asked(call))
        let effects = effects
        asking = Task {
            let answer = await blocking { effects.answer(call) }
            status = answer.status
            refusal = Refusal(call, status: answer.status, error: answer.error)
            asking = nil
            record(.answered(call, status: answer.status.name, error: answer.error))
        }
    }
}

extension LaunchAtLogin.Call {
    fileprivate var name: String {
        switch self {
        case .read: "read"
        case .set(true): "on"
        case .set(false): "off"
        }
    }
}
