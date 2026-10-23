import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a run of readings puts on screen: how many
// pills, where, saying what, filled how far.
@MainActor @Suite(.serialized) struct PillTests {
    static func reading(_ percent: Int, minutes: Int = 9) throws -> BatteryReading {
        try BatteryEvents.reading(BatteryEvents.Fixtures.discharging(timeToEmpty: minutes), percent: percent)
    }

    static func center(_ pills: PillController, alerts: [Alert]) throws -> AlertCenter {
        let center = try AlertCenter(
            store: AlertSettingsStore(defaults: AlertSettingsPersistence.suite()),
            deliver: { pills.deliver($0, reading: $1) })
        try center.update { $0.alerts = alerts }
        return center
    }

    @Test func aLowAlertAtTopOfScreenShowsOnePillForTheReadingThatCrossedIt() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        defer { pills.close(.closeButton) }
        let center = try Self.center(
            pills, alerts: [Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)])
        for percent in [16, 15, 14] { center.observe(try Self.reading(percent)) }

        let shown = try #require(pills.shown)
        #expect(shown.headline.english == "14% Remaining" && shown.subline?.english == "9min until empty")
        #expect(shown.severity == .orange && shown.progress == 0.14 && shown.position == .top && !shown.glow)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        #expect(pills.shownFrame == PillPlacement.frame(.top, on: screen, scale: 1))
        #expect(try #require(pills.shownFrame).maxY > screen.midY)
    }

    @Test func borderGlowFollowsTheAlertThatFiredAndGoesWithItsPill() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        defer { pills.close(.closeButton) }
        let center = try Self.center(pills, alerts: [
            Alert(kind: .low, threshold: 20, position: .top, glow: true, sound: false),
            Alert(kind: .low, threshold: 10, position: .top, glow: false, sound: false),
        ])
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).frame
        for percent in [21, 19] { center.observe(try Self.reading(percent)) }
        #expect(pills.shown?.glow == true && pills.shownGlowFrame == screen)

        center.observe(try Self.reading(9))
        #expect(pills.shown?.headline.english == "9% Remaining" && pills.shownGlowFrame == nil)

        pills.show(PillContent(Alert(kind: .low, threshold: 20, position: .top, glow: true, sound: false),
                               reading: try Self.reading(19)))
        #expect(pills.shownGlowFrame == screen)
        pills.close(.closeButton)
        #expect(pills.shownGlowFrame == nil)
    }

    @Test func aCenterAlertSitsAtTheMiddleOfTheScreen() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        defer { pills.close(.closeButton) }
        pills.show(PillContent(Alert(kind: .low, threshold: 5, position: .center, glow: false, sound: false),
                               reading: try Self.reading(4)))
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        let frame = try #require(pills.shownFrame)
        #expect(frame.midX == screen.midX && frame.midY == screen.midY)
    }

    @Test func aNewPillReplacesTheOneShowingAndClosingClearsIt() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        let low = Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)
        pills.show(PillContent(low, reading: try Self.reading(14)))
        pills.show(PillContent(low, reading: try Self.reading(13)))
        #expect(pills.shown?.headline.english == "13% Remaining")
        pills.close(.closeButton)
        #expect(pills.shown == nil && pills.shownFrame == nil)
    }

    @Test func replacingAPillDoesNotReleaseWhoeverWaitsForNoPill() async throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        let low = Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)
        pills.show(PillContent(low, reading: try Self.reading(14)))
        var released = false
        let waiter = Task { await pills.untilClosed(); released = true }
        await Task.yield()
        pills.show(PillContent(low, reading: try Self.reading(13)))
        await Task.yield()
        #expect(!released)
        pills.close(.closeButton)
        await waiter.value
        #expect(released)
    }

    static func countdown(_ clock: ManualTimekeeper) -> PillController {
        PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), timekeeper: clock)
    }

    /// The `alerts` log lines that name this headline: other suites log in the same category at
    /// the same time, so each countdown test reads only its own pill's lines.
    static func lines(_ log: BatteryLog, about headline: String) throws -> [String] {
        try log.messages().filter { $0.hasSuffix(": \(headline)") }
    }

    @Test func aPillAndItsGlowLeaveByThemselvesOnceShownForHasPassed() async throws {
        let clock = ManualTimekeeper()
        let pills = Self.countdown(clock)
        let log = try BatteryLog(category: "alerts")
        pills.show(PillContent(Alert(kind: .low, threshold: 31, position: .center, glow: true, sound: false),
                               reading: try Self.reading(31)))
        let waiter = Task { await pills.untilClosed() }
        await clock.asleep()

        clock.advance(by: PillController.shownFor - .seconds(1))
        // The countdown is still asleep: `advance` wakes a due sleeper on the spot, so this needs no yield.
        #expect(clock.sleeping == 1)
        clock.advance(by: .seconds(1))
        await waiter.value
        #expect(pills.shown == nil && pills.shownGlowFrame == nil)
        #expect(try Self.lines(log, about: "31% Remaining") == [
            "pill shown at center for \(PillController.shownFor): 31% Remaining", "pill closed: timed out after \(PillController.shownFor): 31% Remaining"])
    }

    @Test func aReplacementGetsItsOwnFullTimeOnScreen() async throws {
        let clock = ManualTimekeeper()
        let pills = Self.countdown(clock)
        let log = try BatteryLog(category: "alerts")
        let low = Alert(kind: .low, threshold: 30, position: .top, glow: false, sound: false)
        pills.show(PillContent(low, reading: try Self.reading(29)))
        await clock.asleep()
        clock.advance(by: .seconds(5))
        pills.show(PillContent(low, reading: try Self.reading(28)))
        // The first pill's countdown went with it. The second's has not started: its task waits
        // for the main actor, which this test holds until its next await.
        #expect(clock.sleeping == 0)
        await clock.asleep()

        let waiter = Task { await pills.untilClosed() }
        clock.advance(by: PillController.shownFor - .seconds(1))
        #expect(clock.sleeping == 1)
        clock.advance(by: .seconds(1))
        await waiter.value
        #expect(pills.shown == nil)
        #expect(try Self.lines(log, about: "29% Remaining") == ["pill shown at top for \(PillController.shownFor): 29% Remaining", "pill replaced: 29% Remaining"])
        #expect(try Self.lines(log, about: "28% Remaining") == [
            "pill shown at top for \(PillController.shownFor): 28% Remaining", "pill closed: timed out after \(PillController.shownFor): 28% Remaining"])
    }

    @Test func closingAPillEndsItsCountdown() async throws {
        let clock = ManualTimekeeper()
        let pills = Self.countdown(clock)
        let log = try BatteryLog(category: "alerts")
        pills.show(PillContent(Alert(kind: .low, threshold: 27, position: .top, glow: false, sound: false),
                               reading: try Self.reading(26)))
        await clock.asleep()
        clock.advance(by: .seconds(3))
        pills.close(.closeButton)
        // Nothing is left counting down to take down whichever pill comes up next.
        #expect(clock.sleeping == 0)
        #expect(try Self.lines(log, about: "26% Remaining") == ["pill shown at top for \(PillController.shownFor): 26% Remaining", "pill closed: ×: 26% Remaining"])
    }

    // orange-alerts-cjt.3ns: an alert fires once per crossing, so its pill's time is time the screen
    // can be seen. A pill held through a sleep gets all of it once someone is back.
    @Test func aPillHeldWhileNoOneCanSeeTheScreenGetsItsFullTimeOnceSeen() async throws {
        let clock = ManualTimekeeper()
        let pills = Self.countdown(clock)
        let log = try BatteryLog(category: "alerts")
        pills.show(PillContent(Alert(kind: .low, threshold: 25, position: .center, glow: true, sound: false),
                               reading: try Self.reading(24)))
        await clock.asleep()
        clock.advance(by: .seconds(1))
        pills.screen(hidden: [.displayAsleep])
        #expect(clock.sleeping == 0)
        clock.advance(by: PillController.shownFor * 10)
        #expect(pills.shown != nil && pills.shownCounting == false)

        pills.screen(hidden: [])
        let waiter = Task { await pills.untilClosed() }
        await clock.asleep()
        clock.advance(by: PillController.shownFor - .seconds(1))
        #expect(clock.sleeping == 1)
        clock.advance(by: .seconds(1))
        await waiter.value
        #expect(pills.shown == nil && pills.shownGlowFrame == nil)
        #expect(try Self.lines(log, about: "24% Remaining") == [
            "pill shown at center for \(PillController.shownFor): 24% Remaining", "pill held: 24% Remaining",
            "pill counting \(PillController.shownFor) again: 24% Remaining", "pill closed: timed out after \(PillController.shownFor): 24% Remaining"])
        #expect(try log.messages().contains("screen hidden by displayAsleep") && log.messages().contains("screen seen"))
    }

    @Test func aPillShownWhileTheScreenIsHiddenWaitsUntilEveryHiderHasEnded() async throws {
        let clock = ManualTimekeeper()
        let pills = Self.countdown(clock)
        let log = try BatteryLog(category: "alerts")
        pills.screen(hidden: [.locked])
        pills.show(PillContent(Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: false),
                               reading: try Self.reading(80)))
        await Task.yield()
        #expect(pills.shownCounting == false && clock.sleeping == 0)
        // The display sleeps and wakes again on the lock screen: still no one can see the pill.
        pills.screen(hidden: [.locked, .displayAsleep])
        pills.screen(hidden: [.locked])
        #expect(pills.shownCounting == false)

        pills.screen(hidden: [])
        let waiter = Task { await pills.untilClosed() }
        await clock.asleep()
        clock.advance(by: PillController.shownFor)
        await waiter.value
        #expect(try Self.lines(log, about: "80% Charged") == [
            "pill shown at top, held: 80% Charged", "pill held: 80% Charged", "pill held: 80% Charged",
            "pill counting \(PillController.shownFor) again: 80% Charged", "pill closed: timed out after \(PillController.shownFor): 80% Charged"])
        #expect(try log.messages().contains("screen hidden by displayAsleep, locked"))
    }

    @Test func aChangeOfDisplaysPlacesThePillOnTheMainScreenAndKeepsItsCountdownAndLanguage() async throws {
        let clock = ManualTimekeeper()
        let language = AppLanguageTests.scratch()
        let laptop = ScreenArea(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))
        let external = ScreenArea(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 1512, y: 70, width: 2560, height: 1345))
        let screens = Screens(laptop)
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: language, timekeeper: clock, screen: { screens.main })
        let log = try BatteryLog(category: "alerts")
        try language.update { $0 = AppLanguage(code: "fr") }
        pills.show(PillContent(Alert(kind: .low, threshold: 22, position: .top, glow: true, sound: false),
                               reading: try Self.reading(21)))
        await clock.asleep()
        clock.advance(by: .seconds(5))
        try language.update { $0 = AppLanguage(code: "es") }

        screens.main = external
        pills.screensChanged()
        #expect(pills.shownFrame == PillPlacement.frame(.top, on: external.visibleFrame, scale: 1))
        #expect(pills.shownGlowFrame == external.frame)
        #expect(pills.shownLanguage == AppLanguage(code: "fr"))
        // Displays re-enumerating: no screen to go to, so the pill stays where it is.
        screens.main = nil
        pills.screensChanged()
        #expect(pills.shownFrame == PillPlacement.frame(.top, on: external.visibleFrame, scale: 1))
        // The same countdown, three seconds from its end.
        #expect(clock.sleeping == 1)
        let waiter = Task { await pills.untilClosed() }
        clock.advance(by: PillController.shownFor - .seconds(5))
        await waiter.value
        #expect(try Self.lines(log, about: "21% Remaining") == [
            "pill shown at top for \(PillController.shownFor): 21% Remaining", "pill placed in \(external.visibleFrame): 21% Remaining",
            "no screen to place the pill on: 21% Remaining", "pill closed: timed out after \(PillController.shownFor): 21% Remaining"])
    }

    // The first set the system sends at launch may say what the controller already holds: nothing hides the screen.
    @Test(.timeLimit(.minutes(1))) func theSameHidersAgainLeaveACountingPillsCountdownAsItWas() async throws {
        let clock = ManualTimekeeper()
        let pills = Self.countdown(clock)
        let log = try BatteryLog(category: "alerts")
        pills.show(PillContent(Alert(kind: .low, threshold: 19, position: .top, glow: false, sound: false),
                               reading: try Self.reading(18)))
        await clock.asleep()
        clock.advance(by: .seconds(6))
        pills.screen(hidden: [])
        #expect(clock.sleeping == 1)
        let waiter = Task { await pills.untilClosed() }
        clock.advance(by: PillController.shownFor - .seconds(6))
        await waiter.value
        #expect(try Self.lines(log, about: "18% Remaining") == [
            "pill shown at top for \(PillController.shownFor): 18% Remaining", "pill closed: timed out after \(PillController.shownFor): 18% Remaining"])
    }

    /// The screen a test's pills go on, moved by the test.
    @MainActor final class Screens {
        var main: ScreenArea?
        init(_ main: ScreenArea) { self.main = main }
    }

    @Test func pillWordingAndSeverityFollowTheAlertAndTheReading() throws {
        let low = { (threshold: Int) in Alert(kind: .low, threshold: threshold, position: .top, glow: false, sound: false) }
        #expect(PillContent(low(5), reading: try Self.reading(4)).severity == .red)
        #expect(PillContent(low(6), reading: try Self.reading(5)).severity == .orange)
        #expect(PillContent(low(15), reading: try Self.reading(14, minutes: 192)).subline?.english == "3h 12m until empty")
        let charged = Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: false)
        let content = PillContent(charged, reading: try Self.reading(80))
        #expect(content.headline.english == "80% Charged" && content.severity == .green)
    }

    // orange-alerts-cjt.c2g: under an 80% Charge Limit the reading that crosses 80 still says
    // charging with powerd's estimate to 100%; the pill must not promise a full charge.
    @Test func aChargedPillAtTheChargeLimitSaysNoTimeUntilFull() throws {
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch())
        defer { pills.close(.closeButton) }
        let center = try Self.center(
            pills, alerts: [Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: false)])
        center.observe(try BatteryEvents.reading(BatteryEvents.Fixtures.charging(timeToFull: 50), percent: 79))
        center.observe(try BatteryEvents.atTheLimit())

        let shown = try #require(pills.shown)
        #expect(shown.headline.english == "80% Charged")
        #expect(shown.subline == nil)
    }

    @Test func aPillSaysItsWordingInFrenchAndSpanish() throws {
        let low = Alert(kind: .low, threshold: 15, position: .top, glow: false, sound: false)
        let content = PillContent(low, reading: try Self.reading(14, minutes: 192))
        let charged = PillContent(Alert(kind: .charged, threshold: 80, position: .top, glow: false, sound: false), reading: try Self.reading(80))
        let short = PillContent(low, reading: try Self.reading(14))
        let app = PhraseTests.app
        func said(_ code: String, _ phrases: [Phrase?]) -> [String] { phrases.compactMap { $0?.resolve(in: AppLanguage(code: code), bundle: app) } }
        #expect(said("fr", [content.headline, content.subline, charged.headline, short.subline])
            == ["14 % restant", "3 h 12 min avant épuisement", "80 % chargé", "9 min avant épuisement"])
        #expect(said("fr", [PillContent.sample.headline, PillContent.sample.subline]) == ["15 % restant", "9 min avant épuisement"])
        #expect(said("es", [content.headline, content.subline, charged.headline, short.subline])
            == ["14 % restante", "3 h 12 min hasta agotarse", "80 % cargado", "9 min hasta agotarse"])
    }

    @Test func theOverlayIsHandedTheLanguageTheAppSpeaksWhenThePillComesUp() throws {
        let language = AppLanguageTests.scratch()
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: language)
        defer { pills.close(.closeButton) }
        try language.update { $0 = AppLanguage(code: "fr") }
        pills.show(.power("On Battery", severity: .orange, reading: try Self.reading(14)))
        #expect(pills.shownLanguage == AppLanguage(code: "fr"))
        try language.update { $0 = AppLanguage(code: "es") }
        pills.show(.power("On Battery", severity: .orange, reading: try Self.reading(14)))
        #expect(pills.shownLanguage == AppLanguage(code: "es"))
    }

    /// The ticket's step on a real Mac, run by `make pill-check` with a person at the screen: a
    /// sample pill over a full-screen app at the centre, then at the top, each closed by its ×.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PILL_CHECK"] != nil, "run by make pill-check with a person at the screen"))
    func pillsShowOverAFullScreenApp() async throws {
        // The appearance a person set on the General screen, as the app itself loads it.
        let pills = PillController(appearance: try NotificationAppearanceModel(defaults: .standard), language: try AppLanguageModel(defaults: .standard))
        defer { pills.close(.closeButton) }
        let log = try BatteryLog(category: "alerts")
        let sounds = AlertSounds()
        let steps: [(position: Alert.Position, glow: Bool, sound: Bool)] = [
            (.center, false, false), (.top, false, false), (.center, true, true)]
        for (position, glow, sound) in steps {
            let alert = Alert(kind: .low, threshold: 17, position: position, glow: glow, sound: sound)
            pills.deliver(.threshold(alert), reading: try Self.reading(17))
            sounds.deliver(.threshold(alert))
            FileHandle.standardError.write(Data(
                ("\n>>> With an app full screen, find the pill at the \(position) of the screen"
                    + (glow ? ", with an orange glow around the screen edges," : "")
                    + (sound ? " and a chime," : "")
                    + " and click its × before it leaves by itself after \(PillController.shownFor).\n").utf8))
            await pills.untilClosed()
        }
        // A pill that timed out proves nothing about whether a person could see it.
        #expect(try Self.lines(log, about: "17% Remaining") == steps.flatMap {
            ["pill shown at \($0.position.rawValue) for \(PillController.shownFor): 17% Remaining", "pill closed: ×: 17% Remaining"]
        })
    }
}

extension NotificationAppearanceModel {
    /// An appearance over a throwaway suite, starting from the defaults.
    static func scratch(_ defaults: UserDefaults = AlertSettingsPersistence.suite()) -> NotificationAppearanceModel {
        try! NotificationAppearanceModel(defaults: defaults)
    }
}
