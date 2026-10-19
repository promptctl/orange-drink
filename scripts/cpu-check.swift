// Launches the app, lets it settle, and measures its CPU over a steady-state window against
// PROJECT.md's 0.1% bar. Run by `make cpu-check`; usage: cpu-check <path to the app executable>.
import Darwin
import Foundation

let settleSeconds = 10.0
let windowSeconds = 60.0
let budgetPercent = 0.1

/// User plus system time the kernel has charged to the process, from launch. proc_pid_rusage
/// reports it in Mach ticks, which the timebase turns into nanoseconds.
func cpuTime(of pid: pid_t) -> Duration {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    precondition(status == 0, "proc_pid_rusage(\(pid)) failed with \(status)")
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

enum CPUCheckError: Error {
    case usage
    case pmsetNamedNoSource(String)
    case appExited(status: Int32, after: Duration)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: cpu-check <path to the app executable>\n".utf8))
    exit(2)
}
let app = Process()
app.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
try app.run()
let launched = ContinuousClock.now
Thread.sleep(forTimeInterval: settleSeconds)
let sourceBefore = try powerSource()
let cpuBefore = cpuTime(of: app.processIdentifier)
let windowStart = ContinuousClock.now
Thread.sleep(forTimeInterval: windowSeconds)
guard app.isRunning else { throw CPUCheckError.appExited(status: app.terminationStatus, after: .now - launched) }
let cpu = cpuTime(of: app.processIdentifier) - cpuBefore
let elapsed = ContinuousClock.now - windowStart
let sourceAfter = try powerSource()
app.terminate()
app.waitUntilExit()

let percent = cpu / elapsed * 100
let source = sourceBefore == sourceAfter ? sourceBefore : "\(sourceBefore), then \(sourceAfter)"
print("cpu: \(String(format: "%.3f", percent))% (\(cpu) over \(elapsed)) on \(source); budget \(budgetPercent)%")
exit(percent <= budgetPercent ? 0 : 1)
