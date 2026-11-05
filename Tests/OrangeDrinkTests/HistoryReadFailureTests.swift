import Foundation
import SQLite3
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is that a history whose read fails says so in its own log, and the
// screen that asked still gets the error to show.
@MainActor @Suite struct HistoryReadFailureTests {
    /// A store opened on `url`, whose every table a second connection then drops, so every read of it throws.
    static func unreadable(_ url: URL) throws -> HistoryStore {
        let store = try HistoryStore(url: url)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        var tables: [String] = []
        var query: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", -1, &query, nil) == SQLITE_OK)
        while sqlite3_step(query) == SQLITE_ROW { tables.append(String(cString: sqlite3_column_text(query, 0))) }
        sqlite3_finalize(query)
        try #require(!tables.isEmpty)
        let dropped = sqlite3_exec(db, tables.map { "DROP TABLE \"\($0)\";" }.joined(), nil, nil, nil)
        try #require(dropped == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        return store
    }

    @Test func anAppEnergyReadThatFailsIsLoggedByTheHistory() async throws {
        let log = try await TestLog()
        let store = try Self.unreadable(BatteryHistoryTests.tempFile())
        // One empty snapshot: the loop's baseline, which writes nothing.
        let history = AppEnergyHistory(store: store, log: log.logger, changes: HistoryChanges(), source: AppEnergyTests.Scripted([[]]), timekeeper: ManualTimekeeper())
        #expect(throws: (any Error).self) { try history.ranking(range: .day) }
        #expect(throws: (any Error).self) { try history.rightNow() }
        #expect(try await log.logged("app usage unreadable"))
        #expect(try await log.logged("app energy right now unreadable"))
        withExtendedLifetime(history) {}
    }

    @Test func aBatteryReadThatFailsIsLoggedByTheHistory() async throws {
        let log = try await TestLog()
        let history = BatteryHistory(store: try Self.unreadable(BatteryHistoryTests.tempFile()), log: log.logger, timekeeper: BatteryHistoryTests.Clock(.now), calendar: BatteryHistoryTests.utc)
        #expect(throws: (any Error).self) { try history.timeline(range: .day) }
        #expect(throws: (any Error).self) { try history.overview() }
        #expect(try await log.logged("battery timeline unreadable"))
        #expect(try await log.logged("battery overview unreadable"))
    }
}
