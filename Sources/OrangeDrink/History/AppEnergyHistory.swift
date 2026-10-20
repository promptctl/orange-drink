import Foundation
import OSLog

/// Records how much energy each app used, a snapshot every `interval`.
///
/// [LAW:no-ambient-temporal-coupling] One loop owns the cadence; it lives as long as this object does,
/// and the clock is the `Timekeeper` a test advances by hand.
@MainActor final class AppEnergyHistory {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "app-energy")

    /// Minutes, not seconds: the qvj spike measured a snapshot at about 5 ms of CPU, so every 5 s alone
    /// would take 0.09% of PROJECT.md's 0.1%. This is the sampling budget's lever and nothing else's.
    nonisolated static let interval = Duration.seconds(120)

    let changes: HistoryChanges
    private let store: HistoryStore
    private let source: any ProcessEnergySource
    private let timekeeper: any Timekeeper
    private var meter = AppEnergyMeter()
    nonisolated(unsafe) private var loop: Task<Void, Never>?

    init(store: HistoryStore, changes: HistoryChanges, source: any ProcessEnergySource, timekeeper: any Timekeeper = SystemTimekeeper(), interval: Duration = AppEnergyHistory.interval) {
        self.store = store
        self.changes = changes
        self.source = source
        self.timekeeper = timekeeper
        // The first snapshot is the baseline; each later one is an interval.
        loop = Task { [weak self] in
            // `self` is held only while sampling, so a dropped object ends the loop during the sleep.
            while !Task.isCancelled {
                guard await self?.sample() != nil else { return }
                do { try await timekeeper.sleep(for: interval) } catch { return }
            }
        }
    }

    /// The stored intervals the App Usage screen ranks: the longest range back from now, oldest first.
    func ranking(range: AppUsageRange) throws -> AppUsageRanking {
        let now = timekeeper.now()
        let longest = AppUsageRange.allCases.map(\.duration).max() ?? 0
        return AppUsageRanking(intervals: try store.appEnergy(since: now.addingTimeInterval(-longest)), firstInterval: try store.firstIntervalTime(), now: now, range: range)
    }

    /// The Right Now list, read from the newest stored interval alone; empty before any.
    func rightNow() throws -> [AppShare] {
        AppUsageRanking.rightNow(of: try store.latestAppEnergy().map(AppUsageRanking.shares(of:)) ?? [])
    }

    /// Takes one snapshot off the main actor and records the interval it closes.
    func sample() async {
        let source = source
        do {
            let processes = try await Task.detached(priority: .utility) { try source.snapshot() }.value
            guard let interval = meter.observe(processes, at: timekeeper.now()) else { return }
            try store.record(interval)
            changes.wrote()
        } catch {
            Self.log.error("app energy sample failed: \(String(describing: error), privacy: .public)")
        }
    }

    deinit { loop?.cancel() }
}
