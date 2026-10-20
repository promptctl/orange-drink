import Foundation

/// An app as the history knows it: a bundle when it has one, otherwise the executable itself.
///
/// [LAW:types-are-the-program] A command-line tool is still something that draws energy; it has a
/// key and a name and no bundle identifier, which the type says instead of leaving a nil to guess at.
struct AppIdentity: Hashable, Sendable {
    /// The bundle identifier when there is one, else the executable's path: what the history groups by.
    let key: String
    let name: String
    let bundleID: String?
}

/// One process's lifetime energy counter, and the app it belongs to.
struct ProcessEnergy: Equatable, Sendable {
    /// A pid is reused after a process exits; the start time tells the two processes apart.
    struct Key: Hashable, Sendable {
        let pid: Int32
        let started: UInt64
    }

    let key: Key
    /// Energy since the process started, in nanojoules; it only grows.
    let nanojoules: UInt64
    let owner: AppIdentity
}

/// The energy apps used between two snapshots.
struct AppEnergyInterval: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let app: AppIdentity
        let nanojoules: UInt64
    }

    /// When the interval ended.
    let at: Date
    let seconds: TimeInterval
    /// Every app's energy together, so a share has a denominator that includes the apps below the cut.
    let totalNanojoules: UInt64
    /// The apps that used the most, most first.
    let entries: [Entry]
}

/// Turns successive snapshots of every process's energy counter into per-app energy over each interval.
///
/// [LAW:effects-at-boundaries] Snapshots and their times arrive as arguments, so a simulated hour is a
/// list of calls and nothing here reads a process.
struct AppEnergyMeter {
    /// Apps kept per interval; the rest are counted in the total only.
    static let kept = 20

    private var previous: (at: Date, counters: [ProcessEnergy.Key: UInt64])?

    /// nil for the first snapshot, which only sets the baseline the next one is measured from.
    mutating func observe(_ processes: [ProcessEnergy], at: Date) -> AppEnergyInterval? {
        defer { previous = (at, Dictionary(processes.map { ($0.key, $0.nanojoules) }) { _, last in last }) }
        guard let previous else { return nil }
        var byApp: [AppIdentity: UInt64] = [:]
        for process in processes {
            // A process not in the last snapshot started since, so all of its energy is this interval's.
            let before = previous.counters[process.key] ?? 0
            byApp[process.owner, default: 0] += process.nanojoules > before ? process.nanojoules - before : 0
        }
        let ranked = byApp.filter { $0.value > 0 }.sorted { ($0.value, $1.key.key) > ($1.value, $0.key.key) }
        return AppEnergyInterval(
            at: at, seconds: at.timeIntervalSince(previous.at), totalNanojoules: byApp.values.reduce(0, +),
            entries: ranked.prefix(Self.kept).map { AppEnergyInterval.Entry(app: $0.key, nanojoules: $0.value) })
    }
}
