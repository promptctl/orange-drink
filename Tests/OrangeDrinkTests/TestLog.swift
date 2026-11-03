import Foundation
import OSLog
@testable import OrangeDrink

/// One test's log, from the moment of construction on. [LAW:one-source-of-truth] The one
/// capture every log assertion reads; Logger.info lines are memory-only, so `log show` cannot
/// replace it and OSLogStore in-process can.
/// [LAW:types-are-the-program] It reads every line on its category: on one of its own, only those written through
/// `logger`, which the test hands to its subject.
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
        try await self.init(following: "test-\(UUID().uuidString)")
    }

    /// A log on `category`, which a subject made before the log writes to (LaunchStep's registration): it reads every
    /// line on it, so the category must be one no other subject writes to.
    ///
    /// [LAW:no-ambient-temporal-coupling] The log begins at a line it writes itself, not at a date: the position a date
    /// gives is too coarse to tell a line written just before this log began from one written after. Returns once that
    /// line has reached OSLogStore, so a log that reads nothing has read something.
    init(following category: String) async throws {
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

    /// The levels a subject writes at. Info is held in memory and notice and error are persisted, by paths nothing orders
    /// against each other, so a line at one level says nothing of when a line at another reaches OSLogStore.
    private static let levels: [OSLogType] = [.info, .default, .error]

    /// Writes `line` once at each level, each copy marked with its level, and returns once every copy has reached OSLogStore.
    private func reach(_ line: String) async throws {
        let copies = Self.levels.map { level in
            let copy = "\(line) at \(level.rawValue)"
            logger.log(level: level, "\(copy, privacy: .public)")
            return copy
        }
        guard try await Self.poll(until: { Set(copies).isSubset(of: try entries()) }) else { throw Missing(line: line) }
    }

    private func entries() throws -> [String] {
        try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                              IOKitBattery.logSubsystem, category))
            .map(\.composedMessage)
    }

    /// The lines after this log's own first line, other than those a log writes itself. The first is any copy of
    /// `begins`: the info copy rolls out of memory in a check that runs for minutes, and the persisted copies stay.
    private func written() throws -> [String] {
        let all = try entries()
        guard let first = all.firstIndex(where: { $0.hasPrefix(begins) }) else { throw Missing(line: begins) }
        return all[(first + 1)...].filter { !$0.hasPrefix(Self.own) }
    }

    /// [LAW:no-ambient-temporal-coupling] Every line written before this call: it writes a mark at each level and reads
    /// once every copy has reached OSLogStore, which a process's lines at one level reach in the order they were written.
    /// So a line the subject has not written is absent for that reason, and not because it is still on its way.
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
