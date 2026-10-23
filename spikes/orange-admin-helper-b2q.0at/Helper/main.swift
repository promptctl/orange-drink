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

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.info("accepted pid \(connection.processIdentifier) \(signing(ofPid: connection.processIdentifier), privacy: .public)")
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = Session(peer: connection.processIdentifier)
        // One call per connection; launchd starts the helper again on the next, so every call is
        // answered by the helper now on disk, never by one started before a rebuild.
        connection.invalidationHandler = { exit(0) }
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: service)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
log.info("\(me, privacy: .public) app \(app.path, privacy: .public) service \(service, privacy: .public) enforces \(requirement, privacy: .public)")
dispatchMain()
