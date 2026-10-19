import Foundation

/// The model's clock and its sleep, as one seam: the app hands it the system's, a test a clock
/// it advances by hand, so "two minutes later" costs no time and depends on none.
///
/// [LAW:effects-at-boundaries] Time is read and waited on only through this.
protocol Timekeeper: Sendable {
    func now() -> Date
    /// Returns when `duration` has passed on this clock, and throws if the task is cancelled first.
    func sleep(for duration: Duration) async throws
}

struct SystemTimekeeper: Timekeeper {
    func now() -> Date { Date() }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
