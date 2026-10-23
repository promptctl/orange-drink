import Darwin
import Foundation
import os
import Security

// The privileged helper: a launchd daemon, started on demand for its Mach service, that serves only its app.
// It runs until launchd stops it, which the app's unregister does at launch and at exit
// (HelperRegistration), so a helper that a rebuild replaced on disk never outlives the app's next launch.

let signer: Signer
do { signer = try Signer(signingInformation: SigningInformation.ofSelf()) } catch {
    // [LAW:no-silent-failure] Without a team there is no requirement to enforce, so the helper serves no one.
    Logger(subsystem: "OrangeDrinkHelper", category: "helper").fault("helper exits: \(error.description, privacy: .public)")
    exit(EX_CONFIG)
}
let log = Logger(subsystem: signer.app, category: "helper")
// The path the kernel ran. Bundle.main would name the enclosing app, since the helper lives in its Contents/MacOS.
let executable = executablePath(of: getpid()) ?? "unknown (proc_pidpath: errno \(errno))"

final class Session: NSObject, PrivilegedHelper {
    let peer: pid_t
    init(peer: pid_t) { self.peer = peer }

    func identity(reply: @escaping @Sendable (String, UInt32) -> Void) {
        log.notice("identity for pid \(self.peer)")
        reply(executable, geteuid())
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
