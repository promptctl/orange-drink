// Launches the Release app, reads that its helper answers a charge-limit call, kills the app the way a crash would,
// and reads the same at the next launch; then quits it and reads that launchd holds no job. Run by
// `make release-helper-check`; usage: release-helper-check <path to the app>.
// Exits 0 when every reading holds, 1 when one does not, and 2 when no reading could be made.
import Foundation

let answerSeconds = 30.0

enum CheckError: Error, CustomStringConvertible {
    case usage
    case alreadyRunning(String)
    case noLabel(String)
    case tool(String, status: Int32, output: String)
    case didNotStart(String)
    case didNotExit(pid: Int32)
    case noAnswer(pid: Int32, log: String)
    case jobLeft(label: String)

    var description: String {
        switch self {
        case .usage: "usage: release-helper-check <path to the app>"
        case .alreadyRunning(let pids): "this copy is already running (pid \(pids)); quit it first, so the check kills only what it launched"
        case .noLabel(let app): "\(app) embeds no helper plist"
        case .tool(let tool, let status, let output): "\(tool) exited \(status):\n\(output)"
        case .didNotStart(let executable): "\(executable) did not start"
        case .didNotExit(let pid): "pid \(pid) did not exit"
        case .noAnswer(let pid, let log): "pid \(pid): no registration and answered ask within \(Int(answerSeconds)) s. Its log:\n\(log)"
        case .jobLeft(let label): "launchd still holds \(label) after the app quit"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .noAnswer, .jobLeft, .didNotExit: 1
        default: 2
        }
    }
}

/// What a tool printed, and how it ended.
func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

/// The pids running exactly this executable; pgrep exits 1 for none.
func pids(of executable: String) throws -> [Int32] {
    let result = try run("/usr/bin/pgrep", ["-f", "^\(NSRegularExpression.escapedPattern(for: executable))$"])
    guard result.status <= 1 else { throw CheckError.tool("pgrep", status: result.status, output: result.output) }
    return result.output.split(separator: "\n").compactMap { Int32($0) }
}

/// [LAW:no-ambient-temporal-coupling] Each wait is on the fact it needs, polled to a deadline.
func poll<Value>(seconds: Double, _ read: () throws -> Value?) throws -> Value? {
    let end = Date(timeIntervalSinceNow: seconds)
    while true {
        if let value = try read() { return value }
        guard Date() < end else { return nil }
        Thread.sleep(forTimeInterval: 0.25)
    }
}

/// Launches the app as a person would, since background task management only serves a GUI app, and returns its pid.
func launch(_ app: String, executable: String) throws -> Int32 {
    let opened = try run("/usr/bin/open", ["-n", app])
    guard opened.status == 0 else { throw CheckError.tool("open", status: opened.status, output: opened.output) }
    guard let pid = try poll(seconds: 10, { try pids(of: executable).first }) else { throw CheckError.didNotStart(executable) }
    return pid
}

/// The helper and charge-limit lines of one process, so another copy's cannot pass for its.
func log(of pid: Int32) throws -> String {
    let predicate = "processID == \(pid) AND (category == \"helper\" OR category == \"chargeLimit\")"
    let result = try run("/usr/bin/log", ["show", "--last", "2m", "--style", "compact", "--predicate", predicate])
    guard result.status == 0 else { throw CheckError.tool("log show", status: result.status, output: result.output) }
    return result.output
}

/// Requires the registration's line and a charge-limit ask the helper answered.
func expectAnswer(pid: Int32) throws {
    let answered = try poll(seconds: answerSeconds) { () -> Bool? in
        let lines = try log(of: pid).split(separator: "\n")
        let registered = lines.contains { $0.contains("helper registration: registered;") }
        let asked = lines.contains { $0.contains(":chargeLimit]") && $0.hasSuffix(": done") }
        return registered && asked ? true : nil
    }
    guard answered != nil else { throw CheckError.noAnswer(pid: pid, log: try log(of: pid)) }
    print("pid \(pid): registered, and the helper answered a charge-limit ask")
}

func end(pid: Int32, signal: Int32, executable: String) throws {
    kill(pid, signal)
    guard try poll(seconds: 15, { try pids(of: executable).contains(pid) ? nil : true }) != nil else { throw CheckError.didNotExit(pid: pid) }
}

func check() throws {
    guard CommandLine.arguments.count == 2 else { throw CheckError.usage }
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
    let executable = app + "/Contents/MacOS/OrangeDrink"
    let plists = (try? FileManager.default.contentsOfDirectory(atPath: app + "/Contents/Library/LaunchDaemons")) ?? []
    guard let plist = plists.first else { throw CheckError.noLabel(app) }
    let label = String(plist.dropLast(".plist".count))
    let running = try pids(of: executable)
    guard running.isEmpty else { throw CheckError.alreadyRunning(running.map(String.init).joined(separator: ", ")) }

    let first = try launch(app, executable: executable)
    do {
        try expectAnswer(pid: first)
        try end(pid: first, signal: SIGKILL, executable: executable)
        print("pid \(first): killed, as a crash would")
    } catch {
        kill(first, SIGTERM)
        throw error
    }
    let second = try launch(app, executable: executable)
    do {
        try expectAnswer(pid: second)
    } catch {
        kill(second, SIGTERM)
        throw error
    }
    try end(pid: second, signal: SIGTERM, executable: executable)
    // 113 is launchctl's "Could not find service"; any other failure says nothing about the job.
    let printed = try poll(seconds: 15) {
        let result = try run("/bin/launchctl", ["print", "system/\(label)"])
        return result.status == 0 ? nil : result
    }
    guard let printed else { throw CheckError.jobLeft(label: label) }
    guard printed.status == 113 else { throw CheckError.tool("launchctl print", status: printed.status, output: printed.output) }
    print("quit: launchd holds no job for \(label)")
}

do {
    try check()
} catch {
    FileHandle.standardError.write(Data("release-helper-check: \(error)\n".utf8))
    exit((error as? CheckError)?.exitCode ?? 2)
}
