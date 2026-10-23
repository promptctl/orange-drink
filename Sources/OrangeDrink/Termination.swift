import AppKit
import Darwin
import OSLog

/// What the log says when the app is asked to quit, so an exit nobody remembers asking for names who asked.
///
/// [LAW:types-are-the-program] Where a quit came from is one of two cases, each carrying only what it can
/// know: a quit Apple event has a sender; a `terminate:` from inside the app has none, and its call
/// stack says which code asked.
enum TerminationRequest: Equatable {
    /// The sender is nil when the event carries no readable pid; a name needs a pid to have been looked up.
    case quitEvent(sender: Sender?)
    case inApp

    struct Sender: Equatable {
        let pid: Int32
        let name: String?
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
        case .quitEvent(let sender?): origin = "quit Apple event from pid \(sender.pid) (\(sender.name ?? "unknown"))"
        case .quitEvent(nil): origin = "quit Apple event with no readable sender pid"
        case .inApp: origin = "quit request from inside the app"
        }
        let frames = stack.dropFirst().prefix(Self.stackDepth).map { "  " + $0.split(separator: " ").joined(separator: " ") }
        return [origin] + frames
    }

    /// The request being handled, as the current Apple event says: only a quit event names a sender,
    /// so any other event in flight is not blamed for a quit that began inside the app.
    static func current(event: NSAppleEventDescriptor?) -> TerminationRequest {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return .inApp }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return .quitEvent(sender: pid.flatMap { $0 > 0 ? Sender(pid: $0, name: processName($0)) : nil })
    }

    /// Any process's name, a command-line sender's included: `NSRunningApplication` knows only apps.
    private static func processName(_ pid: Int32) -> String? {
        var name = [UInt8](repeating: 0, count: 256)
        let length = Int(proc_name(pid, &name, UInt32(name.count)))
        return length > 0 ? String(decoding: name.prefix(length), as: UTF8.self) : nil
    }
}

/// Logs each request to terminate, then lets it proceed: quitting behaves as it always did.
@MainActor final class TerminationLog: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "termination")

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let request = TerminationRequest.current(event: NSAppleEventManager.shared().currentAppleEvent)
        for line in request.lines(stack: Thread.callStackSymbols) { Self.log.notice("\(line, privacy: .public)") }
        return .terminateNow
    }
}

/// Ends the app on SIGTERM the way a menu Quit does. `kill`, launchd, and `Process.terminate()` send it,
/// and its default action would end the process before anything ran. Routed to `terminate:` instead, the
/// app's normal end runs, TerminationLog's stack names this handler, and `exit()` releases the helper's
/// record (HelperRegistration). A crash or SIGKILL still skips all of that.
@MainActor enum SignalTermination {
    private static var source: DispatchSourceSignal?

    /// [LAW:no-ambient-temporal-coupling] Called once, from the app's launch. The default action is turned
    /// off only once the source that replaces it exists.
    static func start() {
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)
        source = sigterm
    }
}
