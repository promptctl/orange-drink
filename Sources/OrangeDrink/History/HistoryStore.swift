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
        migrator.registerMigration("appEnergy") { db in
            try db.create(table: "app") { table in
                table.primaryKey("key", .text)
                table.column("name", .text).notNull()
                table.column("bundleID", .text)
            }
            try db.create(table: "appEnergyInterval") { table in
                table.primaryKey("at", .double)
                table.column("seconds", .double).notNull()
                table.column("totalNanojoules", .integer).notNull()
            }
            try db.create(table: "appEnergy") { table in
                table.column("at", .double).notNull().references("appEnergyInterval", onDelete: .cascade)
                table.column("appKey", .text).notNull().references("app")
                table.column("nanojoules", .integer).notNull()
                table.primaryKey(["at", "appKey"])
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

    /// One interval of per-app energy, with the apps it names, in one transaction.
    func record(_ interval: AppEnergyInterval) throws {
        try queue.write { db in
            let at = interval.at.timeIntervalSince1970
            try db.execute(sql: "INSERT OR REPLACE INTO appEnergyInterval (at, seconds, totalNanojoules) VALUES (?, ?, ?)",
                           arguments: [at, interval.seconds, Int64(clamping: interval.totalNanojoules)])
            try db.execute(sql: "DELETE FROM appEnergy WHERE at = ?", arguments: [at])
            for entry in interval.entries {
                try db.execute(sql: "INSERT INTO app (key, name, bundleID) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET name = excluded.name, bundleID = excluded.bundleID",
                               arguments: [entry.app.key, entry.app.name, entry.app.bundleID])
                try db.execute(sql: "INSERT INTO appEnergy (at, appKey, nanojoules) VALUES (?, ?, ?)",
                               arguments: [at, entry.app.key, Int64(clamping: entry.nanojoules)])
            }
        }
    }

    /// Intervals that ended at or after `since`, oldest first.
    func appEnergy(since: Date) throws -> [AppEnergyInterval] {
        try queue.read { db in
            let since = since.timeIntervalSince1970
            var entries: [Double: [AppEnergyInterval.Entry]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT appEnergy.at, app.key, app.name, app.bundleID, appEnergy.nanojoules
                FROM appEnergy JOIN app ON app.key = appEnergy.appKey
                WHERE appEnergy.at >= ? ORDER BY appEnergy.nanojoules DESC, app.key
                """, arguments: [since]) {
                entries[row["at"], default: []].append(AppEnergyInterval.Entry(
                    app: AppIdentity(key: row["key"], name: row["name"], bundleID: row["bundleID"]), nanojoules: UInt64(row["nanojoules"] as Int64)))
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM appEnergyInterval WHERE at >= ? ORDER BY at", arguments: [since]).map { interval in
                AppEnergyInterval(at: Date(timeIntervalSince1970: interval["at"]), seconds: interval["seconds"],
                                  totalNanojoules: UInt64(interval["totalNanojoules"] as Int64), entries: entries[interval["at"] as Double] ?? [])
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

    /// What the Daily Usage and Battery Health cards chart, read in one transaction so the days, the
    /// health, and the freshness describe the same moment of the history.
    func overviewRows() throws -> (usage: [Date: DayUsage], healthSamples: [(at: Date, health: Double)], latestSample: Date?) {
        try queue.read { db in
            // Two columns of health, so years of history stay cheap to read.
            let health = try Row.fetchAll(db, sql: "SELECT at, health FROM batterySample ORDER BY at").map { (Date(timeIntervalSince1970: $0["at"]), $0["health"] as Double) }
            return (try Self.usage(db), health, try Double.fetchOne(db, sql: "SELECT max(at) FROM batterySample").map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// Every recorded day, keyed by the start of the local day it was recorded for.
    func dailyUsage() throws -> [Date: DayUsage] { try queue.read(Self.usage) }

    private static func usage(_ db: Database) throws -> [Date: DayUsage] {
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM dailyUsage").map { row in
            (Date(timeIntervalSince1970: row["day"]), DayUsage(dischargedPercent: row["dischargedPercent"], screenOn: row["screenOnSeconds"]))
        })
    }
}
