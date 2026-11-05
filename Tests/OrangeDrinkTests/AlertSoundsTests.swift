import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is how many chimes a run of readings sets off: one for
// each firing whose alert has Sound on, none for the rest.
@MainActor @Suite struct AlertSoundsTests {
    @Test func onlyFiringsWhoseAlertHasSoundOnAreHeard() throws {
        var chimes = 0
        let sounds = AlertSounds(play: { chimes += 1 })
        let center = try AlertCenter(
            defaults: scratchDefaults(),
            log: .unread,
            deliver: { firing, _ in sounds.deliver(firing) })
        try center.model.update {
            $0.alerts = [
                Alert(kind: .low, threshold: 20, position: .top, glow: false, sound: true),
                Alert(kind: .low, threshold: 10, position: .top, glow: false, sound: false),
            ]
            $0.power = PowerSourceAlerts(pluggedIn: true, unplugged: false, temperature: true, sound: true)
        }
        for percent in [21, 19] { center.observe(try PillTests.reading(percent)) }
        #expect(chimes == 1)
        center.observe(try PillTests.reading(9))
        #expect(chimes == 1)
        center.observe(try PowerAndTemperatureAlerts.adapter())
        #expect(chimes == 2)
    }

    @Test func aBatteryGoingHotChimesOnceWhenTheCardsSoundIsOnAndNeverWhenItIsOff() throws {
        for (sound, expected) in [(true, 1), (false, 0)] {
            var chimes = 0
            let sounds = AlertSounds(play: { chimes += 1 })
            let center = try AlertCenter(defaults: scratchDefaults(), log: .unread, deliver: { firing, _ in sounds.deliver(firing) })
            try center.model.update {
                $0.alerts = []
                $0.power = PowerSourceAlerts(pluggedIn: false, unplugged: false, temperature: true, sound: sound)
            }
            for celsius in [30.0, 41, 42] { center.observe(try PowerAndTemperatureAlerts.battery(celsius: celsius)) }
            #expect(chimes == expected)
        }
    }

    @Test func aPowerAlertOrTemperatureWarningChimesExactlyWhenTheCardsSoundIsOn() {
        #expect(Firing.pluggedIn(sound: false).sound == false)
        #expect(Firing.unplugged(sound: true).sound)
        #expect(Firing.temperatureWarning(.hot, sound: false).sound == false)
        #expect(Firing.temperatureWarning(.warm, sound: true).sound)
    }
}
