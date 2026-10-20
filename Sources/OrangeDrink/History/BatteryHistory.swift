import Foundation
import Observation
import OSLog

/// Records the battery's history as readings and screen changes arrive.
///
/// [LAW:composability] It is handed its store, its clock, and its screen, so a test runs a
/// simulated day through it and a relaunch is a second store opened on the same file.
@Observable @MainActor final class BatteryHistory {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "history")

    let changes: HistoryChanges
    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let timekeeper: any Timekeeper
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var recorder: HistoryRecorder
    /// [LAW:types-are-the-program] exception: assigned after init by `follow`, which needs `self`.
    @ObservationIgnored nonisolated(unsafe) private var screenTask: Task<Void, Never>?

    init(store: HistoryStore, changes: HistoryChanges = HistoryChanges(), timekeeper: any Timekeeper = SystemTimekeeper(), calendar: Calendar = .current) {
        self.store = store
        self.changes = changes
        self.timekeeper = timekeeper
        self.calendar = calendar
        recorder = HistoryRecorder(calendar: calendar, launchedAt: timekeeper.now())
    }

    /// A Mac with no battery has no history to keep.
    func observe(_ reading: BatteryReading?) {
        guard let reading else { return }
        persist(recorder.observe(reading, at: timekeeper.now()))
    }

    func screenChanged(on: Bool) { persist(recorder.screen(on: on, at: timekeeper.now())) }

    /// Credits the open screen interval and what is pending, as the app quits.
    func flush() { persist(recorder.flush(at: timekeeper.now())) }

    /// What the Battery Level card shows for `range`, read from the store as of now.
    func timeline(range: HistoryRange) throws -> BatteryLevelTimeline {
        let now = timekeeper.now()
        return BatteryLevelTimeline(
            range: range, now: now, samples: try store.samples(since: now.addingTimeInterval(-BatteryLevelTimeline.lookback)))
    }

    /// What the Daily Usage and Battery Health cards show, read from the store as of now.
    func overview() throws -> BatteryOverview {
        let rows = try store.overviewRows()
        return BatteryOverview(usage: rows.usage, healthSamples: rows.healthSamples, calendar: calendar, collectedAt: rows.latestSample)
    }

    func follow<Changes: AsyncSequence & Sendable>(screen changes: Changes) where Changes.Element == Bool {
        screenTask = Task { [weak self] in
            do {
                for try await on in changes {
                    guard let self else { return }
                    self.screenChanged(on: on)
                }
            } catch { Self.log.error("screen changes ended: \(String(describing: error), privacy: .public)") }
        }
    }

    private func persist(_ write: HistoryWrite) {
        guard !write.isEmpty else { return }
        do {
            try store.apply(write)
            changes.wrote()
        } catch {
            Self.log.error("history write failed: \(String(describing: error), privacy: .public)")
            recorder.restore(write)
        }
    }

    deinit { screenTask?.cancel() }
}
