import Foundation
import OSLog
@testable import OrangeDrink

/// One test's log, from the moment of construction on. [LAW:one-source-of-truth] The one
/// capture every log assertion reads; Logger.info lines are memory-only, so `log show` cannot
/// replace it and OSLogStore in-process can.
/// [LAW:types-are-the-program] It reads only lines written through `logger`, which the test hands to its subject.
struct TestLog {
    let logger: Logger
    private let store: OSLogStore
    private let since: OSLogPosition
    private let category: String
    private let begins = Self.own + "begins \(UUID().uuidString)"
    private static let mark = Self.own + "read to "
    /// The prefix of every line a log writes itself, this one's and those of another log on the same category.
    private static let own = "test log "

    /// A log on a category of its own, so no other test, and not the hosted app, writes a line it reads.
    init() async throws {
        try await self.init(category: "test-\(UUID().uuidString)")
    }

    /// [LAW:no-ambient-temporal-coupling] The log begins at a line it writes itself, not at a date: a category can be
    /// shared with a subject made before the log (LaunchStep's), and the position a date gives is too coarse to tell
    /// a line written just before this log began from one written after. Returns once that line has reached
    /// OSLogStore, so a log that reads nothing has read something.
    init(category: String) async throws {
        self.category = category
        logger = Logger(subsystem: IOKitBattery.logSubsystem, category: category)
        store = try OSLogStore(scope: .currentProcessIdentifier)
        since = store.position(date: Date().addingTimeInterval(-1))
        try await reach(begins)
    }

    /// Reads `done` every 20 ms until it holds or five seconds have passed; whether it held.
    private static func poll(until done: () throws -> Bool) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if try done() { return true }
            if ContinuousClock.now >= end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct Missing: Error, CustomStringConvertible {
        let line: String
        var description: String { "a line this log wrote itself is not in OSLogStore: \(line)" }
    }

    /// Writes `line` and returns once it has reached OSLogStore.
    private func reach(_ line: String) async throws {
        logger.info("\(line, privacy: .public)")
        guard try await Self.poll(until: { try entries().contains(line) }) else { throw Missing(line: line) }
    }

    private func entries() throws -> [String] {
        try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                              IOKitBattery.logSubsystem, category))
            .map(\.composedMessage)
    }

    /// The lines after this log's own first line, other than those a log writes itself.
    private func written() throws -> [String] {
        let all = try entries()
        guard let first = all.firstIndex(of: begins) else { throw Missing(line: begins) }
        return all[(first + 1)...].filter { !$0.hasPrefix(Self.own) }
    }

    /// [LAW:no-ambient-temporal-coupling] Every line written before this call: it writes a mark and reads once the mark
    /// has reached OSLogStore, which a process's lines reach in the order they were written. So a line the subject has
    /// not written is absent for that reason, and not because it is still on its way.
    func messages() async throws -> [String] {
        try await reach(Self.mark + UUID().uuidString)
        return try written()
    }

    /// Polls the log until a line contains `fragment`: log entries reach OSLogStore shortly after they are written.
    func logged(_ fragment: String) async throws -> Bool {
        try await count(fragment, awaiting: 1) > 0
    }

    /// How many lines contain `fragment`, counted once `expected` of them have reached OSLogStore or five seconds have
    /// passed, so a count read just after the lines were written does not come up short.
    func count(_ fragment: String, awaiting expected: Int) async throws -> Int {
        var count = 0
        _ = try await Self.poll {
            count = try written().filter { $0.contains(fragment) }.count
            return count >= expected
        }
        return count
    }
}
