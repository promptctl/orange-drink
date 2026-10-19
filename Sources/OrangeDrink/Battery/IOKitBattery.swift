import Foundation
import IOKit
import IOKit.ps
import os

/// [LAW:effects-at-boundaries] The one edge that talks to IOKit. It fetches the three
/// dictionaries and hands them to the pure parser.
enum IOKitBattery {
    static let logSubsystem = Bundle.main.bundleIdentifier!
    static let logCategory = "battery"
    static let log = Logger(subsystem: logSubsystem, category: logCategory)

    /// nil when this Mac has no battery: a desktop, or a laptop whose battery is gone, is a
    /// legal host, not an error. Every outcome leaves one line in the log.
    static func read() throws -> BatteryReading? {
        do {
            let reading = try fetch()
            log.info("battery read: \(reading.map { String(describing: $0) } ?? "none", privacy: .public)")
            return reading
        } catch {
            log.error("battery read failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func fetch() throws -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS else { throw BatteryReadError.registry(status: status) }
        // On success IOKit always fills `properties`, and registry keys are always strings.
        let registry = properties!.takeRetainedValue() as! [String: Any]

        // Both calls answer nil, not an error, when powerd is unreachable.
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            throw BatteryReadError.powerSources(call: "IOPSCopyPowerSourcesInfo")
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            throw BatteryReadError.powerSources(call: "IOPSCopyPowerSourcesList")
        }
        let sources = (list as [CFTypeRef])
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        guard let powerSource = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else {
            throw BatteryReadError.noInternalBatterySource
        }
        // No details dictionary and an empty one say the same thing: nothing known about the adapter.
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]

        return try BatteryReading(registry: registry, powerSource: powerSource, adapter: adapter)
    }
}
