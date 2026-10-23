import Foundation
import OSLog
import ServiceManagement

/// What registering the privileged helper at launch did.
///
/// [LAW:no-ambient-temporal-coupling] The helper's system record lives exactly as long as this process:
/// `holdUntilExit` takes it at launch and an `atexit` handler releases it, so a copy of the app that has
/// exited, been deleted, or been replaced leaves no record behind (orange-admin-helper-b2q.qm0).
struct HelperRegistration: Equatable {
    enum Outcome: Equatable {
        case registered(status: String)
        case refused(error: String, status: String)
    }

    /// `ok`, or the error unregistering a previous record gave. Nothing to unregister fails with
    /// SMAppServiceErrorDomain 1, which is the usual case after a clean exit.
    let cleared: String
    let outcome: Outcome

    /// [LAW:effects-at-boundaries] The log line, a pure function of what SMAppService answered.
    var line: String {
        let registration = switch outcome {
        case .registered(let status): "registered; status \(status)"
        case .refused(let error, let status): "refused (\(error)); status \(status)"
        }
        return "helper registration: cleared \(cleared); \(registration)"
    }

    static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "helper")

    /// The launch path's one call. It unregisters first, which also repairs a job a crashed copy left
    /// wedged, then registers, so this copy's helper is the job's program; approval survives both steps.
    /// Then it installs the one handler that unregisters at exit. A refusal, such as an approval not
    /// yet given, is logged, and the app runs without the helper.
    @discardableResult static func holdUntilExit() -> HelperRegistration {
        let service = daemon()
        let cleared = describe(attempt(service.unregister))
        let refusal = attempt(service.register)
        let status = service.status.name
        let registration = HelperRegistration(cleared: cleared, outcome: refusal.map { .refused(error: describe($0), status: status) } ?? .registered(status: status))
        log.notice("\(registration.line, privacy: .public)")
        // A C function pointer captures nothing, so the handler finds the service again from the bundle.
        atexit {
            let service = HelperRegistration.daemon()
            let released = HelperRegistration.describe(HelperRegistration.attempt(service.unregister))
            HelperRegistration.log.notice("helper unregistered: \(released, privacy: .public); status \(service.status.name, privacy: .public)")
        }
        return registration
    }

    /// [LAW:one-source-of-truth] The service for the plist this build embeds. A build without one is broken.
    static func daemon() -> SMAppService {
        do { return SMAppService.daemon(plistName: try LaunchDaemon(in: .main).plistName) } catch { fatalError("no helper launchd plist: \(error)") }
    }

    /// The error a step threw, or nil when it succeeded.
    static func attempt(_ step: () throws -> Void) -> NSError? {
        do { try step(); return nil } catch { return error as NSError }
    }

    static func describe(_ error: NSError?) -> String {
        error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "ok"
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
