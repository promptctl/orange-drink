import Foundation
import os

/// A tool the live tests run and read back. [LAW:one-source-of-truth] The one runner: each run is killed at
/// its deadline, so a stuck tool fails its test instead of hanging the whole run.
struct ChildProcess {
    let status: Int32
    let output: Data
    let errors: String

    var text: String { String(decoding: output, as: UTF8.self) }
    /// Both streams, for a failure message.
    var transcript: String { text + errors }

    struct TimedOut: Error, CustomStringConvertible {
        let executable: String
        let seconds: Int
        var description: String { "\(executable) was still running at its \(seconds) s deadline and was killed" }
    }

    static func run(_ executable: String, _ arguments: [String], deadline seconds: Int = 30) throws -> ChildProcess {
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
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: killer)
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
        if killed.withLock({ $0 }) { throw TimedOut(executable: executable, seconds: seconds) }
        return ChildProcess(status: process.terminationStatus, output: output, errors: String(decoding: errors.withLock { $0 }, as: UTF8.self))
    }
}
