import Foundation
import IOKit
import IOKit.ps
import os

/// [LAW:effects-at-boundaries] The one edge that talks to IOKit. It fetches the three
/// dictionaries and hands them to the pure parser.
enum IOKitBattery {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "battery")

    /// nil when this Mac has no battery: a desktop is a legal host, not an error.
    static func read() throws -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            log.info("battery read: none installed")
            return nil
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS, let registry = properties?.takeRetainedValue() as? [String: Any] else {
            throw BatteryReadError(key: "IORegistryEntryCreateCFProperties \(status)", source: "registry")
        }

        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = (IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef])
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        guard let powerSource = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else {
            throw BatteryReadError(key: kIOPSInternalBatteryType, source: "power source")
        }
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]

        let reading = try BatteryReading(registry: registry, powerSource: powerSource, adapter: adapter)
        log.info("battery read: \(String(describing: reading), privacy: .public)")
        return reading
    }
}
