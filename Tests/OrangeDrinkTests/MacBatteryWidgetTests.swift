import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the widget reads off the shelf after each state
// the model takes, through the widget's own read path, from a shelf in a directory of the test's own.
@MainActor @Suite(.timeLimit(.minutes(1))) final class MacBatteryWidgetTests {
    struct StreamEnded: Error {}

    final class Reloads {
        var count = 0
    }

    /// Each test's own shelf, gone with the test.
    let shelf = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: shelf)
    }

    /// The model the app builds, its states published the way the app publishes them.
    static func model(readings: AsyncThrowingStream<BatteryReading?, any Error>, shelf: URL, reloads: Reloads) -> BatteryModel {
        let widgets = ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { if $0 == .macBattery { reloads.count += 1 } }
        return BatteryModel(readings: readings, onState: { widgets.publish(MacBattery($0)) })
    }

    @Test func theWidgetReadsEachReadingInTurnThenTheEnd() async throws {
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = Self.model(readings: readings, shelf: shelf, reloads: Reloads())
        #expect(try WidgetShelf.read(.macBattery, from: shelf).get() == .running(.waiting))

        let charging = try BatteryHistoryTests.charging(80)
        feed.yield(charging)
        _ = await model.state { if case .known(let held) = $0 { held == charging } else { false } }
        #expect(try WidgetShelf.read(.macBattery, from: shelf).get() == .running(.level(percent: 80, charging: true)))

        let onBattery = try BatteryHistoryTests.onBattery(79)
        feed.yield(onBattery)
        _ = await model.state { if case .known(let held) = $0 { held == onBattery } else { false } }
        #expect(try WidgetShelf.read(.macBattery, from: shelf).get() == .running(.level(percent: 79, charging: false)))

        feed.finish(throwing: StreamEnded())
        _ = await model.state(once: BatteryModel.isEnded)
        #expect(try WidgetShelf.read(.macBattery, from: shelf).get() == .running(.ended))
    }

    @Test func aValueTheShelfHoldsCostsNoWriteAndNoReload() async throws {
        let log = try BatteryLog(category: ShelfLog.category)
        let reloads = Reloads()
        let widgets = ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { if $0 == .macBattery { reloads.count += 1 } }

        widgets.publish(.level(percent: 50, charging: false))
        widgets.publish(.level(percent: 50, charging: false))
        #expect(reloads.count == 1)
        // The host app publishes into the same log category; the shelf's path makes each line this test's own.
        #expect(try await log.logged("widget shelf written, reload asked: level(percent: 50, charging: false) in \(shelf.path) for MacBattery, AllBatteries"))
        #expect(try await log.logged("widget shelf unchanged: level(percent: 50, charging: false) in \(shelf.path)"))
    }

    @Test func aShelfThatCannotBeWrittenIsLoggedAndAsksNoReload() async throws {
        let log = try BatteryLog(category: ShelfLog.category)
        let reloads = Reloads()
        let missing = shelf.appending(path: "missing")
        let widgets = ShelfPublisher<MacBattery>(item: .macBattery, directory: missing) { _ in reloads.count += 1 }

        widgets.publish(.level(percent: 50, charging: false))
        #expect(reloads.count == 0)
        #expect(try await log.logged("widget shelf write failed: level(percent: 50, charging: false) in \(missing.path)"))
    }

    /// The widget's own read, logged either way.
    @Test func theWidgetLogsWhatItReadsAndWhyItCouldNot() async throws {
        let log = try BatteryLog(category: ShelfLog.category)
        #expect(throws: (any Error).self) { try WidgetShelf.load(.macBattery, from: .success(shelf), log: ShelfLog.log).get() }
        #expect(try await log.logged("widget shelf unreadable: "))

        try WidgetShelf.write(.running(.level(percent: 42, charging: true)), as: .macBattery, to: shelf)
        #expect(try WidgetShelf.load(.macBattery, from: .success(shelf), log: ShelfLog.log).get() == .running(.level(percent: 42, charging: true)))
        #expect(try await log.logged("widget shelf read: level(percent: 42, charging: true)"))
    }

    /// A test host quitting beside the installed app leaves `.appNotRunning` on the shared shelf; the
    /// running app's next state, though unchanged for it, puts the level back.
    @Test func anotherCopysMarkIsCorrectedByTheNextState() throws {
        let reloads = Reloads()
        let running = ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { if $0 == .macBattery { reloads.count += 1 } }
        let quitting = ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { _ in }

        running.publish(.level(percent: 50, charging: false))
        quitting.publishQuit()
        running.publish(.level(percent: 50, charging: false))
        #expect(try WidgetShelf.read(.macBattery, from: shelf).get() == .running(.level(percent: 50, charging: false)))
        #expect(reloads.count == 2)
    }

    @Test func eachStateDrawsWhatItSays() throws {
        func texts(_ battery: Result<Shelved<MacBattery>, any Error>) throws -> [String] {
            try MacBatteryView(entry: MacBatteryEntry(date: .now, battery: battery), appName: "Orange Drink").inspect().findAll(ViewType.Text.self).map { try $0.string() }
        }
        #expect(try texts(.success(.running(.level(percent: 80, charging: true)))) == ["80%"])
        #expect(try texts(.success(.running(.waiting))) == ["–"])
        #expect(try texts(.success(.running(.noBattery))) == ["No battery"])
        #expect(try texts(.success(.running(.ended))) == ["Battery unavailable"])
        #expect(try texts(.success(.appNotRunning)) == ["Open Orange Drink"])
        #expect(try texts(.failure(ShelfError.noGroupEntitlement)) == ["Open Orange Drink"])
    }

    /// The file the app wrote before the envelope: a bare value. The widget cannot read it, and the app's next
    /// state, though the same value, writes the new shape over it.
    @Test func aFileInTheShapeBeforeTheEnvelopeIsRewrittenByTheNextState() throws {
        try JSONEncoder().encode(MacBattery.level(percent: 50, charging: false)).write(to: shelf.appending(path: "mac.json"))
        #expect(throws: (any Error).self) { try WidgetShelf.read(.macBattery, from: shelf).get() as Shelved<MacBattery> }
        let reloads = Reloads()
        ShelfPublisher<MacBattery>(item: .macBattery, directory: shelf) { if $0 == .macBattery { reloads.count += 1 } }.publish(.level(percent: 50, charging: false))
        #expect(try WidgetShelf.read(.macBattery, from: shelf).get() == .running(.level(percent: 50, charging: false)))
        #expect(reloads.count == 1)
    }
}
