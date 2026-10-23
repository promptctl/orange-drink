import Foundation
import os
import Security

// The privileged helper launchd starts from inside the app (BundleProgram), so Bundle.main is the app.
let log = Logger(subsystem: "dev.orangedrink.helperspike", category: "helper")

func fail(_ message: String) -> Never {
    log.error("\(message, privacy: .public)")
    fatalError(message)
}

/// [LAW:one-source-of-truth] The peer requirement is the app's own designated requirement, read off
/// its signature at launch: `cdhash H"…"` for an ad-hoc app, its identifier and team for a Developer ID one.
/// Either way it pins whatever bundle is at this path when the helper launches: re-signing the app, ad hoc
/// or with any team, rewrites the requirement the root helper enforces. Pinning a signer would take a
/// requirement built from the helper's own signature, which this spike does not try.
func designatedRequirement(of app: URL) -> String {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    var text: CFString?
    var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
    if status == errSecSuccess, let code { status = SecCodeCopyDesignatedRequirement(code, [], &requirement) }
    if status == errSecSuccess, let requirement { status = SecRequirementCopyString(requirement, [], &text) }
    guard status == errSecSuccess, let text else { fail("no designated requirement for \(app.path): OSStatus \(status)") }
    return text as String
}

func selfSigning() -> String {
    var me: SecCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return "unreadable" }
    return signing(of: unsafeBitCast(me, to: SecStaticCode.self))
}

func signing(ofPid pid: pid_t) -> String {
    var guest: SecCode?
    let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &guest)
    guard status == errSecSuccess, let guest else { return "unreadable (OSStatus \(status))" }
    return signing(of: unsafeBitCast(guest, to: SecStaticCode.self))
}

let app = Bundle.main.bundleURL
let requirement = designatedRequirement(of: app)
let service: String
do { service = try LaunchDaemon(in: Bundle.main).machService } catch { fail("\(error)") }
let me = "helper pid=\(getpid()) euid=\(geteuid()) \(selfSigning())"

final class Session: NSObject, HelperProtocol {
    let peer: pid_t
    init(peer: pid_t) { self.peer = peer }

    func whoAmI(reply: @escaping @Sendable (String) -> Void) {
        reply("""
            \(me)
            helper app: \(app.path)
            helper enforces: \(requirement)
            caller pid=\(peer) \(signing(ofPid: peer))
            """)
    }
}

/// The helper exits at the first check, `idle` after its launch or after any connection closes, that
/// finds no accepted connection open, and launchd starts it again for the next caller. So a call is answered by the helper and requirement
/// now on disk, not by one started before a rebuild, including one launched only for a refused
/// caller, which never reaches the delegate. A connection still being served keeps it alive.
final class Lifetime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lifetime")
    private let idle: DispatchTimeInterval = .seconds(2)
    private var open = 0  // read and written only on `queue`

    func opened() { queue.async { self.open += 1 } }
    func closed() { queue.async { self.open -= 1; self.exitWhenIdle() } }
    func launched() { queue.async { self.exitWhenIdle() } }

    private func exitWhenIdle() {
        queue.asyncAfter(deadline: .now() + idle) { if self.open == 0 { exit(0) } }
    }
}

let lifetime = Lifetime()

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.info("accepted pid \(connection.processIdentifier) \(signing(ofPid: connection.processIdentifier), privacy: .public)")
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = Session(peer: connection.processIdentifier)
        lifetime.opened()
        connection.invalidationHandler = { lifetime.closed() }
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: service)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
lifetime.launched()
log.info("\(me, privacy: .public) app \(app.path, privacy: .public) service \(service, privacy: .public) enforces \(requirement, privacy: .public)")
dispatchMain()
