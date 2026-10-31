import AppKit
import Darwin
import OSLog

/// What the log says when the app is asked to quit, so an exit nobody remembers asking for names who asked.
///
/// [LAW:types-are-the-program] Where a quit came from is one of three cases, each carrying only what it
/// can know: a quit Apple event and a SIGTERM have a sender; a `terminate:` from inside the app has none,
/// and its call stack says which code asked.
enum TerminationRequest: Equatable {
    /// The sender is nil when the event carries no readable pid; a name needs a pid to have been looked up.
    case quitEvent(sender: Sender?)
    /// The sender is nil when `si_pid` is 0: no process sent it, or the kernel did not say.
    case signal(sender: Sender?)
    case inApp

    struct Sender: Equatable {
        let pid: Int32
        /// Nil once the sender has gone: `/bin/kill` and `pkill` have exited by the time their signal is read,
        /// `killall` and a shell's builtin have not.
        let name: String?

        static func lookedUp(_ pid: Int32?) -> Sender? {
            pid.flatMap { $0 > 0 ? Sender(pid: $0, name: processName($0)) : nil }
        }

        /// Any process's name, a command-line sender's included: `NSRunningApplication` knows only apps.
        private static func processName(_ pid: Int32) -> String? {
            var name = [UInt8](repeating: 0, count: 256)
            let length = Int(proc_name(pid, &name, UInt32(name.count)))
            return length > 0 ? String(decoding: name.prefix(length), as: UTF8.self) : nil
        }
    }

    /// The frames kept: past the delegate's own and AppKit's terminate internals, to the code that asked.
    static let stackDepth = 30

    /// [LAW:effects-at-boundaries] A pure function of what the delegate read from AppKit, so the wording
    /// is asserted with no app running.
    ///
    /// One log line for the origin and one per stack frame: the unified log cuts a message at about a
    /// kilobyte, and a whole stack in one message loses the frames that name the code that asked.
    func lines(stack: [String]) -> [String] {
        let origin: String
        switch self {
        case .quitEvent(let sender): origin = Self.origin("quit Apple event", sender)
        case .signal(let sender): origin = Self.origin("SIGTERM", sender)
        case .inApp: origin = "quit request from inside the app"
        }
        let frames = stack.dropFirst().prefix(Self.stackDepth).map { "  " + $0.split(separator: " ").joined(separator: " ") }
        return [origin] + frames
    }

    private static func origin(_ request: String, _ sender: Sender?) -> String {
        sender.map { "\(request) from pid \($0.pid) (\($0.name ?? "unknown"))" } ?? "\(request) with no readable sender pid"
    }

    /// The request being handled, as the current Apple event says: only a quit event names a sender,
    /// so any other event in flight is not blamed for a quit that began inside the app.
    static func current(event: NSAppleEventDescriptor?) -> TerminationRequest {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return .inApp }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return .quitEvent(sender: Sender.lookedUp(pid))
    }
}

/// The quits on disk. The unified log drops `.notice` lines in about half a day, so a quit noticed the next
/// morning has left no evidence there; this file is for that reader, by `cat` or `grep`.
struct QuitRecords {
    let url: URL
    /// Which copy quit: a Debug build, the installed app, and the test host all write this one file.
    let build: String

    static var standard: QuitRecords {
        QuitRecords(url: URL.libraryDirectory.appending(components: "Logs", IOKitBattery.logSubsystem, "quits.log"),
                    build: "\(PanelAction.versionText(of: .main)) \(Bundle.main.bundlePath)")
    }

    /// One `write` on an `O_APPEND` file, so two copies quitting together cannot interleave their records.
    func append(_ lines: [String], at date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let header = "\(date.ISO8601Format()) pid \(getpid()) \(build)"
        try FileHandle(fileDescriptor: file, closeOnDealloc: true).write(contentsOf: Data((([header] + lines).joined(separator: "\n") + "\n").utf8))
    }
}

/// Logs each request to terminate, then lets it proceed: quitting behaves as it always did.
///
/// It ends the app on SIGTERM the way a menu Quit does. `kill`, launchd, and `Process.terminate()` send it,
/// and its default action would end the process before anything ran. Routed to `terminate:` instead, the
/// app's normal end runs, this record names the sender, and `exit()` releases the helper's record
/// (HelperRegistration). A crash or SIGKILL still skips all of that.
@MainActor final class TerminationLog: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "termination")

    private let records: QuitRecords
    private let signal: Int32
    private let terminate: @MainActor () -> Void
    private var signals: (any DispatchSourceRead)?
    /// The SIGTERM being served. `terminate:` hands the delegate no reason, and it reaches
    /// `applicationShouldTerminate` synchronously, so this is set directly before that call.
    private var signalled: TerminationRequest?

    init(records: QuitRecords, signal: Int32, terminate: @escaping @MainActor () -> Void) {
        self.records = records
        self.signal = signal
        self.terminate = terminate
    }

    override convenience init() {
        self.init(records: .standard, signal: SIGTERM, terminate: { NSApplication.shared.terminate(nil) })
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        signals = SignalWatch.start(signal) { [unowned self] pid in
            signalled = .signal(sender: TerminationRequest.Sender.lookedUp(pid))
            terminate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record(signalled ?? TerminationRequest.current(event: NSAppleEventManager.shared().currentAppleEvent), stack: Thread.callStackSymbols, at: Date())
        return .terminateNow
    }

    /// [LAW:one-source-of-truth] One reading of the request, for two views of it: the unified log places the
    /// quit among everything else `log show` prints, and the file keeps it.
    func record(_ request: TerminationRequest, stack: [String], at date: Date) {
        let lines = request.lines(stack: stack)
        for line in lines { Self.log.notice("\(line, privacy: .public)") }
        // [LAW:no-silent-failure] Said where it can still be read, and the quit goes on: a record is never why
        // the app cannot end.
        do { try records.append(lines, at: date) } catch {
            Self.log.error("no quit record at \(self.records.url.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}

/// Says which process sent a signal. kqueue's EVFILT_SIGNAL, and so a DispatchSource signal source, says only
/// that one came; `si_pid` reaches a `sigaction` handler and nothing else.
///
/// [LAW:no-ambient-temporal-coupling] The self-pipe trick: the handler writes `si_pid` down a pipe and a read
/// source on the main queue takes it, so the signal and its sender arrive as one value. EVFILT_SIGNAL fires when
/// the signal is generated, before any handler runs, so a variable the handler sets could be read unset.
enum SignalWatch {
    /// [LAW:no-shared-mutable-globals] Each signal's pipe, indexed by signal number, because a C handler
    /// captures nothing and a disposition is per process. `start` is the only writer, and fills a signal's
    /// entry before installing its handler, which only reads.
    private nonisolated(unsafe) static let writeEnds = UnsafeMutablePointer<Int32>.allocate(capacity: Int(NSIG))

    /// Takes over `number` from its default action. The caller keeps the source alive for as long as it watches.
    static func start(_ number: Int32, sent: @escaping @MainActor (Int32) -> Void) -> any DispatchSourceRead {
        var ends: [Int32] = [0, 0]
        precondition(pipe(&ends) == 0, "no pipe for signal \(number): errno \(errno)")
        let readEnd = ends[0]
        // Close-on-exec, so no process the app runs holds the pipe. Non-blocking, so a full pipe drops a repeat
        // of a signal already waiting there instead of stopping a thread inside the handler.
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(ends[1], F_SETFL, O_NONBLOCK)
        writeEnds[Int(number)] = ends[1]
        let source = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: .main)
        source.setEventHandler {
            var pid: Int32 = 0
            // Under PIPE_BUF, so the handler's write and this read are each all or nothing.
            _ = read(readEnd, &pid, MemoryLayout<Int32>.size)
            MainActor.assumeIsolated { sent(pid) }
        }
        source.resume()
        // A handler, not SIG_IGN: an ignored signal stays ignored in every process the app runs, while a caught
        // one is reset to the default in each. It stays async-signal-safe: a load, a `write`, and errno put back
        // for the thread it interrupted.
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = { number, info, _ in
            let interrupted = errno
            var pid = info!.pointee.si_pid
            _ = write(SignalWatch.writeEnds[Int(number)], &pid, MemoryLayout<Int32>.size)
            errno = interrupted
        }
        action.sa_flags = SA_SIGINFO | SA_RESTART
        precondition(sigaction(number, &action, nil) == 0, "no handler for signal \(number): errno \(errno)")
        return source
    }
}
