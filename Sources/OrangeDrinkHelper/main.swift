import Darwin
import Foundation
import os
import Security

// The privileged helper: a launchd daemon, started on demand for its Mach service, that serves only its app.
// It runs until launchd stops it, which the app's unregister does (HelperRegistration), or until its own
// file changes on disk.

let signer: Signer
do { signer = try Signer(signingInformation: SigningInformation.ofSelf()) } catch {
    // [LAW:no-silent-failure] Without a team there is no requirement to enforce, so the helper serves no one.
    Logger(subsystem: "OrangeDrinkHelper", category: "helper").fault("helper exits: \(error.description, privacy: .public)")
    exit(EX_CONFIG)
}
let log = Logger(subsystem: signer.app, category: "helper")
// The path the kernel ran. Bundle.main would name the enclosing app, since the helper lives in its Contents/MacOS.
let executable: String
if let path = Processes.executablePath(of: getpid()) { executable = path } else {
    log.fault("helper exits: proc_pidpath of itself failed, errno \(errno)")
    exit(EX_OSERR)
}

// [LAW:one-source-of-truth] The code that serves is the file on disk. A rebuild that rewrites, replaces or
// removes it, or the unmount of its volume, ends this process, and launchd runs the new file at the next
// call, even while a running copy of the app still holds the record and so never unregisters.
let binary = open(executable, O_EVTONLY)
if binary < 0 {
    log.fault("helper exits: cannot watch \(executable, privacy: .public), errno \(errno)")
    exit(EX_OSERR)
}
let replaced = DispatchSource.makeFileSystemObjectSource(fileDescriptor: binary, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
replaced.setEventHandler {
    log.notice("helper exits: \(executable, privacy: .public) changed on disk (\(replaced.data.rawValue))")
    exit(0)
}
replaced.resume()

final class Session: NSObject, PrivilegedHelper {
    let peer: pid_t
    init(peer: pid_t) { self.peer = peer }

    func identity(reply: @escaping @Sendable (String, UInt32) -> Void) {
        log.notice("identity for pid \(self.peer)")
        reply(executable, geteuid())
    }

    func setLowPowerMode(_ on: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let outcome = Result { () throws(HelperFailure) in try LowPowerModeWrite.perform(on, pmset: pmset) }
        log.notice("\(LowPowerModeWrite.line(on, peer: self.peer, outcome), privacy: .public)")
        reply(outcome.failure?.description)
    }
}

/// Runs /usr/bin/pmset to its end: its output, or a failure with its exit status and what it printed.
func pmset(_ arguments: [String]) throws(HelperFailure) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch { throw HelperFailure("pmset \(arguments.joined(separator: " ")) did not start: \(error)") }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw HelperFailure("pmset \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(text)") }
    return text
}

extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    /// [LAW:single-enforcer] Every connection that reaches here has met the listener's requirement.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.notice("accepted pid \(connection.processIdentifier)")
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelper.self)
        connection.exportedObject = Session(peer: connection.processIdentifier)
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: signer.service)
// [LAW:single-enforcer] The one check of who may call: libxpc drops any other peer before the delegate
// sees it, and logs "Dropping check-in message due to code signing requirement" in this process.
listener.setConnectionCodeSigningRequirement(signer.callerRequirement)
listener.delegate = delegate
listener.resume()
log.notice("helper pid \(getpid()) euid \(geteuid()) at \(executable, privacy: .public) serves \(signer.service, privacy: .public) to: \(signer.callerRequirement, privacy: .public)")
dispatchMain()
