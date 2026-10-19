import Foundation
import IOKit.ps
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the diagram shows for a reading.
@Suite struct PowerFlowDiagram {
    typealias Fixtures = BatteryReadingParse

    /// Charging off a 59 W adapter: 10.4 W (13 V at 800 mA) into the battery, 57.2 W taken in
    /// from the adapter, so 46.8 W is the system's own.
    static func charging(adapterWatts: Int? = 59, telemetry: [String: Any]? = ["SystemPowerIn": 57200]) throws -> BatteryReading {
        var registry = Fixtures.registry
        registry["Voltage"] = 13000
        registry["Amperage"] = 800
        registry["PowerTelemetryData"] = telemetry
        let adapter: [String: Any] = adapterWatts.map { [kIOPSPowerAdapterWattsKey: $0] } ?? [:]
        return try #require(try BatteryReading(registry: registry, powerSource: Fixtures.charging(timeToFull: 82), adapter: adapter))
    }

    @Test func showsTheChargerTheTwoBandsTheCaptionAndAWorkload() throws {
        let flow = try #require(PowerFlow(try Self.charging()))
        #expect(flow.charger == "59W")
        #expect(flow.battery.label == "10.4 W")
        #expect(flow.system.label == "46.8 W")
        #expect(flow.caption == "Charging at 10 W")
        #expect(flow.workload == "Active workload: multitasking or media")
    }

    @Test func eachBandIsAsThickAsTheWattsItCarries() throws {
        let flow = try #require(PowerFlow(try Self.charging()))
        #expect(abs(flow.system.share / flow.battery.share - 4.5) < 0.01)
        #expect(abs(flow.battery.share - 10.4 / 59) < 1e-9)
    }

    @Test func noTelemetryOrNoAdapterMeansNoDiagram() throws {
        #expect(PowerFlow(try Self.charging(telemetry: nil)) == nil)
        #expect(PowerFlow(try BatteryEvents.onBattery) == nil)
    }

    @Test func aReadingAboveTheRatingStillFitsTheWhole() throws {
        let flow = try #require(PowerFlow(try Self.charging(adapterWatts: 30)))
        #expect(flow.battery.share + flow.system.share <= 1 + 1e-9)
    }

    @Test func workloadClassesRiseWithTheDraw() {
        #expect(PowerFlow.workload(watts: 3).hasPrefix("Idle"))
        #expect(PowerFlow.workload(watts: 15).hasPrefix("Light"))
        #expect(PowerFlow.workload(watts: 46.8).hasPrefix("Active"))
        #expect(PowerFlow.workload(watts: 80).hasPrefix("Heavy"))
    }
}
