/// [LAW:one-source-of-truth] The app's memory of its devices, kept across launches. The shelf mirrors it for Edit Widget, so a
/// shelf file that is lost or unreadable is written again from here.
extension SeenDevices: Stored {
    static let storageKey = "devices.seen"

    /// Takes in every device on the list. A read with no name leaves a known one: `Device.name` is the address until
    /// IOBluetooth has a name, and a device that leaves then would stay in Edit Widget as an address.
    mutating func see(_ list: DeviceList) {
        for device in list.devices where device.hasName || names[device.id.address] == nil {
            names[device.id.address] = device.name
        }
    }
}

typealias SeenDevicesModel = StoredModel<SeenDevices>
