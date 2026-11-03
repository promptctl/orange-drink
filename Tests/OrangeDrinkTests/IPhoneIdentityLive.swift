import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] orange-device-sources-rec.0ex's step on a real Mac, run by `make iphone-identity-check`: every iPhone,
// iPad or Vision Pro usbmuxd lists, over the cable or Wi-Fi, is read for its identity through the app's own edge, and each
// value is held to the Mac's own record of the same device, never to what a person sees:
//   - its Bluetooth address, in IOBluetooth's form, is the address system_profiler lists a paired device under, and that
//     device's name is the DeviceName lockdown gave: the fact the one-device-from-two-sources rule rests on;
//   - its ProductType is the "Product Type" the Mac recorded for it in com.apple.iPod (keyed by the last part of its UDID).
// It needs no cable and no person: a device on Wi-Fi is read the same way.
struct IPhoneIdentityLive {
    @available(macOS, deprecated: 10.15, message: "reads lockdown, which uses SecureTransport; see lm3.8pk")
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IPHONE_IDENTITY_CHECK"] != nil, "run by make iphone-identity-check with a trusted iPhone or iPad reachable"),
          .timeLimit(.minutes(5)))
    func identityMatchesTheMacsOwnRecord() throws {
        // One handle per device: either route gives the same identity.
        var handles: [String: Int] = [:]
        for device in try usbmuxListDevices() {
            guard case .device(let udid, _) = device.connection else { continue }
            handles[udid] = handles[udid] ?? device.handle
        }
        try #require(!handles.isEmpty, "usbmuxd lists no iPhone or iPad; this check needs one this Mac trusts, cabled or on Wi-Fi")
        let paired = try Self.pairedBluetooth()
        let models = try Self.recordedModels()
        let identities = PairIdentities()
        var modelsCompared = 0
        for (udid, handle) in handles.sorted(by: { $0.key < $1.key }) {
            let identity = try readIPhoneIdentity(handle: handle, udid: udid, identities: identities)
            let name = paired[identity.bluetooth]
            // The Mac records a model only for a device it has synced (a Vision Pro it never has gets none), so a device with
            // no record is left out of the model comparison, and the check needs one device that is in it.
            let model = udid.split(separator: "-").last.flatMap { models[String($0)] }
            // The record is posted on a ticket in a public repo, so it states what the comparisons found and not the device's
            // address or name.
            printForTheRecord("identity: \(identity.productType) (\(identity.kind)); system_profiler lists its address: \(name != nil); "
                              + "its name there is the one lockdown gave: \(name == identity.name); "
                              + "com.apple.iPod's Product Type is " + (model.map { "\($0 == identity.productType ? "the" : "not the") one lockdown gave" } ?? "not recorded: not compared"))
            #expect(name != nil, "system_profiler lists no paired device at lockdown's address for \(udid): \(identity.bluetooth.key)")
            #expect(name == identity.name, "system_profiler names the device at \(identity.bluetooth.key) differently from lockdown's DeviceName")
            if let model {
                modelsCompared += 1
                #expect(model == identity.productType, "com.apple.iPod records Product Type \(model) for \(udid), lockdown says \(identity.productType)")
            }
        }
        #expect(modelsCompared > 0, "com.apple.iPod records none of \(handles.count) reachable devices, so no model was compared")
    }

    /// Every device System Settings lists as paired with this Mac, connected or not: its address, in IOBluetooth's form → its name.
    static func pairedBluetooth() throws -> [BluetoothAddress: String] {
        let profiler = try ChildProcess.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        try #require(profiler.status == 0, "system_profiler exited \(profiler.status): \(profiler.errors)")
        let root = try #require(try JSONSerialization.jsonObject(with: profiler.output) as? [String: Any])
        let controller = try #require((root["SPBluetoothDataType"] as? [[String: Any]])?.first)
        var paired: [BluetoothAddress: String] = [:]
        for key in ["device_connected", "device_not_connected"] {
            for entry in controller[key] as? [[String: [String: Any]]] ?? [] {
                for (name, properties) in entry {
                    guard let address = (properties["device_address"] as? String).flatMap(BluetoothAddress.init) else { continue }
                    paired[address] = name
                }
            }
        }
        return paired
    }

    /// The model the Mac recorded for each device it has connected: the last part of its UDID → "Product Type".
    static func recordedModels() throws -> [String: String] {
        let defaults = try ChildProcess.run("/usr/bin/defaults", ["export", "com.apple.iPod", "-"])
        try #require(defaults.status == 0, "defaults exited \(defaults.status): \(defaults.errors)")
        let root = try plistDictionary(defaults.output)
        let devices = try #require(root["Devices"] as? [String: [String: Any]], "com.apple.iPod records no Devices")
        return devices.compactMapValues { $0["Product Type"] as? String }
    }
}
