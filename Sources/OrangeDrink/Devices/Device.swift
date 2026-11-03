import Foundation

/// [LAW:types-are-the-program] What a device reports, and no more: a device with one battery, one
/// with earbuds and a case (each part may be missing, e.g. a bud out of its case), none at all, or
/// not known this read. An unreported level is absent; 0% is a reading, a drained battery.
enum DeviceLevels: Equatable, Sendable {
    case none
    /// Power management did not answer, so this device's levels are unknown, not absent.
    case unread
    case single(BatteryLevel)
    case earbuds(left: BatteryLevel?, right: BatteryLevel?, case: BatteryLevel?)

    /// The level an alert watches: what powers the device. A bud going into its case must not read as
    /// the level falling from the buds' to the case's, so the case is never the level.
    var alertLevel: BatteryLevel? {
        switch self {
        case .none, .unread: nil
        case .single(let level): level
        case .earbuds(let left, let right, _): [left, right].compactMap { $0 }.min { $0.percent < $1.percent }
        }
    }

    /// The level a one-number display shows: the earbud that runs out first; the case only when no
    /// earbud reports, because the case does not power playback.
    var lowest: BatteryLevel? {
        switch self {
        case .none, .unread: nil
        case .single(let level): level
        case .earbuds(let left, let right, let `case`): [left, right].compactMap { $0 }.min { $0.percent < $1.percent } ?? `case`
        }
    }
}

struct Device: Equatable, Sendable, Identifiable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    let levels: DeviceLevels

    /// [LAW:parse-dont-validate] The one place a device's name is chosen: the user's alias, else the
    /// name the device broadcasts, else its address. IOBluetooth answers "" for a name it does not
    /// have yet (orange-devices-bue.suy), so a blank is no name, never a name.
    static func name(alias: String?, broadcast: String?, address: String) -> String {
        [alias, broadcast].lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? address
    }

    /// False for a device known only by the address `name(alias:broadcast:address:)` fell back to.
    var hasName: Bool { name != id.key }
}

/// What the Bluetooth edge tells the list: a device's current state, that it is gone, or the
/// complete set of connected devices at one sweep.
///
/// [LAW:no-ambient-temporal-coupling] Connect and disconnect notifications and the sweep arrive from
/// different threads with no order between them, so a disconnect can land before the sweep that read
/// the device as connected. The sweep is the authority: it replaces the list, so any such race
/// is gone by the next sweep instead of leaving a device listed that is not there.
enum DeviceEvent: Equatable, Sendable {
    case reported(Device)
    case gone(DeviceID)
    case swept([Device])
    case permission(BluetoothPermission)
}

/// Every connected device the app knows of, from every source. [LAW:one-source-of-truth] The one
/// reduction from events to the list; nothing else holds a device.
///
/// A device is stored once, by its identity, and an identity names its source: which source a device
/// belongs to is read from it and never held a second time. What a source has told the list is its
/// reading; an event is applied *from* a source and touches only the devices whose identity names it, so a
/// source cannot add, remove or keep another's device. [LAW:single-enforcer] Here, in the one reduction.
struct DeviceList: Equatable, Sendable {
    /// [LAW:types-are-the-program] What one source has told the list: it swept, or why it did not.
    private enum Reading: Equatable, Sendable {
        case read
        case unread(UnreadDevices)

        /// A source that has not spoken: waiting, never read.
        static let unheard = Reading.unread(.waiting)
    }

    private var byID: [DeviceID: Device] = [:]
    /// Total over the sources the list was built for, so a source that has not spoken is waiting and cannot be mistaken
    /// for read. A source nothing subscribed to is not in it: it is no source of this list, not one waiting for ever.
    private var readings: [DeviceSource: Reading]

    init(sources: some Collection<DeviceSource>) {
        readings = Dictionary(uniqueKeysWithValues: sources.map { ($0, Reading.unheard) })
    }

    mutating func apply(_ event: DeviceEvent, from source: DeviceSource) {
        precondition(readings[source] != nil, "an event from \(source.rawValue), which this list was not built for")
        switch event {
        case .reported(let device) where device.id.source == source: byID[device.id] = device
        case .gone(let id) where id.source == source: byID[id] = nil
        case .reported, .gone: break
        case .swept(let devices):
            removeDevices(of: source)
            for device in devices where device.id.source == source { byID[device.id] = device }
            readings[source] = .read
        case .permission(let permission):
            // Heard after a sweep, this is the end of what that sweep read, so nothing is kept to go stale, as in `end(_:)`.
            removeDevices(of: source)
            readings[source] = .unread(UnreadDevices(permission))
        }
    }

    /// The source's stream ended: no event will follow from it, so nothing of its is kept to go stale.
    mutating func end(_ source: DeviceSource) {
        precondition(readings[source] != nil, "the end of \(source.rawValue), which this list was not built for")
        removeDevices(of: source)
        readings[source] = .unread(.ended)
    }

    private mutating func removeDevices(of source: DeviceSource) {
        byID = byID.filter { $0.key.source != source }
    }

    /// Why this source's devices are no list of what it has connected, or nil once it has swept; nil too for a source this
    /// list was not built for, which has nothing to say. [LAW:types-are-the-program]
    /// A device reported before the first sweep leaves it unread: one device is not what is connected, and the connect a
    /// registration replays has no order with that sweep.
    func unread(of source: DeviceSource) -> UnreadDevices? {
        switch readings[source] {
        case nil, .read?: nil
        case .unread(let reason)?: reason
        }
    }

    /// Why a screen with no device to show has no list of what is connected, or nil when it has one to show or nothing is unread:
    /// a function of the readings, so there is no second copy of them. A device of a source that has swept is something to show;
    /// one reported ahead of its source's first sweep is not, as it is not the list. Otherwise the reason is the first source, in
    /// `DeviceSource.allCases` order, that was denied or ended; waiting only when none was.
    ///
    /// A source unread beside listed devices is shown nowhere yet: orange-device-sources-rec.k69.
    var unread: UnreadDevices? {
        let reasons = DeviceSource.allCases.filter { readings[$0] != nil }.map { ($0, unread(of: $0)) }
        guard reasons.contains(where: { $0.1 != nil }) else { return nil }
        let showsDevice = reasons.contains { source, reason in reason == nil && byID.keys.contains { $0.source == source } }
        guard !showsDevice else { return nil }
        return reasons.lazy.compactMap(\.1).first { $0 != .waiting } ?? .waiting
    }

    /// In a stable order, by name then identity, so a view never reshuffles equal rows.
    var devices: [Device] {
        byID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

extension DeviceEvent {
    /// The identity of every device the event names.
    var ids: [DeviceID] {
        switch self {
        case .reported(let device): [device.id]
        case .gone(let id): [id]
        case .swept(let devices): devices.map(\.id)
        case .permission: []
        }
    }
}

extension UnreadDevices {
    /// What a sweep is waiting on for this permission: nothing yet when allowed, since the sweep is what reads the list.
    init(_ permission: BluetoothPermission) {
        self = switch permission {
        case .allowed: .waiting
        case .notDetermined: .unanswered
        case .denied: .denied
        }
    }

    /// Why a card that lists devices is empty.
    var explanation: Phrase {
        switch self {
        case .waiting: "Reading your Bluetooth devices…"
        case .unanswered: "Answer the Bluetooth prompt to see your devices."
        case .denied: "This app isn't allowed to use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth, then quit and reopen the app."
        case .ended: "Device readings stopped. Quit and reopen the app."
        }
    }
}
