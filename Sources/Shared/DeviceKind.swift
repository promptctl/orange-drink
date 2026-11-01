import Foundation

// Compiled into the app and its widget extension: what a device is and what level it reports, so the widget
// reads the app's own types off the shelf instead of copies of them.

enum DeviceKind: String, Codable, Equatable, Sendable {
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

    /// An outline icon per kind: a phone, a tablet, or concentric arcs around a dot for audio and
    /// every other wireless accessory.
    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .accessory: "dot.radiowaves.left.and.right"
        }
    }
}

struct BatteryLevel: Codable, Equatable, Sendable {
    let percent: Int
    /// Shown as "~50%": the source only knows the level roughly.
    let approximate: Bool

    /// "37%", "~50%" when the level is only approximate, or "–" when it is unknown.
    /// [LAW:one-source-of-truth] design-docs/devices.md: an approximate level is "~" wherever it appears.
    static func text(_ level: BatteryLevel?) -> String {
        level.map { "\($0.approximate ? "~" : "")\($0.percent)%" } ?? "–"
    }

    /// How far a bar or ring fills, from 0 to 1, and empty when the level is unknown.
    static func fraction(_ level: BatteryLevel?) -> Double { Double(level?.percent ?? 0) / 100 }
}
