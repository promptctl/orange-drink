// Raises the low battery warning on a VM, which has no battery. Run it as root, in a VM only.
// `fake-battery <percent> <minutes to empty> <hold seconds>` publishes a power source to powerd through
// IOKit's power source API, the way a UPS driver does, and holds it that long: powerd drops it when this process exits.
// ControlCenter then needs a restart to build its Battery module. `fake-battery warn <level>` writes the warning level
// where powerd publishes it and posts powerd's notification: 1 none, 2 early, 3 final.
import Foundation
import IOKit.ps
import SystemConfiguration

@_silgen_name("notify_post") func notify_post(_ name: UnsafePointer<CChar>) -> UInt32

func warn(_ level: Int) {
    let store = SCDynamicStoreCreate(kCFAllocatorDefault, "fakebattery" as CFString, nil, nil)!
    print("set level \(level) -> \(SCDynamicStoreSetValue(store, "State:/IOKit/LowBatteryWarning" as CFString, level as CFNumber)) read \(IOPSGetBatteryWarningLevel().rawValue)")
    print("notify_post -> \(notify_post("com.apple.system.powersources.lowbattery"))")
}

@_silgen_name("IOPSCreatePowerSource") func IOPSCreatePowerSource(_ source: UnsafeMutablePointer<OpaquePointer?>) -> IOReturn
@_silgen_name("IOPSSetPowerSourceDetails") func IOPSSetPowerSourceDetails(_ source: OpaquePointer?, _ details: CFDictionary) -> IOReturn

let arguments = CommandLine.arguments
if arguments[1] == "warn" { warn(Int(arguments[2])!); exit(0) }
let percent = Int(arguments[1])!, minutes = Int(arguments[2])!, hold = TimeInterval(arguments[3])!
var source: OpaquePointer?
let created = IOPSCreatePowerSource(&source)
print("IOPSCreatePowerSource -> \(String(created, radix: 16))")
let details: [String: Any] = [
    kIOPSNameKey: "InternalBattery-0", kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSTransportTypeKey: kIOPSInternalType,
    kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsPresentKey: true, kIOPSIsChargingKey: false,
    kIOPSCurrentCapacityKey: percent, kIOPSMaxCapacityKey: 100, kIOPSTimeToEmptyKey: minutes,
]
print("IOPSSetPowerSourceDetails -> \(String(IOPSSetPowerSourceDetails(source, details as CFDictionary), radix: 16))")
print("warning level \(IOPSGetBatteryWarningLevel().rawValue)")
Thread.sleep(forTimeInterval: hold)
