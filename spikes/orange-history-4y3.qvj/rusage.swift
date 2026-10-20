// Prototype A: per-process energy from proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj, sampled twice.
// Usage: rusage <seconds between samples> [samples]. Prints the top ten by energy over the window, the
// processes it could not read, and this process's own CPU time spent sampling.
import Darwin
import Foundation

struct Snapshot { var nanojoules: [pid_t: UInt64] = [:]; var unreadable = 0 }

func pids() -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 4096)
    // Returns the number of pids, not bytes.
    let count = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
}

func snapshot() -> Snapshot {
    var result = Snapshot()
    for pid in pids() {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        if status == 0 { result.nanojoules[pid] = usage.ri_energy_nj } else { result.unreadable += 1 }
    }
    return result
}

func name(_ pid: pid_t) -> String {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "?" }
    return String(cString: path)
}

/// The pid macOS holds responsible for `pid`: the app a helper, XPC service or child belongs to, as the
/// system's own energy and privacy attribution groups them. A private symbol, found at run time.
typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
let responsible: ResponsibleFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFunction.self) }

/// The enclosing .app bundle's path, or the executable itself for a daemon or command-line tool.
func app(_ path: String) -> String {
    if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
    return path
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

let arguments = CommandLine.arguments
let interval = arguments.count > 1 ? Double(arguments[1])! : 10
let samples = max(2, arguments.count > 2 ? Int(arguments[2])! : 2)
let cpuStart = cpuSeconds()
let wallStart = Date()
var previous = snapshot()
var totals: [pid_t: UInt64] = [:]
var last = previous
for _ in 1..<samples {
    Thread.sleep(forTimeInterval: interval)
    last = snapshot()
    for (pid, nj) in last.nanojoules { if let before = previous.nanojoules[pid], nj >= before { totals[pid, default: 0] += nj - before } }
    previous = last
}
let window = Double(samples - 1) * interval
let sum = totals.values.reduce(0, +)
print("window \(window)s, \(totals.count) processes with an energy delta, \(last.nanojoules.count) readable and \(last.unreadable) unreadable in the last snapshot, total \(Double(sum) / 1e9) J (\(Double(sum) / 1e9 / window) W)")
print("--- per process")
for (pid, nj) in totals.sorted(by: { $0.value > $1.value }).prefix(10) {
    print(String(format: "%6d  %7.3f W  %5.1f%%  %@", pid, Double(nj) / 1e9 / window, Double(nj) * 100 / Double(max(sum, 1)), name(pid)))
}
print("--- per app: grouped under the responsible process's .app bundle (executables outside a .app are their own entry)")
var byApp: [String: UInt64] = [:]
print("responsibility_get_pid_responsible_for_pid: \(responsible == nil ? "missing" : "found")")
for (pid, nj) in totals {
    let owner = responsible.map { $0(pid) } ?? pid
    byApp[app(name(owner > 0 ? owner : pid)), default: 0] += nj
}
for (path, nj) in byApp.sorted(by: { $0.value > $1.value }).prefix(10) {
    print(String(format: "%7.3f W  %5.1f%%  %@", Double(nj) / 1e9 / window, Double(nj) * 100 / Double(max(sum, 1)), path))
}
let cpu = cpuSeconds() - cpuStart
print(String(format: "sampler CPU: %.4f s over %.1f s wall for %d snapshots = %.4f s per snapshot", cpu, Date().timeIntervalSince(wallStart), samples, cpu / Double(samples)))
