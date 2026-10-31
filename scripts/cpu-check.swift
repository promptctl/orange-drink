// Launches the app, lets it settle, and measures its CPU over a steady-state window against
// PROJECT.md's 0.1% bar. Run by `make cpu-check`; usage: cpu-check <path to the app executable>.
// Exits 0 under the bar, 1 over it, and 2 when no measurement could be made.
import Foundation
import os

let settleSeconds = 10.0
let windowSeconds = 60.0
let budgetPercent = 0.1

enum CPUCheckError: Error, CustomStringConvertible {
    case usage
    case pmset(status: Int32, output: String)
    case appExited(Process.TerminationReason, status: Int32)
    case rusage(errno: Int32)
    case interrupted(signal: Int32)

    var description: String {
        switch self {
        case .usage: "usage: cpu-check <path to the app executable>"
        case .pmset(let status, let output): "pmset -g batt exited \(status) and named no power source:\n\(output)"
        case .appExited(.exit, let status): "the app exited with status \(status) before the window ended"
        case .appExited(_, let signal): "the app was killed by signal \(signal) before the window ended"
        case .rusage(let errno): "proc_pid_rusage failed: \(String(cString: strerror(errno)))"
        case .interrupted(let signal): "interrupted by signal \(signal)"
        }
    }
}

/// The signal that would have ended the script, held for the sleep it cuts short.
///
/// [LAW:no-ambient-temporal-coupling] Process starts the app in its own process group, out of
/// Ctrl-C's reach, so a signal ends the measurement as an error and `measure`'s defer ends the
/// app with it, on the one path every ending takes.
let interruption = DispatchSemaphore(value: 0)
let interruptedBy = OSAllocatedUnfairLock<Int32?>(initialState: nil)
let signalSources = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number)
    source.setEventHandler {
        interruptedBy.withLock { $0 = number }
        interruption.signal()
    }
    source.resume()
    return source
}

/// Throws the signal that has arrived, if one has.
func checkInterruption() throws {
    if let number = interruptedBy.withLock({ $0 }) { throw CPUCheckError.interrupted(signal: number) }
}

/// Sleeps for the seconds, or throws the signal that cut the sleep short.
func sleep(seconds: Double) throws {
    _ = interruption.wait(timeout: .now() + seconds)
    try checkInterruption()
}

/// User plus system time the kernel has charged to the app, from launch. proc_pid_rusage
/// reports it in Mach ticks, which the timebase turns into nanoseconds.
///
/// [LAW:one-source-of-truth] The kernel is the one judge of whether the app is still there:
/// Process.isRunning trails the exit, so the sample itself tells, by a gone pid or by the
/// exit time the kernel stamps on one not yet reaped, and the exit is reported by its reason
/// and status once Foundation has collected them.
func cpuTime(of app: Process) throws -> Duration {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(app.processIdentifier, RUSAGE_INFO_V4, $0) }
    }
    if status != 0, errno != ESRCH { throw CPUCheckError.rusage(errno: errno) }
    guard status == 0, info.ri_proc_exit_abstime == 0 else {
        app.waitUntilExit()
        throw CPUCheckError.appExited(app.terminationReason, status: app.terminationStatus)
    }
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
    guard pmset.terminationStatus == 0, let match = output.firstMatch(of: #/Now drawing from '([^']+)'/#) else {
        throw CPUCheckError.pmset(status: pmset.terminationStatus, output: output)
    }
    return String(match.1)
}

/// The General screen's battery notification switch, on, as a default in the argument domain: nothing is written to this
/// Mac's preferences, and the steady state measured is the one with that feature's wake registered.
let dismissingSystemNotifications = ["-systemNotifications",
                                     "<" + Data(#"{"dismissBatteryNotifications":true}"#.utf8).map { String(format: "%02x", $0) }.joined() + ">"]

struct MeasuredWindow {
    let cpu: Duration
    let elapsed: Duration
    /// The source over the window, or both when it changed under the measurement.
    let source: String
}

/// [LAW:effects-at-boundaries] The one function that owns the app process: however the
/// measurement ends, the app ends with it, so a failed run leaves nothing in the menu bar.
func measure(executable: String) throws -> MeasuredWindow {
    let app = Process()
    app.executableURL = URL(fileURLWithPath: executable)
    app.arguments = dismissingSystemNotifications
    try app.run()
    defer {
        app.terminate()
        app.waitUntilExit()
    }
    try sleep(seconds: settleSeconds)
    let sourceBefore = try powerSource()
    let cpuBefore = try cpuTime(of: app)
    let windowStart = ContinuousClock.now
    try sleep(seconds: windowSeconds)
    let cpu = try cpuTime(of: app) - cpuBefore
    let elapsed = ContinuousClock.now - windowStart
    let sourceAfter = try powerSource()
    try checkInterruption()
    let source = sourceBefore == sourceAfter ? sourceBefore : "\(sourceBefore), then \(sourceAfter)"
    return MeasuredWindow(cpu: cpu, elapsed: elapsed, source: source)
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
