import Darwin
import Foundation
import OSLog
import ServiceManagement

/// What the app does with the privileged helper's system record, at launch and at exit.
///
/// [LAW:no-ambient-temporal-coupling] The record belongs to the helper's label (project.yml HELPER_LABEL) and
/// lives exactly as long as some process runs a copy of the app that embeds that label: a launch takes it
/// unless another such process already holds it, and an exit releases it unless one still runs. A build's
/// label is that build's alone; the shipped label is shared by every installed copy, the one in the mounted
/// image and the one in /Applications alike. So a copy that has exited, been deleted, or been replaced
/// leaves no record behind, and no process removes the record from under another (orange-admin-helper-b2q.qm0).
enum HelperRegistration {
    /// What happened to a record already there.
    enum Clearing: Equatable {
        /// Unregistered: `nil`, or the error it gave. Nothing to unregister fails with
        /// SMAppServiceErrorDomain 1, the usual case at a launch after a clean exit.
        case unregistered(error: String?)
        /// Left alone, because these other processes run a copy with this label and hold it.
        case heldBy(pids: [Int32])
        /// Left alone, because who holds it could not be read.
        case holdersUnread(errno: Int32)
    }

    enum Outcome: Equatable {
        case registered(status: String)
        case refused(error: String, status: String)
    }

    enum Event: Equatable {
        case launched(Clearing, Outcome)
        case exited(Clearing, status: String)

        /// [LAW:effects-at-boundaries] The log line, a pure function of what SMAppService answered.
        var line: String {
            switch self {
            case .launched(let clearing, .registered(let status)): "helper registration: \(clearing.text); registered; status \(status)"
            case .launched(let clearing, .refused(let error, let status)): "helper registration: \(clearing.text); refused (\(error)); status \(status)"
            case .exited(let clearing, let status): "helper at exit: \(clearing.text); status \(status)"
            }
        }
    }

    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "helper")

    /// [LAW:one-source-of-truth] The plist this build embeds, read once at launch, so the exit handler does
    /// not depend on the bundle still being on disk. A build without one is broken.
    static let daemon: LaunchDaemon = {
        do { return try LaunchDaemon(in: .main) } catch { fatalError("no helper launchd plist: \(error)") }
    }()

    /// The launch path's one call. It installs the one handler that releases the record at exit, then, off
    /// the main thread since each step is a round trip to the system's background-task daemons, clears
    /// (which also repairs a job a crashed copy left wedged) and registers, so this copy's helper is the
    /// job's program; approval survives both steps. A refusal, such as an approval not yet given, is logged,
    /// and the app runs without the helper. An exit while this is under way can leave the record, which the
    /// copy's next launch clears.
    static func holdUntilExit() {
        let plistName = daemon.plistName
        // A C function pointer captures nothing, so the handler reads the plist name launch already read.
        atexit {
            let service = SMAppService.daemon(plistName: HelperRegistration.daemon.plistName)
            let clearing = HelperRegistration.clear(service)
            HelperRegistration.log.notice("\(HelperRegistration.Event.exited(clearing, status: service.status.name).line, privacy: .public)")
        }
        DispatchQueue.global(qos: .utility).async {
            let service = SMAppService.daemon(plistName: plistName)
            let clearing = clear(service)
            let refusal = attempt(service.register)
            let status = service.status.name
            log.notice("\(Event.launched(clearing, refusal.map { .refused(error: describe($0), status: status) } ?? .registered(status: status)).line, privacy: .public)")
        }
    }

    /// Unregisters the record unless another process holds it.
    static func clear(_ service: SMAppService) -> Clearing {
        do {
            let holders = try otherHolders()
            return holders.isEmpty ? .unregistered(error: attempt(service.unregister).map(describe)) : .heldBy(pids: holders)
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
