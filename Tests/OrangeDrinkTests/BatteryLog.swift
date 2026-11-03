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

    /// [LAW:no-ambient-temporal-coupling] The log begins at a line it writes itself, not at a date: the
    /// position a date gives, and the dates on entries, are too coarse to tell lines another test wrote
    /// just before this log began from this test's own.
    init(category: String = IOKitBattery.logCategory) throws {
        self.category = category
        store = try OSLogStore(scope: .currentProcessIdentifier)
        since = store.position(date: Date().addingTimeInterval(-1))
        let begins = "test log begins \(UUID().uuidString)"
        self.begins = begins
        Logger(subsystem: IOKitBattery.logSubsystem, category: category).info("\(begins, privacy: .public)")
    }

    /// The lines after this log's own first line; none until that line has reached OSLogStore, since every
    /// line after it reaches the store after it.
    func messages() throws -> [String] {
        let all = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                                        IOKitBattery.logSubsystem, category))
            .map(\.composedMessage)
        guard let first = all.firstIndex(of: begins) else { return [] }
        return Array(all[(first + 1)...])
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
