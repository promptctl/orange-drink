import Darwin
import Foundation
import os
import OSLog
import ServiceManagement

/// What the app does with the privileged helper's system record and launchd's job for it, at launch, at exit, and
/// when a call finds the helper gone.
///
/// [LAW:no-ambient-temporal-coupling] The record belongs to the helper's label (project.yml HELPER_LABEL) and
/// lives exactly as long as some process runs a copy of the app that embeds that label: a launch takes it,
/// and an exit releases it unless one still runs. A build's label is that build's alone; the shipped label
/// is shared by every installed copy, the one in the mounted image and the one in /Applications alike. So a
/// copy that has exited leaves no record behind, and no process removes the record from under another
/// (orange-admin-helper-b2q.qm0). The exception is a copy moved or deleted while it runs: `unregister` needs the
/// bundle, so its record and launchd's job stay until a copy with this label next exits.
///
/// [LAW:single-enforcer] Every step runs on one serial queue, so no two interleave, an ask waits for the steps
/// ahead of it, and the exit is the last.
struct HelperRegistration: Sendable {
    /// What happened to a record already there.
    enum Clearing: Equatable {
        /// Unregistered: `nil`, or the error it gave. Nothing to unregister fails with SMAppServiceErrorDomain 1,
        /// which in a repair means launchd holds a job with no record (orange-admin-helper-b2q.8ew).
        case unregistered(error: String?)
        /// Left alone, because these other processes run a copy with this label and hold it.
        case heldBy(pids: [Int32])
        /// Left alone, because who holds it could not be read.
        case holdersUnread(errno: Int32)
    }

    /// What `register` answered, the last time it was asked, and how long that took.
    struct Outcome: Equatable {
        /// The last refusal, or nil once it was accepted. With no helper file to run, it says why and `attempts` counts
        /// the asks made before that was found, none if it was found first.
        let refusal: String?
        let status: String
        let attempts: Int
        let elapsed: Duration

        var text: String {
            "\(refusal.map { "refused (\($0))" } ?? "registered"); status \(status); attempt \(attempts) after \(Int(elapsed / .milliseconds(1))) ms"
        }
    }

    /// What the helper's handshake says about the job. [LAW:one-source-of-truth] The cdhash decides, since it names the
    /// code that serves: a copy of this code at another path is this helper, and older code moved aside from this path
    /// is not, though it still gives the path it started at. It is compared with the file in this bundle as it is now,
    /// the code `register` would run: a hash kept from launch would call a bundle replaced under this copy other code
    /// that no repair can remove, and every failed call would stop a helper that is already the right one.
    enum Handshake: Equatable {
        /// This copy's helper answered, which proves launchd runs the job.
        case own
        /// Other code answered: a helper another copy started, which `register` leaves running.
        case otherCode(executable: String, cdhash: Data)
        case failed(HelperCallError)
        /// The file in this bundle has no readable cdhash, so a new job would have nothing to run.
        case embeddedUnreadable(String)

        /// [LAW:parse-dont-validate] The handshake's reply, read against the cdhash of the helper this copy embeds.
        init(reply: Result<HelperIdentity, HelperCallError>, embedded: Result<Data, HelperFailure>) {
            switch (embedded, reply) {
            case (.failure(let failure), _): self = .embeddedUnreadable(failure.description)
            case (_, .failure(let error)): self = .failed(error)
            case (.success(let cdhash), .success(let identity)):
                self = identity.cdhash == cdhash ? .own : .otherCode(executable: identity.executable, cdhash: identity.cdhash)
            }
        }

        /// The cdhash of the file at `helper`, read now.
        static func embedded(at helper: URL) -> Result<Data, HelperFailure> {
            Result { () throws(HelperFailure) in try SigningInformation.cdhash(of: helper) }
        }

        /// [LAW:effects-at-boundaries] One look: what answers, and what the file at `helper` holds, read now.
        static func look(at helper: URL, asking identity: () throws(HelperCallError) -> HelperIdentity) -> Handshake {
            Handshake(reply: Result { () throws(HelperCallError) in try identity() }, embedded: embedded(at: helper))
        }

        /// A job nothing runs, that runs other code, or whose helper ends the connection unanswered is replaced: a helper
        /// that refuses this copy looks like that last one (`HelperCallError.connection`). NSXPCConnectionInvalid, or any
        /// other failure, is not one a new job answers: it is how a call fails with no job there, as after a refused
        /// `register`. This copy's own helper keeps its job and any pause it holds, however slow it was.
        var replacesJob: Bool {
            switch self {
            case .otherCode, .failed(.noReply): true
            case .failed(.connection(let domain, let code, _)): domain == NSCocoaErrorDomain && code == NSXPCConnectionInterrupted
            case .own, .failed, .embeddedUnreadable: false
            }
        }

        var text: String {
            switch self {
            case .own: "the helper answered"
            case .otherCode(let executable, let cdhash): "other code answered (cdhash \(cdhash.hex), started from \(executable))"
            case .failed(let error): "handshake \(error.description)"
            case .embeddedUnreadable(let reason): "embedded helper unreadable: \(reason)"
            }
        }
    }

    enum Event: Equatable {
        case launched(Outcome)
        /// A failed call found no job, so this registers one.
        case reregistered(Outcome)
        /// The record waits for the user's approval, so nothing looked at the job.
        case awaitingApproval
        /// The handshake found nothing to replace.
        case leftAlone(Handshake)
        /// The handshake called for a new job, and `unregister` was not asked, so the job stays as it was.
        case kept(Clearing, Handshake)
        /// `found` called for a new job, so `unregister` was asked, and `register` after it even if `unregister` failed,
        /// since a job with no record fails it. `handshake` is the proof a status cannot give, since it read enabled
        /// through the wedge. The answer also starts the helper, which ends a pause one that died left behind.
        case repaired(found: Handshake, Clearing, Outcome, handshake: Handshake)
        case exited(Clearing, status: String)

        /// [LAW:effects-at-boundaries] The log line, a pure function of what SMAppService answered.
        var line: String {
            switch self {
            case .launched(let outcome): "helper registration: \(outcome.text)"
            case .reregistered(let outcome): "helper registration, a call found no job: \(outcome.text)"
            case .awaitingApproval: "helper check: left the job alone; the record waits for the user's approval"
            case .leftAlone(let handshake): "helper check: left the job alone; \(handshake.text)"
            case .kept(let clearing, let handshake): "helper check: \(clearing.text); \(handshake.text)"
            case .repaired(let found, let clearing, let outcome, let handshake): "helper repair: \(found.text); \(clearing.text); \(outcome.text); \(handshake.text)"
            case .exited(let clearing, let status): "helper at exit: \(clearing.text); status \(status)"
            }
        }
    }

    /// The system calls a step makes, as one seam.
    struct Effects: Sendable {
        /// SMAppService's register and unregister: the error each gave, or nil.
        let register: @Sendable () -> NSError?
        let unregister: @Sendable () -> NSError?
        let status: @Sendable () -> SMAppService.Status
        /// The helper file in this bundle as it is now.
        let embedded: @Sendable () -> Result<Data, HelperFailure>
        /// The helper's handshake, which never touches its write queue.
        let handshake: @Sendable () -> Handshake
        let holders: @Sendable () throws(ProcessTableUnreadable) -> [Int32]
        let now: @Sendable () -> ContinuousClock.Instant
        let pause: @Sendable (Duration) -> Void
    }

    /// How long `register` is asked again after refusing with no record there. For a moment after `unregister`,
    /// background task management refuses it, and a refused attempt seems to start that moment again: 12 attempts
    /// 280 ms apart were all refused, while one 609 ms after the last was accepted (orange-admin-helper-b2q.8ew).
    /// So the gap is what lets it through. The cause is unknown, so this bound decides only how soon the helper is
    /// back: the next failed call registers again, and the event's attempts show how the refusal behaves in the field.
    static let refusalWindow = Duration.seconds(3)
    static let attemptGap = Duration.seconds(1)

    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "helper")

    /// [LAW:one-source-of-truth] The plist this build embeds, read once at launch, so the exit handler does
    /// not depend on the bundle still being on disk. A build without one is broken.
    static let daemon: LaunchDaemon = {
        do { return try LaunchDaemon(in: .main) } catch { fatalError("no helper launchd plist: \(error)") }
    }()

    /// The helper file in this bundle, which `register` makes the job's program.
    static var embeddedHelper: URL { Bundle.main.bundleURL.appending(path: daemon.program) }

    /// The app's registration, on the plist this build embeds.
    static let app: HelperRegistration = {
        let plistName = daemon.plistName, label = daemon.label, helper = embeddedHelper
        // Made at each step, since it is not Sendable.
        let service: @Sendable () -> SMAppService = { SMAppService.daemon(plistName: plistName) }
        return HelperRegistration(effects: Effects(
            register: { attempt(service().register) },
            unregister: { attempt(service().unregister) },
            status: { service().status },
            embedded: { Handshake.embedded(at: helper) },
            handshake: { Handshake.look(at: helper) { () throws(HelperCallError) in try HelperClient(service: label).identity() } },
            holders: { () throws(ProcessTableUnreadable) in try otherHolders() },
            now: { .now },
            pause: { Thread.sleep(forTimeInterval: $0 / .seconds(1)) }
        ), record: { event in log.notice("\(event.line, privacy: .public)") })
    }()

    let effects: Effects
    let record: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "dev.orangedrink.helper-registration")
    /// Set as the exit starts, and read by each reconcile as it runs.
    private let exiting = OSAllocatedUnfairLock(initialState: false)

    init(effects: Effects, record: @escaping @Sendable (Event) -> Void) {
        self.effects = effects
        self.record = record
    }

    /// The launch path's one call: it installs the one handler that releases the record at exit, then registers,
    /// off the main thread since each step is a round trip to the system's background-task daemons. A refusal,
    /// such as an approval not yet given, is logged, and the app runs without the helper.
    static func holdUntilExit() {
        atexit { HelperRegistration.app.exit() }
        app.launch()
    }

    /// Registers, which alone makes this copy's helper the job's program and leaves a job a crash left running, so the
    /// handshake that follows replaces a helper that is not this copy's. An `unregister` first would be refused the
    /// `register` after it, and can't reach a job whose record has gone. The step is queued ahead of every ask, so no
    /// lease of this copy's can be on the helper it replaces.
    func launch() {
        queue.async {
            record(.launched(register(within: Self.refusalWindow)))
            settleJob()
        }
    }

    /// Returns once the steps ahead of this call have run, so no ask meets a service not registered yet.
    func waitForSteps() {
        queue.sync {}
    }

    /// The registration's last step: it releases what the steps ahead of it registered. A reconcile that has not
    /// started by now runs nothing, whether it was waiting or comes from a call the exit cut short, so it neither
    /// delays the exit with work the exit would undo nor registers again behind the release.
    func exit() {
        exiting.withLock { $0 = true }
        queue.sync {
            let clearing = clear()
            record(.exited(clearing, status: effects.status().name))
        }
    }

    /// What a failed call asks of the registration. [LAW:no-silent-failure] The call stays failed: nothing is retried
    /// here, and its caller's next ask finds what this left.
    func reconcile(after failure: HelperUseFailure) {
        queue.async {
            guard !exiting.withLock({ $0 }) else { return }
            if failure.cause == .notRegistered {
                // One attempt, since `register` alone opens no refusal window: a copy refused for good pays one attempt
                // per input rather than the window, and the next input asks again.
                record(.reregistered(register(within: .zero)))
            }
            settleJob()
        }
    }

    /// [LAW:single-enforcer] The one place the helper's answer decides the job, wherever the look comes from. A lease
    /// this copy holds on a helper this replaces ends with it, and the hold's ask for a new one waits for this step. A
    /// record waiting for the user's approval is theirs to allow, on any route: `unregister` would take it out of Login
    /// Items, and no new job answers before they allow it.
    private func settleJob() {
        guard effects.status() != .requiresApproval else {
            record(.awaitingApproval)
            return
        }
        let handshake = effects.handshake()
        guard handshake.replacesJob else {
            record(.leftAlone(handshake))
            return
        }
        let clearing = clear()
        guard case .unregistered = clearing else {
            record(.kept(clearing, handshake))
            return
        }
        let outcome = register(within: Self.refusalWindow)
        record(.repaired(found: handshake, clearing, outcome, handshake: effects.handshake()))
    }

    /// Asks `register` until it accepts, or it refuses for a reason other than the refusal window, or `window` ends, or
    /// the helper file is gone. [LAW:single-enforcer] Each ask has its own read, because `register` on a copy whose
    /// bundle was moved or deleted while it runs segfaults inside ServiceManagement (orange-distribution-kg2.45x).
    private func register(within window: Duration) -> Outcome {
        let start = effects.now()
        var attempts = 0
        while true {
            if case .failure(let failure) = effects.embedded() {
                return Outcome(refusal: failure.description, status: effects.status().name, attempts: attempts, elapsed: start.duration(to: effects.now()))
            }
            attempts += 1
            let refusal = effects.register()
            let status = effects.status()
            let elapsed = start.duration(to: effects.now())
            guard refusal != nil, status.hasNoRecord, elapsed < window else {
                return Outcome(refusal: refusal.map(Self.describe), status: status.name, attempts: attempts, elapsed: elapsed)
            }
            effects.pause(Self.attemptGap)
        }
    }

    /// Unregisters the record unless another process holds it. This also ends a job launchd will not run, which
    /// `register` leaves as it is, so long as there is a record for `unregister` to find.
    private func clear() -> Clearing {
        do {
            let holders = try effects.holders()
            return holders.isEmpty ? .unregistered(error: effects.unregister().map(Self.describe)) : .heldBy(pids: holders)
        } catch {
            return .holdersUnread(errno: error.errno)
        }
    }

    /// Every other process, any user's, running a copy of the app whose helper has this label: the
    /// processes that share its record.
    static func otherHolders() throws(ProcessTableUnreadable) -> [Int32] {
        try Processes.all().filter { $0 != getpid() && Processes.executablePath(of: $0).map(runsThisLabel) == true }
    }

    /// Whether an executable is a copy of the app whose helper has this label.
    static func runsThisLabel(_ executable: String) -> Bool {
        let inBundle = "/Contents/MacOS/" + Bundle.main.executableURL!.lastPathComponent
        guard executable.hasSuffix(inBundle), let copy = Bundle(path: String(executable.dropLast(inBundle.count))) else { return false }
        // A copy whose plist is gone or unreadable embeds no label, so it holds nothing.
        return (try? LaunchDaemon(in: copy).label) == daemon.label
    }

    /// The error a step threw, or nil when it succeeded.
    static func attempt(_ step: () throws -> Void) -> NSError? {
        do { try step(); return nil } catch { return error as NSError }
    }

    static func describe(_ error: NSError) -> String { "\(error.domain) \(error.code) \(error.localizedDescription)" }
}

extension HelperRegistration.Clearing {
    var text: String {
        switch self {
        case .unregistered(nil): "cleared ok"
        case .unregistered(let error?): "cleared \(error)"
        case .heldBy(let pids): "kept for pid \(pids.map(String.init).joined(separator: ", "))"
        case .holdersUnread(let errno): "kept, process table unreadable (errno \(errno))"
        }
    }
}

extension SMAppService.Status {
    /// [LAW:one-source-of-truth] Background task management holds no record, so launchd has no job for the helper.
    var hasNoRecord: Bool { self == .notRegistered || self == .notFound }

    var name: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}
