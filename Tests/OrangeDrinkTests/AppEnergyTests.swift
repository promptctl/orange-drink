import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a run of process snapshots leaves in the store:
// per-app energy over each interval, with the app's name and bundle identifier, surviving a relaunch.
@MainActor @Suite struct AppEnergyTests {
    static let editor = AppIdentity(key: "com.example.editor", name: "Editor", bundleID: "com.example.editor")
    static let browser = AppIdentity(key: "com.example.browser", name: "Browser", bundleID: "com.example.browser")
    static let tool = AppIdentity(key: "/usr/local/bin/tool", name: "tool", bundleID: nil)
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func process(_ pid: Int32, _ joules: Double, _ owner: AppIdentity, started: UInt64 = 1) -> ProcessEnergy {
        ProcessEnergy(key: .init(pid: pid, started: started), nanojoules: UInt64(joules * 1e9), owner: owner)
    }

    static func step(_ meter: inout AppEnergyMeter, _ processes: [ProcessEnergy], at: Date) throws -> AppEnergyInterval {
        let interval = meter.observe(processes, at: at)
        return try #require(interval)
    }

    @Test func theFirstSnapshotIsOnlyABaseline() {
        var meter = AppEnergyMeter()
        #expect(meter.observe([Self.process(1, 5, Self.editor)], at: Self.t0) == nil)
    }

    @Test func anIntervalHoldsEachAppsEnergyOverIt() throws {
        var meter = AppEnergyMeter()
        _ = meter.observe([Self.process(1, 5, Self.editor), Self.process(2, 1, Self.browser), Self.process(3, 2, Self.browser)], at: Self.t0)
        let interval = try Self.step(
            &meter, [Self.process(1, 8, Self.editor), Self.process(2, 4, Self.browser), Self.process(3, 2, Self.browser), Self.process(4, 1, Self.tool)],
            at: Self.t0.addingTimeInterval(120))
        #expect(interval.seconds == 120)
        // Editor +3 J, Browser +3 J (one helper idle), the new tool's whole 1 J.
        #expect(interval.entries.map(\.app) == [Self.browser, Self.editor, Self.tool])
        #expect(interval.entries.map(\.nanojoules) == [3_000_000_000, 3_000_000_000, 1_000_000_000])
        #expect(interval.totalNanojoules == 7_000_000_000)
    }

    @Test func aReusedPidIsANewProcessNotANegativeDelta() throws {
        var meter = AppEnergyMeter()
        _ = meter.observe([Self.process(1, 50, Self.editor, started: 10)], at: Self.t0)
        let interval = try Self.step(&meter, [Self.process(1, 2, Self.browser, started: 99)], at: Self.t0.addingTimeInterval(60))
        #expect(interval.entries.map(\.app) == [Self.browser])
        #expect(interval.totalNanojoules == 2_000_000_000)
    }

    @Test func aProcessThatFailedToReadOnceIsNotChargedItsWholeLifetime() throws {
        var meter = AppEnergyMeter()
        _ = meter.observe([Self.process(1, 5000, Self.editor)], at: Self.t0)
        _ = meter.observe([], at: Self.t0.addingTimeInterval(120))
        let interval = try Self.step(&meter, [Self.process(1, 5002, Self.editor)], at: Self.t0.addingTimeInterval(240))
        #expect(interval.totalNanojoules == 2_000_000_000)
    }

    @Test func onlyTheTopAppsAreKeptButTheTotalCountsThemAll() throws {
        var meter = AppEnergyMeter()
        let apps = (0..<(AppEnergyMeter.kept + 5)).map { AppIdentity(key: "app\($0)", name: "App \($0)", bundleID: nil) }
        _ = meter.observe([], at: Self.t0)
        let interval = try Self.step(&meter, apps.enumerated().map { Self.process(Int32($0.offset + 1), Double($0.offset + 1), $0.element) }, at: Self.t0.addingTimeInterval(60))
        #expect(interval.entries.count == AppEnergyMeter.kept)
        #expect(interval.entries.first?.app == apps.last)
        #expect(interval.totalNanojoules == UInt64((1...apps.count).reduce(0, +)) * 1_000_000_000)
    }

    @Test func storedIntervalsComeBackWithTheirNamesAndBundleIdentifiersAfterARelaunch() throws {
        let url = BatteryHistoryTests.tempFile()
        var meter = AppEnergyMeter()
        _ = meter.observe([Self.process(1, 1, Self.editor)], at: Self.t0)
        let first = try Self.step(&meter, [Self.process(1, 3, Self.editor), Self.process(2, 1, Self.tool)], at: Self.t0.addingTimeInterval(120))
        let second = try Self.step(&meter, [Self.process(1, 4, Self.editor), Self.process(2, 1, Self.tool)], at: Self.t0.addingTimeInterval(240))
        let store = try HistoryStore(url: url)
        try store.record(first)
        try store.record(second)
        #expect(try HistoryStore(url: url).appEnergy(since: Self.t0) == [first, second])
        #expect(try HistoryStore(url: url).appEnergy(since: Self.t0.addingTimeInterval(200)) == [second])
    }

    final class Scripted: ProcessEnergySource, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [[ProcessEnergy]]
        init(_ snapshots: [[ProcessEnergy]]) { self.snapshots = snapshots }
        func snapshot() throws -> [ProcessEnergy] { lock.withLock { snapshots.removeFirst() } }
    }

    @Test(.timeLimit(.minutes(1))) func theLoopStoresAnIntervalPerCadenceAndCountsTheWrite() async throws {
        let clock = ManualTimekeeper()
        let store = try HistoryStore(url: BatteryHistoryTests.tempFile())
        let changes = HistoryChanges()
        let source = Scripted([[Self.process(1, 1, Self.editor)], [Self.process(1, 4, Self.editor)], [Self.process(1, 6, Self.editor)]])
        let history = AppEnergyHistory(store: store, changes: changes, source: source, timekeeper: clock, interval: .seconds(120))
        await clock.asleep()
        #expect(changes.revision == 0)
        clock.advance(by: .seconds(120))
        while changes.revision < 1 { await Task.yield() }
        await clock.asleep()
        clock.advance(by: .seconds(120))
        while changes.revision < 2 { await Task.yield() }
        let stored = try store.appEnergy(since: .distantPast)
        #expect(stored.map(\.totalNanojoules) == [3_000_000_000, 2_000_000_000])
        withExtendedLifetime(history) {}
    }

    @Test func anExecutableOutsideABundleStandsForItselfAndABundleNamesItsApp() {
        let tool = RusageEnergySource.identity(executable: "/usr/local/bin/tool")
        #expect(tool == AppIdentity(key: "/usr/local/bin/tool", name: "tool", bundleID: nil))
        let finder = RusageEnergySource.identity(executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        #expect(finder.bundleID == "com.apple.finder" && finder.key == "com.apple.finder" && finder.name == "Finder")
    }

    @Test func theRealSourceSeesProcessesAndTheirOwners() throws {
        let processes = try RusageEnergySource().snapshot()
        #expect(processes.count > 50)
        #expect(processes.contains { $0.key.pid == getpid() })
    }
}

// The ticket's step on a real Mac, enabled by TEST_RUNNER_APP_ENERGY_CHECK (make app-energy-check): with
// `yes > /dev/null` running in Terminal, samples for a minute and finds Terminal holding the most stored energy.
@MainActor @Suite struct AppEnergyLive {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APP_ENERGY_CHECK"] != nil), .timeLimit(.minutes(3)))
    func terminalLeadsTheStoredEnergyWhileYesRuns() async throws {
        let store = try HistoryStore(url: BatteryHistoryTests.tempFile())
        let changes = HistoryChanges()
        let history = AppEnergyHistory(store: store, changes: changes, source: try RusageEnergySource(), interval: .seconds(10))
        while changes.revision < 5 { try await Task.sleep(for: .milliseconds(200)) }
        var energy: [AppIdentity: UInt64] = [:]
        for interval in try store.appEnergy(since: .distantPast) { for entry in interval.entries { energy[entry.app, default: 0] += entry.nanojoules } }
        let ranked = energy.sorted { $0.value > $1.value }
        print("app energy check, most stored energy first:", ranked.prefix(5).map { "\($0.key.name) (\($0.key.bundleID ?? "no bundle")) \(Double($0.value) / 1e9) J" })
        #expect(ranked.first?.key.bundleID == "com.apple.Terminal")
        withExtendedLifetime(history) {}
    }
}
