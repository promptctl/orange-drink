@preconcurrency import CoreBluetooth
import os

/// What macOS has been told about this app's use of Bluetooth.
///
/// [LAW:no-ambient-temporal-coupling] IOBluetooth's first call holds its thread until the person answers the prompt
/// (orange-distribution-kg2.73n), and CoreBluetooth asks the same question of the same TCC service without holding one.
/// So the wait lives here, as a stream to await, and `BluetoothDevices.events` starts IOBluetooth once it is over and stops
/// it again if the answer changes.
enum BluetoothPermission: Equatable, Sendable {
    case allowed
    case notDetermined
    case denied

    /// [LAW:parse-dont-validate] Restricted is denied by a profile instead of a person: neither gives devices.
    init(_ authorization: CBManagerAuthorization) {
        switch authorization {
        case .allowedAlways: self = .allowed
        case .notDetermined: self = .notDetermined
        case .restricted, .denied: self = .denied
        @unknown default: self = .denied
        }
    }

    /// What one ask of macOS came to: what it said, or nothing within the minute that bounds it.
    enum Ask: Equatable, Sendable {
        case heard(BluetoothPermission)
        case stalled
    }

    typealias Updates = AsyncStream<CBManagerAuthorization>

    /// The app's asks: the launch's, then a new manager's every minute.
    static func asks(timekeeper: any Timekeeper, log: Logger) -> AsyncStream<Ask> {
        asks(first: { launchAsk(log: log) }, then: { ask(log: log) }, timekeeper: timekeeper, log: log)
    }

    /// Asks `first`, then `then` each minute, for as long as the stream is read.
    ///
    /// [LAW:no-ambient-temporal-coupling] The minute that pays for a sweep pays for the ask before it, so there is one clock,
    /// and it does not wait on bluetoothd: an ask that says nothing by the minute's end is dropped as `.stalled`, and the
    /// minute being spent, the next is made at once. The one wait with no bound is an ask that said `.notDetermined`: a
    /// prompt is open for as long as a person leaves it, and there is no list to go stale behind it.
    static func asks(
        first: @escaping @Sendable () -> Updates, then ask: @escaping @Sendable () -> Updates, timekeeper: any Timekeeper, log: Logger
    ) -> AsyncStream<Ask> {
        AsyncStream { continuation in
            let task = Task {
                var next = first
                do {
                    while true {
                        let asked = try await answer(to: next(), timekeeper, log: log) { continuation.yield($0) }
                        next = ask
                        continuation.yield(asked)
                        if asked != .stalled { try await timekeeper.sleep(for: BluetoothDevices.pollInterval) }
                    }
                } catch {
                    // Only a cancelled task throws here, and a cancel ends in one of these throws whatever it cut short,
                    // so nothing asks again.
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What one ask came to. `updates` ends with this call, which drops the ask and releases its manager.
    private static func answer(
        to updates: Updates, _ timekeeper: any Timekeeper, log: Logger, prompted: (Ask) -> Void
    ) async throws -> Ask {
        guard let update = try await firstUpdate(of: updates, timekeeper) else {
            log.error("bluetooth permission: no answer within the minute, the last one stands")
            return .stalled
        }
        var permission = BluetoothPermission(update)
        if permission == .notDetermined {
            prompted(.heard(permission))
            for await later in updates {
                permission = BluetoothPermission(later)
                if permission != .notDetermined { break }
            }
        }
        return .heard(permission)
    }

    /// `updates`' first element, or nil if the minute passes first. The stream stays with the caller, so a prompt's wait can go
    /// on reading it. It ends with no element only when cancelled, which throws.
    private static func firstUpdate(of updates: Updates, _ timekeeper: any Timekeeper) async throws -> CBManagerAuthorization? {
        try await withThrowingTaskGroup(of: CBManagerAuthorization?.self) { race in
            defer { race.cancelAll() }
            race.addTask {
                var iterator = updates.makeAsyncIterator()
                guard let update = await iterator.next() else { throw CancellationError() }
                return update
            }
            race.addTask {
                try await timekeeper.sleep(for: BluetoothDevices.pollInterval)
                return nil
            }
            return try await race.next() ?? nil
        }
    }

    /// The launch's ask. The property is true at launch, so an answered launch makes no manager and waits on no delegate call.
    static func launchAsk(log: Logger) -> Updates {
        let authorization = CBManager.authorization
        return authorization == .notDetermined ? ask(log: log) : AsyncStream { $0.yield(authorization) }
    }

    /// [LAW:effects-at-boundaries] The one edge that asks macOS, through a new manager, because only a new one hears a change
    /// made under a running app. In the VM, with the permission taken away, the app lives on, a manager it already holds hears
    /// nothing, and `CBManager.authorization` goes on saying allowed (orange-devices-bue.4gw). The property is yielded only
    /// for the one case the manager's first delegate call is held for, the open prompt. The stream holds the manager until
    /// the ask is dropped.
    static func ask(log: Logger) -> Updates {
        AsyncStream { continuation in
            let authorization = CBManager.authorization
            log.log(level: logLevel(of: authorization), "bluetooth permission: read authorization \(authorization.rawValue, privacy: .public)")
            if authorization == .notDetermined { continuation.yield(authorization) }
            let delegate = ManagerDelegate(continuation: continuation, log: log)
            let manager = CBCentralManager(delegate: delegate, queue: DispatchQueue(label: "BluetoothPermission"),
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            continuation.onTermination = { _ in withExtendedLifetime((manager, delegate)) {} }
        }
    }

    /// [LAW:nothing-unseen] A stalled prompt stays in the persisted log; an idle app's ask a minute does not.
    private static func logLevel(of authorization: CBManagerAuthorization?) -> OSLogType {
        authorization == .notDetermined ? .default : .info
    }

    private final class ManagerDelegate: NSObject, CBCentralManagerDelegate, Sendable {
        private let continuation: AsyncStream<CBManagerAuthorization>.Continuation
        private let log: Logger

        init(continuation: AsyncStream<CBManagerAuthorization>.Continuation, log: Logger) {
            self.continuation = continuation
            self.log = log
        }

        /// A prompt left open logs none of these; a wait that stalled logs one still not determined.
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            let authorization = CBManagerAuthorization(state: central.state, authorization: CBManager.authorization)
            let said = authorization.map { String($0.rawValue) } ?? "none yet"
            log.log(level: logLevel(of: authorization), "bluetooth permission: state \(central.state.rawValue, privacy: .public), authorization \(said, privacy: .public)")
            if let authorization { continuation.yield(authorization) }
        }
    }
}

extension CBManagerAuthorization {
    /// [LAW:one-source-of-truth] The state is the live word on a refusal, because the property can be stale in a running
    /// process. Bluetooth off, or no radio, says nothing of permission and reads as what the property says. Unknown and
    /// resetting are CoreBluetooth's own "an update is imminent": no answer yet, so a stale allowed cannot end the ask.
    init?(state: CBManagerState, authorization: CBManagerAuthorization) {
        switch state {
        case .unauthorized: self = .denied
        case .unknown, .resetting: return nil
        default: self = authorization
        }
    }
}
