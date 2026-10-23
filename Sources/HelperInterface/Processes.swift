import Darwin

/// The process table could not be read.
struct ProcessTableUnreadable: Error, Equatable {
    let errno: Int32
}

/// [LAW:one-source-of-truth] The kernel's process table, any user's: the one reader of pids and their
/// executables, for the app's energy history and for the helper's record.
enum Processes {
    /// Every pid running now.
    static func all() throws(ProcessTableUnreadable) -> [pid_t] {
        // A null buffer asks how many pids there are now; room is left for processes started since.
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { throw ProcessTableUnreadable(errno: errno) }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        // The return value is a count of pids, not of bytes.
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { throw ProcessTableUnreadable(errno: errno) }
        return Array(pids.prefix(Int(count)))
    }

    /// The path the kernel ran for a process, or nil once it has gone or this user may not read it.
    static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        return length > 0 ? String(decoding: path.prefix(Int(length)), as: UTF8.self) : nil
    }
}
