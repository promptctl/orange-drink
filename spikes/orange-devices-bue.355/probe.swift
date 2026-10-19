// Spike orange-devices-bue.355: read every paired device's name, type, battery.
// Run: swiftc -O probe.swift -framework IOBluetooth -framework IOKit -o /tmp/probe && /tmp/probe
import Foundation
import IOBluetooth
import IOKit

// Private IOBluetoothDevice battery properties (KVC; absent => nil, not 0).
let batteryKeys = ["batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight", "batteryPercentCombined", "batteryPercentCase"]

func kvc(_ d: IOBluetoothDevice, _ key: String) -> Int? {
    guard d.responds(to: Selector(key)) else { return nil }
    let v = (d.value(forKey: key) as? NSNumber)?.intValue ?? 0
    return v > 0 ? v : nil
}

func kind(_ d: IOBluetoothDevice) -> String {
    switch (d.deviceClassMajor, d.deviceClassMinor) {
    case (0x02, _): return "phone"
    case (0x04, _): return "audio"
    case (0x05, 0x10...0x1F), (0x05, _): return "peripheral"
    default: return "other(major=\(d.deviceClassMajor),minor=\(d.deviceClassMinor))"
    }
}

print("== IOBluetooth paired devices ==")
for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
    let levels = batteryKeys.compactMap { k in kvc(d, k).map { "\(k.dropFirst(14))=\($0)%" } }
    print("\(d.isConnected() ? "CONN " : "disc ") \(d.name ?? "?") [\(kind(d))] \(levels.joined(separator: " "))")
}

print("== IORegistry BatteryPercent (HID peripherals) ==")
var it: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &it)
while case let s = IOIteratorNext(it), s != 0 {
    var p: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0)
    if let dict = p?.takeRetainedValue() as? [String: Any], let b = dict["BatteryPercent"] {
        print("\(dict["Product"] ?? "?") addr=\(dict["DeviceAddress"] ?? "?") battery=\(b)%")
    }
    IOObjectRelease(s)
}
