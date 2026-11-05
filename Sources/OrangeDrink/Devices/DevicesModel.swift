import Foundation
import Observation
import os

/// The app's one device subscription and the list every view reads from it.
///
/// [LAW:one-source-of-truth] One subscription per process, held from launch: views derive from
/// this and never read IOBluetooth themselves.
@Observable @MainActor final class DevicesModel {
    private(set) var list: DeviceList
    /// [LAW:types-are-the-program] exception: see BatteryModel.subscription; same reason.
    @ObservationIgnored nonisolated(unsafe) private var subscriptions: [Task<Void, Never>] = []

    /// [LAW:composability] The model mirrors whatever events it is given: the app hands it
    /// `BluetoothDevices.events()`, a test a recorded stream with no Bluetooth in the room.
    /// `onChange` is told of the list after every event and once more when a source ends, so what acts on it (device
    /// alerts) sees every list and never watches `list`.
    ///
    /// A source is its stream under its tag, one stream to a tag. Each is followed on its own, so a source failing or
    /// ending leaves the others' devices listed.
    init(sources: [DeviceSource: AsyncThrowingStream<DeviceEvent, any Error>], log: Logger, onChange: @escaping @MainActor (DeviceList) -> Void = { _ in }) {
        precondition(!sources.isEmpty, "a device list of no sources would read waiting for ever")
        list = DeviceList(sources: sources.keys)
        // The weak reference is re-taken per event: a strong one held across a stream would keep the model alive for good.
        let model: @Sendable () -> DevicesModel? = { [weak self] in self }
        subscriptions = sources.map { source, events in
            Task { await DevicesModel.follow(source, events, model: model, log: log, onChange: onChange) }
        }
    }

    private static func follow(
        _ source: DeviceSource, _ events: AsyncThrowingStream<DeviceEvent, any Error>,
        model: @Sendable () -> DevicesModel?, log: Logger, onChange: @MainActor (DeviceList) -> Void
    ) async {
        let ending: any Error
        do {
            for try await event in events {
                guard let model = model() else { return }
                // [LAW:no-silent-failure] A stream reports devices of its own source, and the list ignores any other's. One that
                // reports another's is a mapper bug the list cannot know of, so it is said here, where the stream and its tag
                // meet. The key is a Bluetooth address or a device ID, so only the sources are named.
                for other in Set(event.ids.map(\.source)).subtracting([source]).sorted(by: { $0.rawValue < $1.rawValue }) {
                    log.error("device source \(source.rawValue, privacy: .public) reported a device of \(other.rawValue, privacy: .public); ignored")
                }
                let contestedBefore = Set(model.list.contested)
                model.list.apply(event, from: source)
                // [LAW:no-silent-failure] Two devices claiming one Bluetooth address are not merged, which a screen shows only as
                // extra rows, so the fault is said here, where the list is first seen to hold it. Once per address, not at every
                // relist of a phone on Wi-Fi.
                for address in Set(model.list.contested).subtracting(contestedBefore).sorted() {
                    log.error("device list: more than one device claims Bluetooth address \(address, privacy: .private); their rows are not merged")
                }
                onChange(model.list)
            }
            ending = DevicesModelError.streamFinished
        } catch {
            ending = error
        }
        // deinit cancelled the task: the model is gone, nobody is left to report an ended stream to.
        guard let model = model() else { return }
        log.error("device source ended: \(source.rawValue, privacy: .public): \(String(describing: ending), privacy: .public)")
        model.list.end(source)
        onChange(model.list)
    }

    deinit { subscriptions.forEach { $0.cancel() } }
}

enum DevicesModelError: Error {
    /// The event stream finished; a live device source never does.
    case streamFinished
}
