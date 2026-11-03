import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the card says for a reading.
@Suite struct ChargeCardWords {
    typealias Events = BatteryEvents

    @Test func chargingReadsTheLevelTheStateAndTheTimeToFull() throws {
        let card = ChargeCard(try Events.reading(Events.Fixtures.charging(timeToFull: 82), percent: 78))
        #expect(card.percent == "78")
        #expect(card.unit == "%")
        #expect(card.status.title == "Charging")
        #expect(card.estimateCaption == "UNTIL FULL")
        #expect(card.estimate.english == "1h 22m")
        #expect(card.progress == 0.78)
    }

    @Test func aChargeTheLimitStopsShowsNoTimeUntilFull() throws {
        let card = ChargeCard(try Events.atTheLimit())
        #expect(card.status.title == "Charging")
        #expect(card.estimate == "–")
    }

    @Test func dischargingShowsTheTimeToEmptyInItsPlace() throws {
        let card = ChargeCard(try Events.reading(Events.Fixtures.discharging(timeToEmpty: 200), percent: 60))
        #expect(card.status.title == "On Battery")
        #expect(card.estimateCaption == "UNTIL EMPTY")
        #expect(card.estimate.english == "3h 20m")
    }

    @Test func noEstimateIsADashNotAZero() throws {
        let held = ChargeCard(try Events.reading(Events.Fixtures.onACNotCharging(charged: false), percent: 80))
        #expect(held.status.title == "Not Charging")
        #expect(held.estimate == "–")
        let full = ChargeCard(try Events.reading(Events.Fixtures.onACNotCharging(charged: true), percent: 100))
        #expect(full.status.title == "Charged")
    }
}

/// A "relaunch" is a second instance over the same defaults.
@Suite @MainActor struct PanelSectionMemory {
    @Test func sectionsStartCollapsed() {
        #expect(PanelSections(defaults: scratchDefaults()).isOpen(.batteryInformation) == false)
    }

    @Test func anOpenSectionIsStillOpenAfterARelaunch() {
        let store = scratchDefaults()
        PanelSections(defaults: store).toggle(.batteryInformation)
        #expect(PanelSections(defaults: store).isOpen(.batteryInformation))
    }

    @Test func aSectionClosedAgainIsStillClosedAfterARelaunch() {
        let store = scratchDefaults()
        let sections = PanelSections(defaults: store)
        sections.toggle(.batteryInformation)
        sections.toggle(.batteryInformation)
        #expect(PanelSections(defaults: store).isOpen(.batteryInformation) == false)
    }
}
