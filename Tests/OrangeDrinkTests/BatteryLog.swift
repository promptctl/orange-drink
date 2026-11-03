import Foundation
import OSLog
@testable import OrangeDrink

/// The battery log from the moment of construction on. [LAW:one-source-of-truth] The one
/// capture every log assertion reads; Logger.info lines are memory-only, so `log show` cannot
/// replace it and OSLogStore in-process can.
struct BatteryLog {
    private let store: OSLogStore
    private let since: OSLogPosition
    private let category: String
    private let begins: String
    private static let beginsPrefix = "test log begins "

    /// [LAW:no-ambient-temporal-coupling] The log begins at a line it writes itself, not at a date: the
    /// position a date gives, and the dates on entries, are too coarse to tell lines another test wrote
    /// just before this log began from this test's own. Returns once that line has reached OSLogStore,
    /// so a log that reads nothing has read something.
    init(category: String = IOKitBattery.logCategory) async throws {
        self.category = category
        store = try OSLogStore(scope: .currentProcessIdentifier)
        since = store.position(date: Date().addingTimeInterval(-1))
        let begins = "\(Self.beginsPrefix)\(UUID().uuidString)"
        self.begins = begins
        Logger(subsystem: IOKitBattery.logSubsystem, category: category).info("\(begins, privacy: .public)")
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while try entries().firstIndex(of: begins) == nil {
            guard ContinuousClock.now < end else { throw Missing(begins: begins) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct Missing: Error, CustomStringConvertible {
        let begins: String
        var description: String { "the line this log begins at is not in OSLogStore: \(begins)" }
    }

    private func entries() throws -> [String] {
        try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                              IOKitBattery.logSubsystem, category))
            .map(\.composedMessage)
    }

    /// The lines after this log's own first line, less the first lines of other tests' logs.
    func messages() throws -> [String] {
        let all = try entries()
        guard let first = all.firstIndex(of: begins) else { throw Missing(begins: begins) }
        return all[(first + 1)...].filter { !$0.hasPrefix(Self.beginsPrefix) }
    }

    /// Polls the log until a line contains `fragment`: log entries reach OSLogStore shortly after they are written.
    func logged(_ fragment: String) async throws -> Bool {
        try await count(fragment, awaiting: 1) > 0
    }

    /// How many lines contain `fragment`, counted once `expected` of them have reached OSLogStore or five seconds have
    /// passed, so a count read just after the lines were written does not come up short.
    func count(_ fragment: String, awaiting expected: Int) async throws -> Int {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let count = try messages().filter { $0.contains(fragment) }.count
            if count >= expected || ContinuousClock.now >= end { return count }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
