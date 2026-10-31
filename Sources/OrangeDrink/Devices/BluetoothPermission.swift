@preconcurrency import CoreBluetooth

/// What macOS has been told about this app's use of Bluetooth.
///
/// [LAW:no-ambient-temporal-coupling] IOBluetooth's first call holds its thread until the person answers the prompt
/// (orange-distribution-kg2.73n), and CoreBluetooth asks the same question of the same TCC service without holding one.
/// So the wait lives here, as a stream to await, and `BluetoothDevices.events` starts IOBluetooth once it is over.
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

    /// Why a device list is empty for this permission, or nil when the list is empty because nothing is connected.
    var explanation: Phrase? {
        switch self {
        case .allowed: nil
        case .notDetermined: "Answer the Bluetooth prompt to see your devices."
        case .denied: "This app isn't allowed to use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth, then quit and reopen the app."
        }
    }

    /// Reports each update and returns at the first answer. A prompt left open is a wait with no end, and only the device
    /// list is held by it. Updates end without an answer only when the wait is cancelled, so nothing past it can run unanswered.
    static func answer(from updates: AsyncStream<CBManagerAuthorization>, report: (BluetoothPermission) -> Void) async throws {
        for await update in updates {
            let permission = BluetoothPermission(update)
            report(permission)
            guard permission == .notDetermined else {
                BluetoothDevices.log.notice("bluetooth permission answered: \(String(describing: permission), privacy: .public)")
                return
            }
        }
        throw CancellationError()
    }

    /// [LAW:effects-at-boundaries] The one edge that asks macOS. The read comes first because the manager's first delegate
    /// call is held until the prompt is answered. The stream holds the manager until the wait stops reading it.
    @Sendable static func updates() -> AsyncStream<CBManagerAuthorization> {
        AsyncStream { continuation in
            let authorization = CBManager.authorization
            BluetoothDevices.log.notice("bluetooth permission: read authorization \(authorization.rawValue, privacy: .public)")
            continuation.yield(authorization)
            let delegate = ManagerDelegate(continuation: continuation)
            let manager = CBCentralManager(delegate: delegate, queue: DispatchQueue(label: "BluetoothPermission"),
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            continuation.onTermination = { _ in withExtendedLifetime((manager, delegate)) {} }
        }
    }

    private final class ManagerDelegate: NSObject, CBCentralManagerDelegate, Sendable {
        private let continuation: AsyncStream<CBManagerAuthorization>.Continuation

        init(continuation: AsyncStream<CBManagerAuthorization>.Continuation) { self.continuation = continuation }

        /// [LAW:nothing-unseen] A prompt left open logs none of these; a wait that stalled logs one still not determined.
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            let authorization = CBManager.authorization
            BluetoothDevices.log.notice("bluetooth permission: state \(central.state.rawValue, privacy: .public), authorization \(authorization.rawValue, privacy: .public)")
            continuation.yield(authorization)
        }
    }
}
