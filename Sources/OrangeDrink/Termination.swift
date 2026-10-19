import AppKit
import Darwin
import OSLog

/// What the log says when the app is asked to quit, so an exit nobody remembers asking for names who asked.
///
/// [LAW:types-are-the-program] Where a quit came from is one of two cases, each carrying only what it can
/// know: a quit Apple event has a sender; a `terminate:` from inside the app has none, and its call
/// stack says which code asked.
enum TerminationRequest: Equatable {
    case quitEvent(senderPID: Int32?, senderName: String?)
    case inApp

    /// The frames kept: past the delegate's own and AppKit's terminate internals, to the code that asked.
    static let stackDepth = 30

    /// [LAW:effects-at-boundaries] A pure function of what the delegate read from AppKit, so the wording
    /// is asserted with no app running.
    func sentence(stack: [String]) -> String {
        let origin: String
        switch self {
        case .quitEvent(let pid?, let name): origin = "quit Apple event from pid \(pid) (\(name ?? "unknown"))"
        case .quitEvent(nil, _): origin = "quit Apple event with no readable sender pid"
        case .inApp: origin = "quit request from inside the app"
        }
        return "\(origin); stack: \(stack.dropFirst().prefix(Self.stackDepth).joined(separator: " <- "))"
    }

    /// The request being handled, as the current Apple event says: only a quit event names a sender,
    /// so any other event in flight is not blamed for a quit that began inside the app.
    static func current(event: NSAppleEventDescriptor?) -> TerminationRequest {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return .inApp }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return .quitEvent(senderPID: pid, senderName: pid.flatMap(processName))
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
        Self.log.notice("\(request.sentence(stack: Thread.callStackSymbols), privacy: .public)")
        return .terminateNow
    }
}
