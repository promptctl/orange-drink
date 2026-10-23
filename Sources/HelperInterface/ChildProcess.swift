import Foundation
import os

/// A tool run to its end and read back, by the helper (pmset) and by the live tests. [LAW:one-source-of-truth]
/// The one runner: each run is killed at its deadline, so a stuck tool is a failure instead of a hang.
struct ChildProcess {
    let status: Int32
    let output: Data
    let errors: String

    var text: String { String(decoding: output, as: UTF8.self) }
    /// Both streams, for a failure message.
    var transcript: String { text + errors }

    struct TimedOut: Error, CustomStringConvertible {
        let executable: String
        let seconds: TimeInterval
        var description: String { "\(executable) was still running at its \(seconds.formatted()) s deadline and was killed" }
    }

    static func run(_ executable: String, _ arguments: [String], deadline seconds: TimeInterval = 30) throws -> ChildProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let killed = OSAllocatedUnfairLock(initialState: false)
        let killer = DispatchWorkItem {
            killed.withLock { $0 = true }
            // SIGKILL, which no tool can catch, so a run past its deadline always ends.
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: killer)
        // stderr drains on its own thread, so a tool that fills one pipe never blocks on the other.
        let errors = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchGroup()
        let errorHandle = err.fileHandleForReading
        DispatchQueue.global().async(group: drained) {
            let data = errorHandle.readDataToEndOfFile()
            errors.withLock { $0 = data }
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        killer.cancel()
        // Timed out only when the kill ended it: a tool that exited just before the kill landed finished in time.
        if killed.withLock({ $0 }), process.terminationReason == .uncaughtSignal { throw TimedOut(executable: executable, seconds: seconds) }
        return ChildProcess(status: process.terminationStatus, output: output, errors: String(decoding: errors.withLock { $0 }, as: UTF8.self))
    }
}
