import Foundation
import Observation

/// The app's one device subscription and the list every view reads from it.
///
/// [LAW:one-source-of-truth] One subscription per process, held from launch: views derive from
/// this and never read IOBluetooth themselves.
@Observable @MainActor final class DevicesModel {
    private(set) var list = DeviceList()
    /// Set when the stream ends with an error: no event will follow, and the list is emptied rather than left stale.
    private(set) var failure: (any Error)?
    /// [LAW:types-are-the-program] exception: see BatteryModel.subscription; same reason.
    @ObservationIgnored nonisolated(unsafe) private var subscription: Task<Void, Never>?

    /// [LAW:composability] The model mirrors whatever events it is given: the app hands it
    /// `BluetoothDevices.events()`, a test a recorded stream with no Bluetooth in the room.
    init<Events: AsyncSequence & Sendable>(events: Events) where Events.Element == DeviceEvent {
        subscription = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self else { return }
                    self.list.apply(event)
                }
            } catch {
                BluetoothDevices.log.error("device subscription ended: \(String(describing: error), privacy: .public)")
                self?.list = DeviceList()
                self?.failure = error
            }
        }
    }

    deinit { subscription?.cancel() }
}
