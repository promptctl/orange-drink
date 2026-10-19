import Foundation
import OSLog

/// Records the battery's history as readings and screen changes arrive.
///
/// [LAW:composability] It is handed its store, its clock, and its screen, so a test runs a
/// simulated day through it and a relaunch is a second store opened on the same file.
@MainActor final class BatteryHistory {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "history")

    private let store: HistoryStore
    private let timekeeper: any Timekeeper
    private var recorder: HistoryRecorder
    /// [LAW:types-are-the-program] exception: assigned after init by `follow`, which needs `self`.
    @ObservationIgnored nonisolated(unsafe) private var screenTask: Task<Void, Never>?

    init(store: HistoryStore, timekeeper: any Timekeeper = SystemTimekeeper(), calendar: Calendar = .current) {
        self.store = store
        self.timekeeper = timekeeper
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
        do { try store.apply(write) } catch {
            Self.log.error("history write failed: \(String(describing: error), privacy: .public)")
            recorder.restore(write)
        }
    }

    deinit { screenTask?.cancel() }
}
