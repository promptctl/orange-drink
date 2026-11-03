import Foundation

// Compiled into the app and its widget extension, because a widget's settings and the shelf hold these.

/// Where a device is read from. [LAW:types-are-the-program] Closed, so a device of a source nothing reads cannot exist.
enum DeviceSource: String, CaseIterable, Sendable {
    case bluetooth
    /// An iPhone or iPad, read over its cable; its key is the device ID usbmuxd names it by.
    case iPhone = "iphone"
}

/// A device's identity: its source and the key that source names it by, the one thing a rename cannot change. Two devices
/// with equal names or equal keys from different sources are different devices.
///
/// [LAW:one-source-of-truth] `wire` is the one string form, `source:key`, and `init?(wire:)` the one parser of it. A
/// Bluetooth address (IOBluetooth writes it dash-separated) and a device ID never hold a ":", so the first one ends the source.
struct DeviceID: Hashable, Sendable, Comparable {
    let source: DeviceSource
    let key: String

    static func bluetooth(_ address: String) -> DeviceID { DeviceID(source: .bluetooth, key: address) }

    var wire: String { "\(source.rawValue):\(key)" }

    /// [LAW:parse-dont-validate] The crossing for every stored or system-held identity. A string with no source is what every
    /// release before sources wrote, when only Bluetooth existed, so it is a Bluetooth address. nil for a source this release
    /// does not know and for a key that is empty, so neither is guessed into a device.
    init?(wire: String) {
        guard let colon = wire.firstIndex(of: ":") else {
            guard !wire.isEmpty else { return nil }
            self = .bluetooth(wire)
            return
        }
        let key = String(wire[wire.index(after: colon)...])
        guard let source = DeviceSource(rawValue: String(wire[..<colon])), !key.isEmpty else { return nil }
        self.init(source: source, key: key)
    }

    init(source: DeviceSource, key: String) {
        (self.source, self.key) = (source, key)
    }

    /// By source, then key, so the order is the fields' and not the wire form's.
    static func < (lhs: DeviceID, rhs: DeviceID) -> Bool {
        (lhs.source.rawValue, lhs.key) < (rhs.source.rawValue, rhs.key)
    }
}

extension DeviceID: Codable {
    /// What releases before sources stored for a pinned, hidden or alerting device.
    private struct Legacy: Decodable { let address: String }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let wire = try? value.decode(String.self) {
            guard let id = DeviceID(wire: wire) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "not a device identity: \(wire)")
            }
            self = id
        } else {
            self = .bluetooth(try value.decode(Legacy.self).address)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(wire)
    }
}
