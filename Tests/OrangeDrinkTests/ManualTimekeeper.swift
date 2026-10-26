import Foundation
@testable import OrangeDrink

/// A clock a test moves by hand: `advance` is the only thing that makes time pass, and it
/// wakes every sleeper whose time has come.
final class ManualTimekeeper: Timekeeper, @unchecked Sendable {
    private struct Sleeper { let wakes: Date; let continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var sleepers: [UUID: Sleeper] = [:]
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func now() -> Date { lock.withLock { current } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // A task cancelled before it got here has already run onCancel, which found no sleeper to remove; checked
                // under the lock onCancel takes, so a cancellation is seen here or by onCancel, never by neither.
                enum Outcome { case cancelled, due, asleep(waking: [CheckedContinuation<Void, Never>]) }
                let outcome: Outcome = lock.withLock {
                    guard !Task.isCancelled else { return .cancelled }
                    let wakes = current.addingTimeInterval(duration / .seconds(1))
                    // A sleep whose time has already come returns at once, as Task.sleep does; it never becomes a sleeper.
                    guard wakes > current else { return .due }
                    sleepers[id] = Sleeper(wakes: wakes, continuation: continuation)
                    defer { arrivals = [] }
                    return .asleep(waking: arrivals)
                }
                switch outcome {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .asleep(let waiting): waiting.forEach { $0.resume() }
                }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Returns once something is asleep on this clock. A test advances time only after this, so
    /// the sleeper it means to wake is already waiting and the advance cannot slip past it.
    func asleep() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if sleepers.isEmpty { arrivals.append(continuation); return false }
                return true
            }
            if ready { continuation.resume() }
        }
    }

    /// How many sleeps are waiting on this clock. A cancelled sleep leaves at once, in its
    /// cancellation handler, so a test reads this with no yield in between.
    var sleeping: Int { lock.withLock { sleepers.count } }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            current = current.addingTimeInterval(duration / .seconds(1))
            let due = sleepers.filter { $0.value.wakes <= current }
            due.keys.forEach { sleepers.removeValue(forKey: $0) }
            return due.values
        }
        due.forEach { $0.continuation.resume() }
    }
}
