import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the words the expanded card shows for a reading.
@Suite struct BatteryInformationWords {
    typealias Fixtures = BatteryReadingParse

    /// The reference reading: charging at 78%, 4635 / 5942 / 6249 mAh, 84 of 1000 cycles,
    /// 30.9 °C, 12.62 V, 828 mA flowing in.
    static func reference(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> BatteryInformation {
        var registry = Fixtures.registry
        registry.merge([
            "AppleRawCurrentCapacity": 4635, "AppleRawMaxCapacity": 5942, "DesignCapacity": 6249,
            "CycleCount": 84, "DesignCycleCount9C": 1000, "Temperature": 3090, "Voltage": 12620, "Amperage": 828,
        ]) { $1 }
        edit(&registry)
        var powerSource = Fixtures.charging(timeToFull: 82)
        powerSource["Current Capacity"] = 78
        return BatteryInformation(try #require(try BatteryReading(registry: registry, powerSource: powerSource, adapter: Fixtures.adapter)))
    }

    @Test func healthIsFullCapacityOverDesignWithItsCycles() throws {
        let info = try Self.reference()
        #expect(info.health.percent == "95%")
        #expect(info.health.label == "Good")
        #expect(info.health.cycles == "84/1000")
        #expect(abs(info.health.fraction - 5942.0 / 6249.0) < 1e-9)
    }

    @Test func aWornBatteryIsNotCalledGood() throws {
        let info = try Self.reference { $0["AppleRawMaxCapacity"] = 4800 }
        #expect(info.health.label == "Service Recommended")
        #expect(info.health.condition == .warning)
    }

    @Test func temperatureShowsBothScalesAndItsStatus() throws {
        let t = try Self.reference().temperature
        #expect(t.celsius == "30.9°C")
        #expect(t.fahrenheit == "87.6°F")
        #expect(t.status == "Normal")
        #expect(t.condition == .good)
    }

    @Test func aHotBatteryChangesStatusAndColour() throws {
        #expect(try Self.reference { $0["Temperature"] = 3700 }.temperature.condition == .warning)
        let hot = try Self.reference { $0["Temperature"] = 4200 }.temperature
        #expect(hot.status == "Hot")
        #expect(hot.condition == .bad)
    }

    @Test func electricalShowsPowerCurrentWithItsDirectionAndVoltage() throws {
        let e = try Self.reference().electrical
        #expect(e.power == "10.4 W")
        #expect(e.current == "828 mA")
        #expect(e.flow == .intoBattery)
        #expect(e.voltage == "12.62 V")
        #expect(e.voltageStatus == "Charging")
        #expect(e.charging)
    }

    @Test func currentLeavingTheBatteryPointsTheOtherWay() throws {
        let e = try Self.reference { $0["Amperage"] = -900 }.electrical
        #expect(e.current == "900 mA")
        #expect(e.flow == .outOfBattery)
    }

    @Test func capacityShowsThreeMilliampHourFigures() throws {
        let c = try Self.reference().capacity
        #expect([c.remaining, c.full, c.design] == ["4635 mAh", "5942 mAh", "6249 mAh"])
    }
}
