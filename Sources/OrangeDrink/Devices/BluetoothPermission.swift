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
    @Sendable static func asks(timekeeper: any Timekeeper) -> AsyncStream<Ask> {
        asks(first: launchAsk, then: ask, timekeeper: timekeeper)
    }

    /// Asks `first`, then `then` each minute, for as long as the stream is read.
    ///
    /// [LAW:no-ambient-temporal-coupling] The minute that pays for a sweep pays for the ask before it, so there is one clock,
    /// and it does not wait on bluetoothd: an ask that says nothing by the minute's end is dropped as `.stalled`, and the
    /// minute being spent, the next is made at once. The one wait with no bound is an ask that said `.notDetermined`: a
    /// prompt is open for as long as a person leaves it, and there is no list to go stale behind it.
    static func asks(
        first: @escaping @Sendable () -> Updates, then ask: @escaping @Sendable () -> Updates, timekeeper: any Timekeeper
    ) -> AsyncStream<Ask> {
        AsyncStream { continuation in
            let task = Task {
                var next = first
                do {
                    while true {
                        let asked = try await answer(to: next(), timekeeper) { continuation.yield($0) }
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
        to updates: Updates, _ timekeeper: any Timekeeper, prompted: (Ask) -> Void
    ) async throws -> Ask {
        guard let update = try await firstUpdate(of: updates, within: BluetoothDevices.pollInterval, timekeeper) else {
            BluetoothDevices.log.error("bluetooth permission: no answer within the minute, the last one stands")
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

    /// `updates`' first element, or nil if `bound` passes first. The stream stays with the caller, so a prompt's wait can go on
    /// reading it. It ends with no element only when cancelled, which throws.
    private static func firstUpdate(
        of updates: Updates, within bound: Duration, _ timekeeper: any Timekeeper
    ) async throws -> CBManagerAuthorization? {
        try await withThrowingTaskGroup(of: CBManagerAuthorization?.self) { race in
            defer { race.cancelAll() }
            race.addTask {
                var iterator = updates.makeAsyncIterator()
                guard let update = await iterator.next() else { throw CancellationError() }
                return update
            }
            race.addTask {
                try await timekeeper.sleep(for: bound)
                return nil
            }
            return try await race.next() ?? nil
        }
    }

    /// The launch's ask. The property is true at launch, so an answered launch makes no manager and waits on no delegate call.
    @Sendable static func launchAsk() -> Updates {
        let authorization = CBManager.authorization
        return authorization == .notDetermined ? ask() : AsyncStream { $0.yield(authorization) }
    }

    /// [LAW:effects-at-boundaries] The one edge that asks macOS, through a new manager, because only a new one hears a change
    /// made under a running app. In the VM, with the permission taken away, the app lives on, a manager it already holds hears
    /// nothing, and `CBManager.authorization` goes on saying allowed (orange-devices-bue.4gw). The property is yielded only
    /// for the one case the manager's first delegate call is held for, the open prompt. The stream holds the manager until
    /// the ask is dropped.
    @Sendable static func ask() -> Updates {
        AsyncStream { continuation in
            let authorization = CBManager.authorization
            BluetoothDevices.log.log(level: logLevel(of: authorization), "bluetooth permission: read authorization \(authorization.rawValue, privacy: .public)")
            if authorization == .notDetermined { continuation.yield(authorization) }
            let delegate = ManagerDelegate(continuation: continuation)
            let manager = CBCentralManager(delegate: delegate, queue: DispatchQueue(label: "BluetoothPermission"),
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            continuation.onTermination = { _ in withExtendedLifetime((manager, delegate)) {} }
        }
    }

    /// [LAW:nothing-unseen] A stalled prompt stays in the persisted log; an idle app's ask a minute does not.
    private static func logLevel(of authorization: CBManagerAuthorization) -> OSLogType {
        authorization == .notDetermined ? .default : .info
    }

    private final class ManagerDelegate: NSObject, CBCentralManagerDelegate, Sendable {
        private let continuation: AsyncStream<CBManagerAuthorization>.Continuation

        init(continuation: AsyncStream<CBManagerAuthorization>.Continuation) { self.continuation = continuation }

        /// A prompt left open logs none of these; a wait that stalled logs one still not determined.
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            let authorization = CBManagerAuthorization(state: central.state, authorization: CBManager.authorization)
            BluetoothDevices.log.log(level: logLevel(of: authorization), "bluetooth permission: state \(central.state.rawValue, privacy: .public), authorization \(authorization.rawValue, privacy: .public)")
            continuation.yield(authorization)
        }
    }
}

extension CBManagerAuthorization {
    /// [LAW:one-source-of-truth] The state is the live word on a refusal, because the property can be stale in a running
    /// process. Any other state says nothing of permission: Bluetooth off, or no radio, reads as what the property says.
    init(state: CBManagerState, authorization: CBManagerAuthorization) {
        self = state == .unauthorized ? .denied : authorization
    }
}
