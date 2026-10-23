// Records, every 30 s, what the public sources say about charging: the IOPowerSources
// description (what the app parses) beside the smart-battery registry's own view.
// Run: swift spikes/orange-alerts-cjt.c2g/capture.swift >> /tmp/c2g/capture.log
import Foundation
import IOKit
import IOKit.ps

func powerSource() -> [String: Any] {
    let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
    return list.lazy.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType } ?? [:]
}

func registry() -> [String: Any] {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    defer { IOObjectRelease(entry) }
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
    return props?.takeRetainedValue() as? [String: Any] ?? [:]
}

while true {
    let ps = powerSource(), reg = registry()
    let charger = reg["ChargerData"] as? [String: Any] ?? [:]
    let fields: [(String, Any?)] = [
        ("state", ps[kIOPSPowerSourceStateKey]), ("pct", ps[kIOPSCurrentCapacityKey]),
        ("psCharging", ps[kIOPSIsChargingKey]), ("psCharged", ps[kIOPSIsChargedKey]),
        ("psFinishing", ps["Is Finishing Charge"]), ("psToFull", ps[kIOPSTimeToFullChargeKey]),
        ("psToEmpty", ps[kIOPSTimeToEmptyKey]), ("regCharging", reg["IsCharging"]),
        ("regFull", reg["FullyCharged"]), ("regExtConnected", reg["ExternalConnected"]),
        ("regAvgToFull", reg["AvgTimeToFull"]), ("amperage", reg["Amperage"]),
        ("notChargingReason", charger["NotChargingReason"]), ("inhibit", charger["ChargerInhibitReason"]),
        ("chargingCurrent", charger["ChargingCurrent"]),
    ]
    let line = fields.map { "\($0.0)=\($0.1.map { "\($0)" } ?? "-")" }.joined(separator: " ")
    print(ISO8601DateFormatter().string(from: Date()), line)
    fflush(stdout)
    Thread.sleep(forTimeInterval: 30)
}
