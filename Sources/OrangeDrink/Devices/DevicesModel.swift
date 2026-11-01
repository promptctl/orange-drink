import Foundation
import Observation

/// The app's one device subscription and the list every view reads from it.
///
/// [LAW:one-source-of-truth] One subscription per process, held from launch: views derive from
/// this and never read IOBluetooth themselves.
@Observable @MainActor final class DevicesModel {
    private(set) var list = DeviceList()
    /// [LAW:types-are-the-program] exception: see BatteryModel.subscription; same reason.
    @ObservationIgnored nonisolated(unsafe) private var subscription: Task<Void, Never>?

    /// [LAW:composability] The model mirrors whatever events it is given: the app hands it
    /// `BluetoothDevices.events()`, a test a recorded stream with no Bluetooth in the room.
    /// `onChange` is told of the list after every event and once more when the stream ends, so what acts on it (device
    /// alerts) sees every list and never watches `list`.
    init<Events: AsyncSequence & Sendable>(
        events: Events, onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }
    ) where Events.Element == DeviceEvent {
        subscription = Task { [weak self] in
            let ending: any Error
            do {
                for try await event in events {
                    guard let self else { return }
                    self.list.apply(event)
                    onChange(self.list)
                }
                ending = DevicesModelError.streamFinished
            } catch {
                ending = error
            }
            // deinit cancelled the task: the model is gone, nobody is left to report an ended stream to.
            guard let self else { return }
            BluetoothDevices.log.error("device subscription ended: \(String(describing: ending), privacy: .public)")
            self.list.end()
            onChange(self.list)
        }
    }

    deinit { subscription?.cancel() }
}

enum DevicesModelError: Error {
    /// The event stream finished; a live device source never does.
    case streamFinished
}
