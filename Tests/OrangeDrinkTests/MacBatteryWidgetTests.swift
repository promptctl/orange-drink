import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the widget reads off the shelf after each state
// the model takes, through the widget's own read path, from a shelf in a directory of the test's own.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MacBatteryWidgetTests {
    struct StreamEnded: Error {}

    final class Reloads {
        var count = 0
    }

    static func shelf() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The model the app builds, its states published the way the app publishes them.
    static func model(readings: AsyncThrowingStream<BatteryReading?, any Error>, shelf: URL, reloads: Reloads) -> BatteryModel {
        let widgets = MacBatteryPublisher(directory: shelf) { reloads.count += 1 }
        return BatteryModel(readings: readings, onState: { widgets.publish(MacBattery($0)) })
    }

    @Test func theWidgetReadsEachReadingInTurnThenTheEnd() async throws {
        let shelf = try Self.shelf()
        let (readings, feed) = AsyncThrowingStream.makeStream(of: BatteryReading?.self)
        let model = Self.model(readings: readings, shelf: shelf, reloads: Reloads())
        #expect(try WidgetShelf.read(from: shelf).get() == .waiting)

        let charging = try BatteryHistoryTests.charging(80)
        feed.yield(charging)
        _ = await model.state { if case .known(let held) = $0 { held == charging } else { false } }
        #expect(try WidgetShelf.read(from: shelf).get() == .level(percent: 80, charging: true))

        let onBattery = try BatteryHistoryTests.onBattery(79)
        feed.yield(onBattery)
        _ = await model.state { if case .known(let held) = $0 { held == onBattery } else { false } }
        #expect(try WidgetShelf.read(from: shelf).get() == .level(percent: 79, charging: false))

        feed.finish(throwing: StreamEnded())
        _ = await model.state(once: BatteryModel.isEnded)
        #expect(try WidgetShelf.read(from: shelf).get() == .ended)
    }

    @Test func aValueTheShelfHoldsCostsNoWriteAndNoReload() throws {
        let shelf = try Self.shelf()
        let reloads = Reloads()
        let widgets = MacBatteryPublisher(directory: shelf) { reloads.count += 1 }

        widgets.publish(.level(percent: 50, charging: false))
        widgets.publish(.level(percent: 50, charging: false))
        #expect(reloads.count == 1)
    }

    /// A test host quitting beside the installed app leaves `.appNotRunning` on the shared shelf; the
    /// running app's next state, though unchanged for it, puts the level back.
    @Test func anotherCopysMarkIsCorrectedByTheNextState() throws {
        let shelf = try Self.shelf()
        let reloads = Reloads()
        let running = MacBatteryPublisher(directory: shelf) { reloads.count += 1 }
        let quitting = MacBatteryPublisher(directory: shelf) {}

        running.publish(.level(percent: 50, charging: false))
        quitting.publish(.appNotRunning)
        running.publish(.level(percent: 50, charging: false))
        #expect(try WidgetShelf.read(from: shelf).get() == .level(percent: 50, charging: false))
        #expect(reloads.count == 2)
    }
}
