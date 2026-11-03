import Foundation

/// Who a device says it is: the three values lockdown's GetValue answers for it, read once a relay is opened.
/// [LAW:parse-dont-validate] `parseIPhoneIdentity` is the one crossing, so a device with an identity has all three and its
/// Bluetooth address is already an address. `bluetooth` is what makes a phone the same device as its Bluetooth twin
/// (`SourceDevice.alsoBluetooth`); lockdown writes it lowercase and colon-separated, which `BluetoothAddress` normalizes to
/// the form IOBluetooth names the device by (compared on real devices by `make iphone-identity-check`).
struct IPhoneIdentity: Equatable, Sendable {
    /// The GetValue keys the identity is read from: what the edge asks lockdown for and the parser reads, in one place.
    static let lockdownKeys = ["DeviceName", "ProductType", "BluetoothAddress"]

    /// The name the user gave the device (Settings › General › About › Name), as lockdown answers it, blank or not.
    let name: String
    /// The model, as Apple's identifier for it: "iPhone16,2", "iPad13,1", "RealityDevice14,1".
    let productType: String
    let bluetooth: BluetoothAddress

    var kind: DeviceKind { DeviceKind(productType: productType) }
}

extension DeviceKind {
    /// [LAW:parse-dont-validate] The one place a lockdown device's kind is decided, from its ProductType, which the user cannot
    /// rename: "iPhone16,2" is a phone and "iPad13,1" a tablet. Every other model (a Vision Pro's "RealityDevice14,1", an iPod
    /// touch's "iPod9,1") is an accessory, the kind for every wireless device that is neither.
    init(productType: String) {
        switch productType.wholeMatch(of: /(iPhone|iPad)\d+,\d+/)?.1.description {
        case "iPhone": self = .phone
        case "iPad": self = .tablet
        default: self = .accessory
        }
    }
}

/// Parses the values of `IPhoneIdentity.lockdownKeys`, keyed by name, as lockdown answered them. A missing key, a value of
/// another type, or a Bluetooth address that is not one is an error, never a default: a device is listed only with the
/// address that joins it to its Bluetooth twin.
func parseIPhoneIdentity(_ values: [String: Any]) throws -> IPhoneIdentity {
    func string(_ key: String) throws -> String {
        guard let value = try optional(values, key, as: String.self) else { throw IPhoneParseError.missingKey(key) }
        return value
    }
    guard let bluetooth = BluetoothAddress(try string("BluetoothAddress")) else { throw IPhoneParseError.invalid("BluetoothAddress") }
    return IPhoneIdentity(name: try string("DeviceName"), productType: try string("ProductType"), bluetooth: bluetooth)
}

// [LAW:behavior-not-structure] The read's log line is this text, so its format is stated here rather than left to reflection.
// The name is the user's own, so it is left out: the log is the model and the address that identifies the device.
extension IPhoneIdentity: CustomStringConvertible {
    var description: String { "\(productType) (\(kind)), bluetooth \(bluetooth.key)" }
}
