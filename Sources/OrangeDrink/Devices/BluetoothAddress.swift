import Foundation

/// The Bluetooth address of a device another source reads (an iPhone's, from lockdown), as the identity Bluetooth itself names that
/// device by. [LAW:parse-dont-validate] The one crossing for such an address: lockdown writes "6C:3A:FF:D9:74:42" where IOBluetooth
/// writes "6c-3a-ff-d9-74-42", so a claim is compared in IOBluetooth's form. Six hex octets, separated by ":" or "-" alike
/// throughout, either case; nil for anything else, so a value that is not an address cannot become an identity no device has.
///
/// This covers the claim side only. `BluetoothDevices` builds its identities from IOBluetooth's `addressString` as it always has,
/// because stored pins, alerts and hides are keyed by exactly that string; the two forms are compared on a real phone by
/// orange-device-sources-rec.0ex's check.
struct BluetoothAddress: Hashable, Sendable {
    /// IOBluetooth's form: lowercase hex octets joined by "-".
    let key: String

    init?(_ text: String) {
        for separator in [":", "-"] as [Character] {
            let octets = text.split(separator: separator, omittingEmptySubsequences: false)
            guard octets.count == 6, octets.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { continue }
            key = octets.map { $0.lowercased() }.joined(separator: "-")
            return
        }
        return nil
    }

    var identity: DeviceID { .bluetooth(key) }
}
