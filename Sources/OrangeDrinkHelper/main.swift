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

    func setLowPowerMode(_ on: Bool, until asked: Date, reply: @escaping @Sendable (String?) -> Void) {
        // [LAW:single-enforcer] The helper bounds its own work: a caller's instant can shorten one call's
        // budget, never stretch it, so no caller can hold the write queue behind a hung pmset.
        let deadline = min(asked, HelperClient.workEnds())
        let outcome = writes.sync {
            Result { () throws(HelperFailure) in
                try LowPowerModeWrite.perform(on, source: PmsetSource.current()) { arguments throws(HelperFailure) in
                    try LowPowerModeWrite.pmset(arguments, until: deadline)
                }
            }
        }
        log.notice("\(LowPowerModeWrite.line(on, peer: self.peer, outcome), privacy: .public)")
        reply(outcome.failure?.description)
    }
}

/// [LAW:single-enforcer] The one order of the system settings this helper writes: each connection delivers on
/// its own queue, so two connections' writes would run at once; here they run one at a time, in the order
/// they reach the helper.
let writes = DispatchQueue(label: "writes")

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
