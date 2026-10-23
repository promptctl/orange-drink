import Darwin
import Foundation
import IOKit.ps
import notify
import os
import Security

// The privileged helper: a launchd daemon, started on demand for its Mach service, that serves only its app.
// It runs until launchd stops it, which the app's unregister does (HelperRegistration), or until its own
// file changes on disk. Either way it gives charging back before it exits.

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

/// [LAW:single-enforcer] The one order of the system settings this helper writes: each connection delivers on
/// its own queue, so two connections' writes would run at once; here they run one at a time, in the order
/// they reach the helper.
let writes = DispatchQueue(label: "writes")

/// Which connections hold charging paused, kept on the write queue. The marker is this label's, so each build's
/// helper ends only its own pause.
let charging = Confined(ChargingHolds(open: { () throws(ChargingFailure) in try ChargeInhibitKey() },
                                      marker: PauseMarkerFile(label: signer.service)), on: writes)

/// Runs one charging reconcile on the write queue and logs what it did.
@discardableResult func logged(_ step: (ChargingHolds) -> ChargingHolds.Outcome) -> Result<Void, ChargingFailure> {
    let outcome = charging.sync(step)
    log.notice("\(outcome.line, privacy: .public)")
    return outcome.result
}

/// [LAW:no-ambient-temporal-coupling] Every way the helper ends on purpose comes here, so charging is given back
/// before the process goes: launchd's stop at the app's unregister, and a rebuild of the helper's own file.
func end(_ reason: String) -> Never {
    logged { $0.end("helper exits: \(reason)") }
    exit(0)
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
replaced.setEventHandler { end("\(executable) changed on disk (\(replaced.data.rawValue))") }
replaced.resume()

// launchd stops the helper with SIGTERM. The source is made before the default action is turned off; a handler
// that does nothing, not SIG_IGN, so pmset and every other tool the helper runs gets SIGTERM's default back.
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminated.setEventHandler { end("SIGTERM") }
terminated.resume()
signal(SIGTERM) { _ in }

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

    func pauseCharging(until asked: Date, reply: @escaping @Sendable (Int, String?) -> Void) {
        let holder = ObjectIdentifier(self)
        let answer = ChargingFailure.reply(inTime(asked) { logged { $0.pause(for: holder) } })
        reply(answer.kind, answer.description)
    }

    func resumeCharging(until asked: Date, reply: @escaping @Sendable (Int, String?) -> Void) {
        let holder = ObjectIdentifier(self)
        let answer = ChargingFailure.reply(inTime(asked) { logged { $0.resume(for: holder) } })
        reply(answer.kind, answer.description)
    }

    /// [LAW:single-enforcer] A charging call that waited past its caller's instant is not run: the caller has stopped
    /// waiting and is ending the connection, which lets go of anything it held.
    private func inTime(_ asked: Date, _ work: () -> Result<Void, ChargingFailure>) -> Result<Void, ChargingFailure> {
        let left = min(asked, HelperClient.workEnds()).timeIntervalSinceNow
        guard left > 0 else { return .failure(.failed("not run: the call's deadline passed \((-left).formatted(.number.precision(.fractionLength(1)))) s ago")) }
        return work()
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    /// [LAW:single-enforcer] Every connection that reaches here has met the listener's requirement.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        log.notice("accepted pid \(connection.processIdentifier)")
        let session = Session(peer: connection.processIdentifier)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelper.self)
        connection.exportedObject = session
        // A connection that ends, by the app's quit or crash or its own release, lets go of any pause it held. The
        // handler holds the session, so its identity cannot pass to a newer connection's before this drop runs.
        connection.invalidationHandler = { logged { $0.drop(ObjectIdentifier(session)) } }
        connection.resume()
        return true
    }
}

// A pause a helper of this label left behind when it was killed is ended before any call is served.
logged { $0.check("helper start") }

// [LAW:dataflow-not-control-flow] Every power-source change is a check: a pause the firmware or powerd undid on a
// replug, a wake, or a Charge Limit change is put back while a connection holds it. Delivered on the main queue: a
// closure in this file's top-level code is main-actor isolated, and Swift checks that at run time, so any other
// queue ends the helper at the first change. The check itself takes its turn on the write queue.
var powerChanges: Int32 = 0
let powerStatus = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &powerChanges, .main) { _ in
    logged { $0.check("power source changed") }
}
if powerStatus != NOTIFY_STATUS_OK { log.fault("no power-source notifications: notify_register_dispatch \(powerStatus)") }

let delegate = Listener()
let listener = NSXPCListener(machServiceName: signer.service)
// [LAW:single-enforcer] The one check of who may call: libxpc drops any other peer before the delegate
// sees it, and logs "Dropping check-in message due to code signing requirement" in this process.
listener.setConnectionCodeSigningRequirement(signer.callerRequirement)
listener.delegate = delegate
listener.resume()
log.notice("helper pid \(getpid()) euid \(geteuid()) at \(executable, privacy: .public) serves \(signer.service, privacy: .public) to: \(signer.callerRequirement, privacy: .public)")
dispatchMain()
