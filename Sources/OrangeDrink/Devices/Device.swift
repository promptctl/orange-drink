import Foundation

/// A paired Bluetooth device, identified by its address: the one thing a rename cannot change.
struct DeviceID: Hashable, Sendable { let address: String }

enum DeviceKind: Equatable, Sendable {
    case phone, tablet
    /// Audio and every other wireless accessory.
    case accessory

    /// [LAW:parse-dont-validate] The one place a device's kind is decided. The Bluetooth class
    /// says "phone" for classic pairings only; a BLE-only pairing reads class 0 (spike
    /// orange-devices-bue.355), so the name is the only thing left to tell an iPad from an iPhone.
    static func classify(majorClass: UInt32, name: String) -> DeviceKind {
        if name.contains(/\biPad\b/.ignoresCase()) { return .tablet }
        if majorClass == Self.phoneMajorClass || name.contains(/\biPhone\b/.ignoresCase()) { return .phone }
        return .accessory
    }

    private static let phoneMajorClass: UInt32 = 0x02
}

struct BatteryLevel: Equatable, Sendable {
    let percent: Int
    /// Shown as "~50%": the source only knows the level roughly.
    let approximate: Bool
}

/// [LAW:types-are-the-program] What a device reports, and no more: a device with one battery, one
/// with earbuds and a case (each part may be missing, e.g. a bud out of its case), or none at all.
/// An unreported level is absent, never 0%.
enum DeviceLevels: Equatable, Sendable {
    case none
    case single(BatteryLevel)
    case earbuds(left: BatteryLevel?, right: BatteryLevel?, case: BatteryLevel?)

    /// The level a one-number display shows: the one that runs out first.
    var lowest: BatteryLevel? {
        switch self {
        case .none: nil
        case .single(let level): level
        case .earbuds(let left, let right, let `case`): [left, right, `case`].compactMap { $0 }.min { $0.percent < $1.percent }
        }
    }
}

struct Device: Equatable, Sendable, Identifiable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    let levels: DeviceLevels
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
}

/// Every connected device the app knows of. [LAW:one-source-of-truth] The one reduction from
/// events to the list; nothing else holds a device.
struct DeviceList: Equatable, Sendable {
    private var byID: [DeviceID: Device] = [:]

    mutating func apply(_ event: DeviceEvent) {
        switch event {
        case .reported(let device): byID[device.id] = device
        case .gone(let id): byID[id] = nil
        case .swept(let devices): byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        }
    }

    /// In a stable order, by name then address, so a view never reshuffles equal rows.
    var devices: [Device] {
        byID.values.sorted { ($0.name, $0.id.address) < ($1.name, $1.id.address) }
    }
}
