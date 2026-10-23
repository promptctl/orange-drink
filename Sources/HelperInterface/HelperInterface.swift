import Foundation
import IOKit.ps
import os
import Security

/// The privileged helper's XPC interface. [LAW:single-enforcer] The helper's listener admits only the app
/// (see `Signer.callerRequirement`), so nothing here checks the caller again.
@objc protocol PrivilegedHelper {
    /// The connection's handshake: the helper's executable path and its effective user id. A reply proves the
    /// helper accepted the caller, runs as root, and is the copy inside the app the caller expected.
    func identity(reply: @escaping @Sendable (String, UInt32) -> Void)

    /// Turns macOS Low Power Mode on or off on the power source the Mac is on now, if that can be done before
    /// `deadline`, the instant the caller's budget leaves for the reply. The reply is nil once pmset has written it, or what
    /// went wrong. [LAW:types-are-the-program] One bit in: the caller names no key, no source, no argument.
    func setLowPowerMode(_ on: Bool, until deadline: Date, reply: @escaping @Sendable (String?) -> Void)

    /// Holds charging paused for as long as this connection lives, or until it resumes. The reply is
    /// `ChargingFailure.reply`'s kind and words.
    func pauseCharging(until deadline: Date, reply: @escaping @Sendable (Int, String?) -> Void)

    /// Lets go of this connection's pause, if it holds one, and brings CHTE to what the remaining holders want.
    func resumeCharging(until deadline: Date, reply: @escaping @Sendable (Int, String?) -> Void)
}

/// The pmset setting that holds Low Power Mode on this Mac. A Mac with an Energy Mode lists `powermode`
/// (0 Automatic, 1 Low Power, 2 High Power); any other lists `lowpowermode` (0 off, 1 on). On both, 1 is
/// Low Power Mode and 0 is not, and each power source keeps its own value.
enum PowerModeKey: String, CaseIterable {
    case powermode, lowpowermode

    /// [LAW:parse-dont-validate] The one key a `pmset -g` listing names, or a failure saying which it found.
    init(listing: String) throws(HelperFailure) {
        let names = Set(listing.split(separator: "\n").compactMap { $0.split(separator: " ").first })
        let listed = Self.allCases.filter { names.contains(Substring($0.rawValue)) }
        guard listed.count == 1, let key = listed.first else {
            throw HelperFailure("pmset -g lists \(listed.isEmpty ? "neither" : "both") of \(Self.allCases.map(\.rawValue).joined(separator: " and "))")
        }
        self = key
    }

    /// pmset's arguments that set Low Power Mode on one power source.
    func arguments(on: Bool, source: PmsetSource) -> [String] { [source.flag, rawValue, on ? "1" : "0"] }
}

/// The power source the Mac runs on, as IOKit names it and as pmset's settings are kept: the switch shows
/// this source's Low Power Mode, so it is the one a flip writes, and every other source keeps its own.
enum PmsetSource: String, CaseIterable {
    case adapter = "AC Power"
    case battery = "Battery Power"
    case ups = "UPS Power"

    /// [LAW:parse-dont-validate] IOKit's providing power source type, or a failure naming it.
    init(providing type: String) throws(HelperFailure) {
        guard let source = Self(rawValue: type) else { throw HelperFailure("unknown power source \"\(type)\"") }
        self = source
    }

    /// The source the Mac runs on now, from IOKit.
    static func current() throws(HelperFailure) -> PmsetSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { throw HelperFailure("IOKit names no power source") }
        return try PmsetSource(providing: type as String)
    }

    /// pmset's flag for this source's settings, and the heading `pmset -g custom` lists them under.
    var flag: String {
        switch self {
        case .adapter: "-c"
        case .battery: "-b"
        case .ups: "-u"
        }
    }

    var heading: String { rawValue + ":" }
}

/// The helper's Low Power Mode operation, apart from the processes it runs and the source it reads.
enum LowPowerModeWrite {
    /// [LAW:effects-at-boundaries] Asks `pmset` for this Mac's listing, then writes the key it names on
    /// `source`; returns the write's arguments. `pmset` runs /usr/bin/pmset with the arguments given.
    static func perform(_ on: Bool, source: PmsetSource, pmset: ([String]) throws(HelperFailure) -> String) throws(HelperFailure) -> [String] {
        let arguments = try PowerModeKey(listing: pmset(["-g"])).arguments(on: on, source: source)
        _ = try pmset(arguments)
        return arguments
    }

    /// /usr/bin/pmset run to its end before `deadline`: its output, or a failure with its status and output.
    /// [LAW:one-source-of-truth] The deadline is the call's, so the time a write waited behind others is spent
    /// from the same budget, and a run that cannot start in time does not start.
    static func pmset(_ arguments: [String], until deadline: Date) throws(HelperFailure) -> String {
        let command = "pmset \(arguments.joined(separator: " "))"
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw HelperFailure("\(command) not run: the call's deadline passed \((-left).formatted(.number.precision(.fractionLength(1)))) s ago") }
        let run: ChildProcess
        do { run = try ChildProcess.run("/usr/bin/pmset", arguments, deadline: left) } catch { throw HelperFailure("\(command): \(error)") }
        guard run.status == 0 else { throw HelperFailure("\(command) exited \(run.status): \(run.transcript)") }
        return run.text
    }

    /// The helper's log line for one call: who asked for which state, and what pmset did.
    static func line(_ on: Bool, peer: Int32, _ outcome: Result<[String], HelperFailure>) -> String {
        let asked = "low power mode \(on ? "on" : "off") for pid \(peer)"
        switch outcome {
        case .success(let arguments): return "\(asked): pmset \(arguments.joined(separator: " ")) ok"
        case .failure(let failure): return "\(asked) failed: \(failure)"
        }
    }
}

extension Result {
    /// The error, or nil on success.
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

struct HelperFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The launchd plist an app embeds for its helper. [LAW:one-source-of-truth] project.yml writes it from
/// HELPER_LABEL; the app and the check client read the label back from here and never spell it.
struct LaunchDaemon {
    let plistName: String
    let label: String
    /// The helper's path inside the app, its `BundleProgram`.
    let program: String

    /// [LAW:parse-dont-validate] The bundle's one plist, or a failure naming what was found instead.
    init(in app: Bundle) throws(HelperFailure) {
        let directory = app.bundleURL.appending(path: "Contents/Library/LaunchDaemons")
        let plists: [URL]
        do { plists = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) } catch {
            throw HelperFailure("no launchd plist directory at \(directory.path): \(error)")
        }
        guard plists.count == 1, let plist = plists.first else { throw HelperFailure("expected one launchd plist in \(directory.path), found \(plists.map(\.lastPathComponent))") }
        let contents: [String: Any]?
        do { contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] } catch {
            throw HelperFailure("\(plist.path) is not a property list: \(error)")
        }
        guard let label = contents?["Label"] as? String, let services = contents?["MachServices"] as? [String: Any], services.keys.sorted() == [label],
              let program = contents?["BundleProgram"] as? String else {
            throw HelperFailure("\(plist.path) needs a Label, exactly that one MachServices entry, and a BundleProgram")
        }
        plistName = plist.lastPathComponent
        self.label = label
        self.program = program
    }
}

/// A signature's signing information: where the helper's identity and its rule for callers are read from.
enum SigningInformation {
    static func of(_ code: SecStaticCode, flags: UInt32 = kSecCSSigningInformation) throws(HelperFailure) -> [String: Any] {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: flags), &info)
        guard status == errSecSuccess, let info = info as? [String: Any] else { throw HelperFailure("no signing information: OSStatus \(status)") }
        return info
    }

    /// The running process's own, read from the running code rather than the file on disk, so a file
    /// replaced after launch cannot change it. A running SecCode is accepted wherever a SecStaticCode is;
    /// Swift keeps the two types apart, hence the cast.
    static func ofSelf(flags: UInt32 = kSecCSSigningInformation) throws(HelperFailure) -> [String: Any] {
        var me: SecCode?
        let status = SecCodeCopySelf([], &me)
        guard status == errSecSuccess, let me else { throw HelperFailure("SecCodeCopySelf: OSStatus \(status)") }
        return try of(unsafeBitCast(me, to: SecStaticCode.self), flags: flags)
    }
}

/// What a signed helper says about itself: the facts its caller requirement is built from.
struct Signer: Equatable {
    let team: String
    /// The helper's Mach service, which is its launchd label and its bundle identifier.
    let service: String
    /// The bundle identifier of the one app the helper serves.
    let app: String
    /// Whether a caller may carry get-task-allow, which lets other code of the same user attach to it and
    /// act through it. Only a Debug helper admits one, because its Debug app carries it.
    let admitsDebuggableCallers: Bool

    /// [LAW:one-source-of-truth] Every fact comes from one signature: the team, and the Info.plist bound
    /// into it, never a file read off disk. [LAW:parse-dont-validate] A helper without a team, ad hoc for
    /// instance, has no requirement to enforce, so it has no `Signer` at all.
    init(signingInformation info: [String: Any]) throws(HelperFailure) {
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { throw HelperFailure("the helper's signature has no team") }
        guard let plist = info[kSecCodeInfoPList as String] as? [String: Any] else { throw HelperFailure("the helper's signature binds no Info.plist") }
        guard let service = plist["CFBundleIdentifier"] as? String, !service.isEmpty,
              let app = plist["OrangeDrinkAppIdentifier"] as? String, !app.isEmpty,
              let admits = plist["OrangeDrinkAdmitsDebuggableCallers"] as? String, ["YES", "NO"].contains(admits) else {
            throw HelperFailure("the helper's Info.plist lacks CFBundleIdentifier, OrangeDrinkAppIdentifier, or a YES/NO OrangeDrinkAdmitsDebuggableCallers: \(plist)")
        }
        self.team = team
        self.service = service
        self.app = app
        admitsDebuggableCallers = admits == "YES"
    }

    /// Code Apple's CA issued to this helper's own team, carrying the app's identifier, and, outside Debug,
    /// not debuggable. A rebuild leaves it unchanged, and a process that is not the team's build of the app
    /// cannot meet it.
    var callerRequirement: String {
        let teamBuildOfTheApp = "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
        return admitsDebuggableCallers ? teamBuildOfTheApp : teamBuildOfTheApp + " and !entitlement[\"com.apple.security.get-task-allow\"]"
    }
}

struct HelperIdentity: Equatable, Sendable {
    let executable: String
    let euid: UInt32
}

enum HelperCallError: Error, CustomStringConvertible, Equatable {
    /// The connection ended without a reply. [LAW:no-silent-failure] A refused caller sees only
    /// NSCocoaErrorDomain 4097, as an unreachable helper would; the helper's log tells them apart.
    case connection(domain: String, code: Int, description: String)
    /// Neither a reply nor an error in time: launchd may have refused or wedged the job.
    case noReply(seconds: Int, service: String)
    /// The helper answered that the operation did not happen, and why.
    case failed(String)
    /// The helper answered that this Mac cannot do it at all, and why: asking again will not change it.
    case unsupported(String)

    var description: String {
        switch self {
        case .connection(let domain, let code, let description): "call failed: domain=\(domain) code=\(code) \(description)"
        case .noReply(let seconds, let service):
            "no reply in \(seconds) s: launchd may have refused or wedged the job; see `launchctl print system/\(service)` (last exit reason)"
        case .failed(let reason): "the helper failed: \(reason)"
        case .unsupported(let reason): ChargingFailure.unsupported(reason).description
        }
    }

    /// A charging call's reply, read back.
    static func charging(kind: Int, description: String?) -> Result<Void, HelperCallError> {
        ChargingFailure.parse(kind: kind, description: description).mapError { failure in
            switch failure {
            case .unsupported(let reason): .unsupported(reason)
            case .failed(let reason): .failed(reason)
            }
        }
    }
}

/// Calls the helper the way the app does. One connection per call, so a call never holds the helper alive; the one
/// exception is a charging pause, whose kept connection is the pause (`ChargeLease`).
/// Each call blocks until the reply or its deadline, so the app makes it off the main thread.
struct HelperClient {
    let service: String

    /// [LAW:one-source-of-truth] The one bound on a call, in seconds: the app's, the check client's, and the
    /// live tests'. A job launchd refused shows up as a call that never answers.
    static let deadline = 10
    /// The last part of a call's budget, kept for the reply to cross back: the helper's work ends this long
    /// before the caller stops waiting, so a write the helper reports done is never one the caller gave up on.
    static let replyAllowance: TimeInterval = 1

    /// The instant a call that starts now must have its helper's work done by.
    static func workEnds() -> Date { Date(timeIntervalSinceNow: TimeInterval(deadline) - replyAllowance) }

    func identity() throws(HelperCallError) -> HelperIdentity {
        try call { helper, _, finish in
            helper.identity { executable, euid in finish(.success(HelperIdentity(executable: executable, euid: euid))) }
        }
    }

    func setLowPowerMode(_ on: Bool) throws(HelperCallError) {
        try call { helper, deadline, finish in
            helper.setLowPowerMode(on, until: deadline) { failure in finish(failure.map { .failure(.failed($0)) } ?? .success(())) }
        }
    }

    /// Lets go of nothing and has the helper bring CHTE to what its holders want: at launch, this starts the helper,
    /// whose start ends a pause a helper that died left behind.
    func resumeCharging() throws(HelperCallError) {
        try call { helper, deadline, finish in
            helper.resumeCharging(until: deadline) { kind, description in finish(HelperCallError.charging(kind: kind, description: description)) }
        }
    }

    /// Holds charging paused on a connection kept for it; the lease is that connection. `lost` hears, once, that the
    /// helper ended a lease it had granted; a lease this call fails to grant is ended here and never reported.
    func pauseCharging(lost: @escaping @Sendable (ObjectIdentifier) -> Void) throws(HelperCallError) -> ChargeLease {
        let lease = ChargeLease(connection: connect(), service: service, lost: lost)
        do {
            try Self.send(on: lease.connection, service: service) { helper, deadline, finish in
                helper.pauseCharging(until: deadline) { kind, description in finish(HelperCallError.charging(kind: kind, description: description)) }
            }
            try lease.arm()
        } catch {
            lease.end()
            throw error
        }
        return lease
    }

    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelper.self)
        return connection
    }

    /// One call on a connection of its own, ended with the call.
    private func call<Value: Sendable>(
        _ invoke: (PrivilegedHelper, Date, @escaping @Sendable (Result<Value, HelperCallError>) -> Void) -> Void
    ) throws(HelperCallError) -> Value {
        let connection = connect()
        connection.resume()
        defer { connection.invalidate() }
        return try Self.send(on: connection, service: service, invoke)
    }

    /// [LAW:one-type-per-behavior] Every operation's deadline and outcome, on whichever connection carries it:
    /// `invoke` sends one message and calls `finish` from its reply.
    fileprivate static func send<Value: Sendable>(
        on connection: NSXPCConnection, service: String,
        _ invoke: (PrivilegedHelper, Date, @escaping @Sendable (Result<Value, HelperCallError>) -> Void) -> Void
    ) throws(HelperCallError) -> Value {
        // The first of the reply and the error wins; the other, if it comes, is dropped.
        let result = OSAllocatedUnfairLock<Result<Value, HelperCallError>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<Value, HelperCallError>) -> Void = { outcome in
            result.withLock { $0 = $0 ?? outcome }
            done.signal()
        }
        let helper = connection.remoteObjectProxyWithErrorHandler { error in
            let error = error as NSError
            finish(.failure(.connection(domain: error.domain, code: error.code, description: error.localizedDescription)))
        } as! PrivilegedHelper
        invoke(helper, Self.workEnds(), finish)
        guard done.wait(timeout: .now() + .seconds(Self.deadline)) == .success, let outcome = result.withLock({ $0 }) else {
            throw .noReply(seconds: Self.deadline, service: service)
        }
        return try outcome.get()
    }
}

/// A pause of charging the helper holds for the app: the one connection the app keeps open to it.
///
/// [LAW:no-ambient-temporal-coupling] The connection is the lease, so either side's death ends it: the app's quit or
/// crash closes it and the helper lets go; the helper's exit interrupts it and `lost` is told. A lease ends exactly
/// once, and only an end the app did not cause is reported: `lost` is armed by the reply that granted the lease, and
/// `release`, a failed grant, and deinit each end it unarmed.
final class ChargeLease: @unchecked Sendable {
    // [LAW:types-are-the-program] exception: @unchecked, because NSXPCConnection is not marked Sendable; Apple
    // documents it as safe to message from any thread, and `stage` is the lease's only other state, under its lock.
    fileprivate let connection: NSXPCConnection
    private let service: String
    private let lost: @Sendable (ObjectIdentifier) -> Void
    private let stage = OSAllocatedUnfairLock(initialState: Stage.granting)

    private enum Stage { case granting, armed, ended }

    fileprivate init(connection: NSXPCConnection, service: String, lost: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.service = service
        self.lost = lost
        // Weak, so the connection's handlers do not keep the lease alive past its holder.
        connection.interruptionHandler = { [weak self] in self?.end() }
        connection.invalidationHandler = { [weak self] in self?.end() }
        connection.resume()
    }

    /// The grant's reply landed: from here, an end the app did not ask for is reported. A connection that ended while
    /// the reply crossed was never a lease.
    fileprivate func arm() throws(HelperCallError) {
        let armed = stage.withLock { stage in
            guard stage == .granting else { return false }
            stage = .armed
            return true
        }
        guard armed else { throw .failed("the helper went away before the pause was held") }
    }

    /// Ends the lease. Only an armed lease's first end is reported: the helper's exit, or the system's end of the
    /// connection. Every later end, and every end of an unarmed lease, is silent by construction.
    fileprivate func end() {
        let wasArmed = stage.withLock { stage in
            defer { stage = .ended }
            return stage == .armed
        }
        connection.invalidate()
        if wasArmed { lost(ObjectIdentifier(self)) }
    }

    /// Lets go of the pause: the helper is told on this connection, then the connection ends. The lease is used up
    /// whatever the reply; a failure says the helper did not confirm it.
    func release() throws(HelperCallError) {
        stage.withLock { $0 = .ended }
        defer { connection.invalidate() }
        try HelperClient.send(on: connection, service: service) { helper, deadline, finish in
            helper.resumeCharging(until: deadline) { kind, description in finish(HelperCallError.charging(kind: kind, description: description)) }
        }
    }

    deinit {
        stage.withLock { $0 = .ended }
        connection.invalidate()
    }
}
