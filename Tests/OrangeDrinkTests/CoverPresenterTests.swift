import CoreGraphics
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what answers a full-screen alert, and which pills and
// sounds wait while it is up (design-docs/alerts.md, What dismisses it).
@MainActor @Suite(.serialized) struct CoverPresenterTests {
    static let full = Alert(kind: .charged, threshold: 95, position: .fullScreen, glow: false, sound: true)
    static let lowPill = Alert(kind: .low, threshold: 20, position: .top, glow: true, sound: true)

    static func onBattery(_ percent: Int) throws -> BatteryReading { try PillTests.reading(percent) }
    static func onAdapter(_ percent: Int) throws -> BatteryReading {
        try BatteryEvents.reading(BatteryEvents.Fixtures.onACNotCharging(charged: false), percent: percent)
    }

    /// A presenter over a cover on one display and a pill controller, counting the chimes it plays.
    @MainActor final class Rig {
        let covers = CoverTests.Rig([CoverTests.primary])
        let pills = PillController(appearance: NotificationAppearanceModel.scratch(), language: AppLanguageTests.scratch(), orderFront: { _ in }, log: .unread)
        var chimes = 0
        var presenter: AlertPresenter!
        private var last: BatteryReading?

        init() { presenter = AlertPresenter(pills: pills, cover: covers.cover, sounds: AlertSounds(play: { [unowned self] in chimes += 1 }), log: .unread) }

        /// Hands the presenter one reading: the adapter change since the last one, and what it fired.
        func read(_ reading: BatteryReading, firing firings: [Firing] = []) {
            let changes = last.map { BatteryEvent.changes(from: $0, to: reading) } ?? []
            last = reading
            presenter.deliver(ReadingAlerts(reading: reading, changes: changes, firings: firings))
        }

        func close() { covers.cover.dismiss(.dismissButton); pills.close(.closeButton) }
    }

    @Test func connectingTheAdapterTakesALowCoverDown() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        rig.read(try Self.onBattery(1))
        #expect(rig.covers.cover.shown != nil)

        rig.read(try Self.onAdapter(1))
        #expect(rig.covers.cover.shown == nil)
    }

    @Test func disconnectingTheAdapterTakesAChargedCoverDown() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onAdapter(95), firing: [.threshold(Self.full)])
        rig.read(try Self.onAdapter(96))
        #expect(rig.covers.cover.shown != nil)

        rig.read(try Self.onBattery(96))
        #expect(rig.covers.cover.shown == nil)
    }

    @Test func aCoverFollowsTheBatteryWithoutChimingAgain() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(3), firing: [.threshold(CoverTests.critical)])
        rig.read(try Self.onBattery(2))
        #expect(rig.covers.cover.shown?.headline.english == "2% Remaining" && rig.chimes == 1)
    }

    @Test func aLowCoverFiredOnTheAdapterWaitsForDismissOrEsc() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onAdapter(2), firing: [.threshold(CoverTests.critical)])
        rig.read(try Self.onAdapter(3))
        #expect(rig.covers.cover.shown != nil)
    }

    @Test func aLowCoverCrossedOnTheReadingThatConnectsTheAdapterIsAlreadyAnswered() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(8))
        rig.read(try Self.onAdapter(2), firing: [.threshold(CoverTests.critical), .pluggedIn(sound: false)])
        #expect(rig.covers.cover.shown == nil && rig.pills.shown?.headline.english == "Plugged In" && rig.chimes == 0)
    }

    @Test func theAdapterAnswersTheCoverOnAReadingThatFiresNothing() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        // The master switch or the Plugged In switch off: the reading fires nothing.
        rig.read(try Self.onAdapter(2))
        #expect(rig.covers.cover.shown == nil)
    }

    @Test func aLowPillFiredUnderTheCoverIsNeitherShownNorPlayed() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        let chimes = rig.chimes

        rig.read(try Self.onBattery(1), firing: [.threshold(Self.lowPill)])
        #expect(rig.pills.shown == nil && rig.chimes == chimes)
    }

    @Test func aLowPillCrossedOnTheCoversReadingIsNeitherShownNorPlayedWhicheverIsListedFirst() throws {
        let silent = Alert(kind: .low, threshold: 5, position: .fullScreen, glow: false, sound: false)
        for firings: [Firing] in [[.threshold(Self.lowPill), .threshold(silent)], [.threshold(silent), .threshold(Self.lowPill)]] {
            let rig = Rig()
            defer { rig.close() }
            rig.read(try Self.onBattery(4), firing: firings)
            #expect(rig.covers.cover.shown != nil && rig.pills.shown == nil && rig.chimes == 0)
        }
    }

    @Test func twoFullScreenAlertsCrossedOnOneReadingShowTheMoreUrgentOnceWhicheverIsListedFirst() throws {
        let five = Alert(kind: .low, threshold: 5, position: .fullScreen, glow: false, sound: true)
        for firings: [Firing] in [[.threshold(five), .threshold(CoverTests.critical)], [.threshold(CoverTests.critical), .threshold(five)]] {
            let rig = Rig()
            defer { rig.close() }
            rig.read(try Self.onBattery(1), firing: firings)
            #expect(rig.covers.cover.shown?.headline.english == "1% Remaining" && rig.covers.ordered.count == 1 && rig.chimes == 1)
        }
    }

    @Test func theOneCoverOfAReadingChimesIfAnyOfItsFullScreenAlertsAskedToBeHeard() throws {
        let heard = Alert(kind: .low, threshold: 5, position: .fullScreen, glow: false, sound: true)
        let silent = Alert(kind: .low, threshold: 3, position: .fullScreen, glow: false, sound: false)
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(1), firing: [.threshold(heard), .threshold(silent)])
        #expect(rig.covers.cover.shown?.headline.english == "1% Remaining" && rig.chimes == 1)
    }

    @Test func aTemperaturePillShowsAndSoundsOverTheCover() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        let chimes = rig.chimes

        rig.read(try Self.onBattery(2), firing: [.temperatureWarning(.hot, sound: true)])
        #expect(rig.pills.shown?.headline.english == "Battery Hot" && rig.chimes == chimes + 1)
        // Stacked by level, not by which window was ordered front last.
        let cover = try #require(rig.covers.cover.shownPanels.first)
        #expect(rig.pills.shownPanels.allSatisfy { $0.level.rawValue > cover.level.rawValue })
    }

    @Test func theCoverTakesDownALowPillAlreadyUpButNotATemperaturePill() throws {
        let rig = Rig()
        defer { rig.close() }
        rig.read(try Self.onBattery(19), firing: [.threshold(Self.lowPill)])
        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        #expect(rig.pills.shown == nil && rig.covers.cover.shown != nil)

        rig.read(try Self.onBattery(2), firing: [.temperatureWarning(.warm, sound: false)])
        rig.read(try Self.onBattery(2), firing: [.threshold(Self.full)])
        #expect(rig.pills.shown?.headline.english == "Battery Warm")
    }

    static let mouse = DeviceFiring(
        alert: Alert(kind: .low, threshold: 20, position: .center, glow: false, sound: false), name: "Magic Mouse",
        level: BatteryLevel(percent: 19, approximate: false))

    /// Where a pill at `position` sits on the screen pills go on.
    static func frame(_ position: PillContent.Position) throws -> CGRect {
        PillPlacement.frame(position, on: try #require(ScreenArea.main()).visibleFrame, scale: 1)
    }

    /// Whether the pill up is at `frame`, within the point AppKit rounds a window's frame to.
    static func sits(_ pills: PillController, at frame: CGRect) -> Bool {
        guard let shown = pills.shownFrame else { return false }
        return [shown.minX - frame.minX, shown.minY - frame.minY, shown.maxX - frame.maxX, shown.maxY - frame.maxY].allSatisfy { abs($0) <= 1 }
    }

    @Test func aCentrePillShownOverTheCoverSitsAtTheTop() throws {
        let rig = Rig()
        defer { rig.close() }
        let top = try Self.frame(.top)
        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        rig.presenter.deliver(Self.mouse)
        #expect(rig.pills.shown?.headline.english == "Magic Mouse: 19% Remaining")
        #expect(Self.sits(rig.pills, at: top))
    }

    @Test func aCentrePillUpWhenTheCoverAppearsMovesToTheTopAndStaysThereAfterIt() throws {
        let rig = Rig()
        defer { rig.close() }
        let (top, center) = (try Self.frame(.top), try Self.frame(.center))
        rig.presenter.deliver(Self.mouse)
        #expect(Self.sits(rig.pills, at: center))

        rig.read(try Self.onBattery(2), firing: [.threshold(CoverTests.critical)])
        #expect(Self.sits(rig.pills, at: top))
        rig.covers.cover.dismiss(.dismissButton)
        #expect(rig.pills.shown != nil && Self.sits(rig.pills, at: top))
    }

    @Test func aCentrePillWithNoCoverUpStaysAtTheCentre() throws {
        let rig = Rig()
        defer { rig.close() }
        let center = try Self.frame(.center)
        rig.presenter.deliver(Self.mouse)
        #expect(Self.sits(rig.pills, at: center))
    }
}
