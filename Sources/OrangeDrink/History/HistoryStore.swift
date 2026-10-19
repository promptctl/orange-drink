import Foundation
import GRDB

/// The battery history on disk. It survives quitting and relaunching because it is a file; the
/// schema is a migration, so a later ticket adds a table by adding a migration here.
///
/// [LAW:single-enforcer] The only code that speaks SQL for the history. The recorder describes
/// writes, the Battery screen reads through the two readers below.
final class HistoryStore: Sendable {
    private let queue: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("batteryHistory") { db in
            try db.create(table: "batterySample") { table in
                table.primaryKey("at", .double)
                table.column("level", .integer).notNull()
                table.column("charging", .boolean).notNull()
                table.column("health", .double).notNull()
                table.column("celsius", .double).notNull()
            }
            try db.create(table: "dailyUsage") { table in
                table.primaryKey("day", .double)
                table.column("dischargedPercent", .integer).notNull()
                table.column("screenOnSeconds", .double).notNull()
            }
        }
        try migrator.migrate(queue)
    }

    /// Where the app keeps its history: its own folder in Application Support.
    static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(IOKitBattery.logSubsystem, isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    /// One transaction: the sample and every day's increment land together or not at all.
    func apply(_ write: HistoryWrite) throws {
        try queue.write { db in
            if let sample = write.sample {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO batterySample (at, level, charging, health, celsius) VALUES (?, ?, ?, ?, ?)",
                    arguments: [sample.at.timeIntervalSince1970, sample.level, sample.charging, sample.health,
                                sample.temperature.converted(to: .celsius).value])
            }
            for (day, usage) in write.days {
                try db.execute(sql: """
                    INSERT INTO dailyUsage (day, dischargedPercent, screenOnSeconds) VALUES (?, ?, ?)
                    ON CONFLICT (day) DO UPDATE SET
                        dischargedPercent = dailyUsage.dischargedPercent + excluded.dischargedPercent,
                        screenOnSeconds = dailyUsage.screenOnSeconds + excluded.screenOnSeconds
                    """, arguments: [day.timeIntervalSince1970, usage.dischargedPercent, usage.screenOn])
            }
        }
    }

    /// Samples at or after `since`, oldest first.
    func samples(since: Date) throws -> [HistorySample] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM batterySample WHERE at >= ? ORDER BY at", arguments: [since.timeIntervalSince1970])
                .map(Self.sample)
        }
    }

    private static func sample(_ row: Row) -> HistorySample {
        HistorySample(at: Date(timeIntervalSince1970: row["at"]), level: row["level"], charging: row["charging"],
                      health: row["health"], temperature: .init(value: row["celsius"], unit: .celsius))
    }

    /// Every recorded day, keyed by the start of the local day it was recorded for.
    func dailyUsage() throws -> [Date: DayUsage] {
        try queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM dailyUsage").map { row in
                (Date(timeIntervalSince1970: row["day"]), DayUsage(dischargedPercent: row["dischargedPercent"], screenOn: row["screenOnSeconds"]))
            })
        }
    }
}
