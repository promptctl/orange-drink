import Foundation
import IOKit
import IOKit.ps
import os

/// What a read of the battery gave: the reading (nil is a Mac with no battery), or why it gave none.
typealias BatteryRead = Result<BatteryReading?, any Error>

/// [LAW:effects-at-boundaries] The one edge that talks to IOKit. It fetches the three
/// dictionaries and hands them to the pure parser.
enum IOKitBattery {
    static let logSubsystem = Bundle.main.bundleIdentifier!
    static let log = Logger(subsystem: logSubsystem, category: "battery")

    /// One look at the battery. nil is a Mac with no battery: a desktop, or a laptop whose battery is gone, is a legal
    /// host, not an error. An answer leaves its line in the log here; a failure is the model's to log
    /// (`BatteryModel`), so one failed read leaves one line.
    static func look(log: Logger) -> BatteryRead {
        let look = BatteryRead { try fetch() }
        if case .success(let reading) = look { log.info("battery read: \(reading.map { String(describing: $0) } ?? "none", privacy: .public)") }
        return look
    }

    /// `look` for a caller that wants the failure thrown, as the live checks do.
    static func read(log: Logger) throws -> BatteryReading? { try look(log: log).get() }

    /// The level powerd warns at, which it writes before it posts kIOPSNotifyLowBattery.
    static func warningLevel() -> IOPSLowBatteryWarningLevel { IOPSGetBatteryWarningLevel() }

    private static func fetch() throws -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS else { throw BatteryReadError.registry(status: status) }
        // On success IOKit always fills `properties`, and registry keys are always strings.
        let registry = properties!.takeRetainedValue() as! [String: Any]

        let sources = try PowerSources.descriptions(IOPSCopyPowerSourcesInfo(), copiedBy: "IOPSCopyPowerSourcesInfo")
        guard let powerSource = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else {
            throw BatteryReadError.noInternalBatterySource
        }
        // No details dictionary and an empty one say the same thing: nothing known about the adapter.
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]

        return try BatteryReading(registry: registry, powerSource: powerSource, adapter: adapter)
    }
}
