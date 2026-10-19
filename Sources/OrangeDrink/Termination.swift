import AppKit
import OSLog

/// What the log says when the app is asked to quit, so an exit nobody remembers asking for names who asked.
///
/// [LAW:effects-at-boundaries] The sentence is a pure function of what the delegate read from AppKit,
/// so the wording is asserted with no app running.
enum TerminationRequest {
    /// A quit Apple event carries its sender's pid; a `terminate:` from inside the app carries none, and
    /// its call stack says which code asked.
    static func sentence(senderPID: Int32?, senderName: String?, stack: [String]) -> String {
        let origin = senderPID.map { "quit request from pid \($0) (\(senderName ?? "unknown"))" } ?? "quit request from inside the app"
        return "\(origin); stack: \(stack.prefix(12).joined(separator: " <- "))"
    }
}

/// Logs each request to terminate, then lets it proceed: quitting behaves as it always did.
@MainActor final class TerminationLog: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "termination")

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let pid = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0) }.flatMap { $0.localizedName ?? $0.bundleIdentifier }
        Self.log.notice("\(TerminationRequest.sentence(senderPID: pid, senderName: name, stack: Thread.callStackSymbols), privacy: .public)")
        return .terminateNow
    }
}
