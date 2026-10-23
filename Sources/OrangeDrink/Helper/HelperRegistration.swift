import Darwin
import Foundation
import OSLog
import ServiceManagement

/// What registering the privileged helper at launch did.
///
/// [LAW:no-ambient-temporal-coupling] The helper's system record belongs to this copy of the app, since the
/// label is the copy's (project.yml HELPER_LABEL), and lives exactly as long as some process runs the copy:
/// a launch takes it unless another process already holds it, and an exit releases it unless another process
/// still runs. So a copy that has exited, been deleted, or been replaced leaves no record behind, and one
/// process of a copy never removes the record from under another (orange-admin-helper-b2q.qm0).
struct HelperRegistration: Equatable {
    /// What happened to a record already there before registering.
    enum Before: Equatable {
        /// Unregistered: `nil`, or the error it gave. Nothing to unregister fails with
        /// SMAppServiceErrorDomain 1, the usual case after a clean exit.
        case unregistered(error: String?)
        /// Left alone, because these other processes run this copy and hold it.
        case heldBy(pids: [Int32])
    }

    enum Outcome: Equatable {
        case registered(status: String)
        case refused(error: String, status: String)
    }

    let before: Before
    let outcome: Outcome

    /// [LAW:effects-at-boundaries] The log line, a pure function of what SMAppService answered.
    var line: String {
        let before = switch before {
        case .unregistered(nil): "cleared ok"
        case .unregistered(let error?): "cleared \(error)"
        case .heldBy(let pids): "kept for pid \(pids.map(String.init).joined(separator: ", "))"
        }
        let registration = switch outcome {
        case .registered(let status): "registered; status \(status)"
        case .refused(let error, let status): "refused (\(error)); status \(status)"
        }
        return "helper registration: \(before); \(registration)"
    }

    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "helper")

    /// The launch path's one call. It installs the one handler that releases the record at exit, then, off
    /// the main thread since each step is a round trip to the system's background-task daemons, unregisters
    /// (which also repairs a job a crashed copy left wedged) and registers, so this copy's helper is the
    /// job's program; approval survives both steps. A refusal, such as an approval not yet given, is logged,
    /// and the app runs without the helper. An exit while this is under way can leave the record, which the
    /// copy's next launch clears.
    static func holdUntilExit() {
        // A C function pointer captures nothing, so the handler finds the service again from the bundle.
        atexit {
            let others = HelperRegistration.otherProcessesOfThisCopy()
            guard others.isEmpty else {
                HelperRegistration.log.notice("helper kept at exit for pid \(others.map(String.init).joined(separator: ", "), privacy: .public)")
                return
            }
            let service = HelperRegistration.daemon()
            let released = HelperRegistration.attempt(service.unregister).map(HelperRegistration.describe) ?? "ok"
            HelperRegistration.log.notice("helper unregistered: \(released, privacy: .public); status \(service.status.name, privacy: .public)")
        }
        DispatchQueue.global(qos: .utility).async {
            let service = daemon()
            let others = otherProcessesOfThisCopy()
            let before: Before = others.isEmpty ? .unregistered(error: attempt(service.unregister).map(describe)) : .heldBy(pids: others)
            let refusal = attempt(service.register)
            let status = service.status.name
            let registration = HelperRegistration(before: before, outcome: refusal.map { .refused(error: describe($0), status: status) } ?? .registered(status: status))
            log.notice("\(registration.line, privacy: .public)")
        }
    }

    /// [LAW:one-source-of-truth] The service for the plist this build embeds. A build without one is broken.
    static func daemon() -> SMAppService {
        do { return SMAppService.daemon(plistName: try LaunchDaemon(in: .main).plistName) } catch { fatalError("no helper launchd plist: \(error)") }
    }

    /// Every other process running this copy's executable, any user's: the processes that share its record.
    static func otherProcessesOfThisCopy() -> [Int32] {
        let own = Bundle.main.executableURL!.resolvingSymlinksInPath().path
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 != getpid() && executablePath(of: $0) == own }
    }

    /// The error a step threw, or nil when it succeeded.
    static func attempt(_ step: () throws -> Void) -> NSError? {
        do { try step(); return nil } catch { return error as NSError }
    }

    static func describe(_ error: NSError) -> String { "\(error.domain) \(error.code) \(error.localizedDescription)" }
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
