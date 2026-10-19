// Launches the app, lets it settle, and measures its CPU over a steady-state window against
// PROJECT.md's 0.1% bar. Run by `make cpu-check`; usage: cpu-check <path to the app executable>.
// Exits 0 under the bar, 1 over it, and 2 when no measurement could be made.
import Foundation

let settleSeconds = 10.0
let windowSeconds = 60.0
let budgetPercent = 0.1

enum CPUCheckError: Error, CustomStringConvertible {
    case usage
    case pmsetNamedNoSource(String)
    case appExited(status: Int32)
    case rusage(errno: Int32)

    var description: String {
        switch self {
        case .usage: "usage: cpu-check <path to the app executable>"
        case .pmsetNamedNoSource(let output): "pmset -g batt named no power source:\n\(output)"
        case .appExited(let status): "the app exited with status \(status) before the window ended"
        case .rusage(let errno): "proc_pid_rusage failed: \(String(cString: strerror(errno)))"
        }
    }
}

/// User plus system time the kernel has charged to the app, from launch. proc_pid_rusage
/// reports it in Mach ticks, which the timebase turns into nanoseconds.
///
/// [LAW:single-enforcer] The one place that tells a running app from one that has exited, so
/// either sample reports an exit by the app's status and never by a failed kernel call.
func cpuTime(of app: Process) throws -> Duration {
    guard app.isRunning else { throw CPUCheckError.appExited(status: app.terminationStatus) }
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(app.processIdentifier, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { throw CPUCheckError.rusage(errno: errno) }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = Int64(info.ri_user_time + info.ri_system_time)
    return .nanoseconds(ticks * Int64(timebase.numer) / Int64(timebase.denom))
}

/// "AC Power" or "Battery Power", as pmset names the source the Mac is drawing from.
func powerSource() throws -> String {
    let pmset = Process()
    pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmset.arguments = ["-g", "batt"]
    let pipe = Pipe()
    pmset.standardOutput = pipe
    try pmset.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    pmset.waitUntilExit()
    guard let match = output.firstMatch(of: #/Now drawing from '([^']+)'/#) else {
        throw CPUCheckError.pmsetNamedNoSource(output)
    }
    return String(match.1)
}

struct Measurement {
    let cpu: Duration
    let elapsed: Duration
    /// The source over the window, or both when it changed under the measurement.
    let source: String
}

/// [LAW:effects-at-boundaries] The one function that owns the app process: however the
/// measurement ends, the app ends with it, so a failed run leaves nothing in the menu bar.
func measure(executable: String) throws -> Measurement {
    let app = Process()
    app.executableURL = URL(fileURLWithPath: executable)
    try app.run()
    defer {
        app.terminate()
        app.waitUntilExit()
    }
    Thread.sleep(forTimeInterval: settleSeconds)
    let sourceBefore = try powerSource()
    let cpuBefore = try cpuTime(of: app)
    let windowStart = ContinuousClock.now
    Thread.sleep(forTimeInterval: windowSeconds)
    let cpu = try cpuTime(of: app) - cpuBefore
    let elapsed = ContinuousClock.now - windowStart
    let sourceAfter = try powerSource()
    let source = sourceBefore == sourceAfter ? sourceBefore : "\(sourceBefore), then \(sourceAfter)"
    return Measurement(cpu: cpu, elapsed: elapsed, source: source)
}

do {
    guard CommandLine.arguments.count == 2 else { throw CPUCheckError.usage }
    let measured = try measure(executable: CommandLine.arguments[1])
    let percent = measured.cpu / measured.elapsed * 100
    print("cpu: \(String(format: "%.3f", percent))% (\(measured.cpu) over \(measured.elapsed)) on \(measured.source); budget \(budgetPercent)%")
    exit(percent <= budgetPercent ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("cpu-check: \(error)\n".utf8))
    exit(2)
}
