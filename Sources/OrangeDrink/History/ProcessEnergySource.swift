import Darwin
import Foundation

/// Every readable process's energy counter, each tied to the app it belongs to.
protocol ProcessEnergySource: Sendable {
    func snapshot() throws -> [ProcessEnergy]
}

enum ProcessEnergyError: Error, Equatable {
    /// macOS has no public per-app energy API; the owner of a helper or XPC service comes from this private
    /// symbol, and without it the energy would be attributed by a different rule.
    case noResponsibilitySymbol
}

/// [LAW:effects-at-boundaries] The one edge that reads process energy (the method the qvj spike chose):
/// `proc_pid_rusage`'s energy counter per process, grouped under the process the system holds responsible
/// for it, which is how a browser's helpers land under the browser. Processes this user may not read
/// (root daemons) are absent.
final class RusageEnergySource: ProcessEnergySource, @unchecked Sendable {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t

    private let responsible: Responsible
    /// Owners by executable path, so a snapshot of a thousand processes reads a bundle's Info.plist once.
    private let lock = NSLock()
    private var identities: [String: AppIdentity] = [:]

    init() throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            throw ProcessEnergyError.noResponsibilitySymbol
        }
        responsible = unsafeBitCast(symbol, to: Responsible.self)
    }

    func snapshot() throws -> [ProcessEnergy] {
        try Processes.all().compactMap { pid -> ProcessEnergy? in
            guard pid > 0, let usage = Self.usage(pid) else { return nil }
            guard let identity = owner(of: pid) else { return nil }
            return ProcessEnergy(key: .init(pid: pid, started: usage.ri_proc_start_abstime), age: Self.seconds(since: usage.ri_proc_start_abstime),
                                 nanojoules: usage.ri_energy_nj, owner: identity)
        }
    }

    /// mach_absolute_time ticks are not nanoseconds on Apple silicon; the timebase converts them.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func seconds(since started: UInt64) -> TimeInterval {
        let ticks = mach_absolute_time() &- started
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// The app a process belongs to: the one the system holds responsible for it. launchd is responsible for
    /// the processes nothing else claims; those stand for themselves.
    func owner(of pid: pid_t) -> AppIdentity? {
        let responsible = responsible(pid)
        return identity(ofProcess: responsible > 1 ? responsible : pid) ?? identity(ofProcess: pid)
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return status == 0 ? usage : nil
    }

    private func identity(ofProcess pid: pid_t) -> AppIdentity? {
        guard let path = Processes.executablePath(of: pid) else { return nil }
        return lock.withLock {
            if let known = identities[path] { return known }
            let made = Self.identity(executable: path)
            identities[path] = made
            return made
        }
    }

    /// The enclosing .app is the app; an executable outside any bundle stands for itself.
    static func identity(executable path: String) -> AppIdentity {
        guard let range = path.range(of: ".app/") else {
            return AppIdentity(key: path, name: URL(fileURLWithPath: path).lastPathComponent, bundleID: nil)
        }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let bundle = Bundle(path: bundlePath)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        return AppIdentity(key: bundleID ?? bundlePath, name: name, bundleID: bundleID)
    }
}
