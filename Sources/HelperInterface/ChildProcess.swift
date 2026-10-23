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

    struct NotStarted: Error, CustomStringConvertible {
        let executable: String
        let code: Int32
        var description: String { "\(executable) could not start: \(String(cString: strerror(code)))" }
    }

    /// Where a run is, as the deadline's kill and the reap both see it.
    private enum Stage { case running, killed, ended }

    static func run(_ executable: String, _ arguments: [String], deadline seconds: TimeInterval = 30) throws -> ChildProcess {
        let out = Pipe(), err = Pipe()
        let pid = try spawn(executable, arguments, output: out, errors: err)
        // [LAW:no-ambient-temporal-coupling] The kill and the reap take turns under one lock, and the child is reaped
        // only once it is marked ended, so the kill never reaches a pid the system has given to another process.
        let stage = OSAllocatedUnfairLock(initialState: Stage.running)
        let killer = DispatchWorkItem {
            // SIGKILL, which no tool can catch, so a run past its deadline always ends.
            stage.withLock { if $0 == .running { kill(pid, SIGKILL); $0 = .killed } }
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
        // Waits for the exit without reaping it, so the pid stays this child's until it is marked ended.
        var exited = siginfo_t()
        while waitid(P_PID, id_t(pid), &exited, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        let wasKilled = stage.withLock { stage in
            defer { stage = .ended }
            return stage == .killed
        }
        killer.cancel()
        var wait: Int32 = 0
        while waitpid(pid, &wait, 0) == -1, errno == EINTR {}
        // The low 7 bits are the signal that ended it, if one did; otherwise the exit status is the next byte.
        let signal = wait & 0x7f
        // Timed out only when the kill ended it: a tool that exited just before the kill landed finished in time.
        if wasKilled, signal == SIGKILL { throw TimedOut(executable: executable, seconds: seconds) }
        return ChildProcess(status: signal == 0 ? (wait >> 8) & 0xff : signal, output: output,
                            errors: String(decoding: errors.withLock { $0 }, as: UTF8.self))
    }

    /// Starts the tool with stdin empty and stdout and stderr into the pipes, and no other descriptor of this
    /// process, so the pipes reach their end when the tool does.
    private static func spawn(_ executable: String, _ arguments: [String], output: Pipe, errors: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        guard code == 0 else { throw NotStarted(executable: executable, code: code) }
        return pid
    }
}
