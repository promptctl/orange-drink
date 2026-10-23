import Darwin
import Foundation
import os
import Security

// The privileged helper: a launchd daemon, started on demand for its Mach service, that serves only its app.

/// This process's own signature, read from the running code rather than the file on disk, so a file
/// replaced after launch cannot change what it says. A running SecCode is accepted wherever a
/// SecStaticCode is; Swift keeps the two types apart, hence the cast.
func ownSigner() throws(HelperFailure) -> Signer {
    var me: SecCode?
    let status = SecCodeCopySelf([], &me)
    guard status == errSecSuccess, let me else { throw HelperFailure("SecCodeCopySelf: OSStatus \(status)") }
    return try Signer(code: unsafeBitCast(me, to: SecStaticCode.self))
}

/// The path the kernel ran. Bundle.main would name the enclosing app, since the helper lives in its Contents/MacOS.
func ownExecutable() -> String {
    var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(getpid(), &path, UInt32(path.count))
    return length > 0 ? String(decoding: path.prefix(Int(length)), as: UTF8.self) : "unknown (proc_pidpath: errno \(errno))"
}

let signer: Signer
do { signer = try ownSigner() } catch {
    // [LAW:no-silent-failure] Without a team there is no requirement to enforce, so the helper serves no one.
    Logger(subsystem: "OrangeDrinkHelper", category: "helper").fault("helper exits: \(error.description, privacy: .public)")
    exit(EX_CONFIG)
}
let log = Logger(subsystem: signer.app, category: "helper")
let executable = ownExecutable()

final class Session: NSObject, PrivilegedHelper {
    let peer: pid_t
    init(peer: pid_t) { self.peer = peer }

    func identity(reply: @escaping @Sendable (String, UInt32) -> Void) {
        log.notice("identity for pid \(self.peer)")
        reply(executable, geteuid())
    }
}

/// [LAW:no-ambient-temporal-coupling] The one owner of when the helper exits. It counts open accepted
/// connections on its own queue, and exits when a check made `idle` after launch, or after a connection
/// closes, finds none open; launchd starts the helper again for the next caller. A helper that outlived
/// its last caller would otherwise go on answering after a rebuild replaced it on disk. A refused caller
/// never opens a connection, so a helper launched only for one exits `idle` after launch.
final class Lifetime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lifetime")
    private let idle: DispatchTimeInterval = .seconds(5)
    private var open = 0  // read and written only on `queue`

    func opened() { queue.async { self.open += 1 } }
    func closed() { queue.async { self.open -= 1; self.exitWhenIdle() } }
    func launched() { queue.async { self.exitWhenIdle() } }

    private func exitWhenIdle() {
        queue.asyncAfter(deadline: .now() + idle) {
            guard self.open == 0 else { return }
            log.notice("helper exits: idle")
            exit(0)
        }
    }
}

let lifetime = Lifetime()

final class Listener: NSObject, NSXPCListenerDelegate {
    /// [LAW:single-enforcer] Every connection that reaches here has met the listener's requirement.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.notice("accepted pid \(connection.processIdentifier)")
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelper.self)
        connection.exportedObject = Session(peer: connection.processIdentifier)
        lifetime.opened()
        connection.invalidationHandler = { lifetime.closed() }
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
lifetime.launched()
log.notice("helper pid \(getpid()) euid \(geteuid()) at \(executable, privacy: .public) serves \(signer.service, privacy: .public) to: \(signer.callerRequirement, privacy: .public)")
dispatchMain()
