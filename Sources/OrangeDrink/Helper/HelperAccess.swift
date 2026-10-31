import Foundation
import ServiceManagement

/// Why a helper-backed control did not act: the call's own error, and the helper's approval when it failed.
///
/// [LAW:no-silent-failure] Both facts are kept. An unapproved helper has no job for launchd to look up, so its
/// call fails at once as NSCocoaErrorDomain 4099 (orange-admin-helper-b2q.1d4); the status says that is why,
/// and the call's error stays as the evidence.
struct HelperUseFailure: Error, Equatable, CustomStringConvertible {
    let call: HelperCallError
    let status: SMAppService.Status

    /// [LAW:one-source-of-truth] What the failure comes down to: what the screen says, how the hold settles, and what
    /// the registration does about it all read this.
    enum Cause: Equatable {
        /// The user can fix it by allowing the helper under Login Items.
        case needsApproval
        /// Background task management holds no record, so launchd has no job for the helper.
        case notRegistered
        /// The record says enabled, and the helper gave no reply: launchd may hold a job it will not run.
        case notAnswering
        case other
    }

    var cause: Cause {
        switch (call, status) {
        case (_, .requiresApproval): .needsApproval
        // It answered, so whatever the status says now, it is there.
        case (.failed, _), (.unsupported, _): .other
        case (_, .notRegistered), (_, .notFound): .notRegistered
        case (.noReply, .enabled): .notAnswering
        default: .other
        }
    }

    var description: String { "\(call.description) (cause \(cause), helper status \(status.name))" }
}

/// [LAW:single-enforcer] The app's one way to the privileged helper: every helper-backed control calls through
/// here, and the client is private, so every failure arrives explained.
struct HelperAccess {
    private let client: HelperClient
    /// The daemon's plist, which names its SMAppService. The service is made at each read, since it is not
    /// Sendable and a control's write runs off the main actor.
    private let plistName: String
    private let reconcile: @Sendable (HelperUseFailure) -> Void

    init(daemon: LaunchDaemon) {
        self.init(service: daemon.label, plistName: daemon.plistName, reconcile: HelperRegistration.app.reconcile(after:))
    }

    init(service: String, plistName: String, reconcile: @escaping @Sendable (HelperUseFailure) -> Void) {
        client = HelperClient(service: service)
        self.plistName = plistName
        self.reconcile = reconcile
    }

    func setLowPowerMode(_ on: Bool) throws(HelperUseFailure) {
        try Self.explained({ () throws(HelperCallError) in try client.setLowPowerMode(on) }, status: status, reconcile: reconcile)
    }

    func pauseCharging(lost: @escaping @Sendable (ChargeLease) -> Void) throws(HelperUseFailure) -> ChargeLease {
        try Self.explained({ () throws(HelperCallError) in try client.pauseCharging(lost: lost) }, status: status, reconcile: reconcile)
    }

    func release(_ lease: ChargeLease) throws(HelperUseFailure) {
        try Self.explained({ () throws(HelperCallError) in try lease.release() }, status: status, reconcile: reconcile)
    }

    func resumeCharging() throws(HelperUseFailure) {
        try Self.explained({ () throws(HelperCallError) in try client.resumeCharging() }, status: status, reconcile: reconcile)
    }

    /// [LAW:one-source-of-truth] Read fresh: the user approves or revokes in System Settings at any time.
    func status() -> SMAppService.Status { SMAppService.daemon(plistName: plistName).status }

    /// [LAW:effects-at-boundaries] Runs `call`; only a failed call reads `status`, once, and the failure carries both.
    /// `reconcile` hears the failure before the caller does, and returns at once.
    static func explained<Value>(_ call: () throws(HelperCallError) -> Value, status: () -> SMAppService.Status,
                                 reconcile: (HelperUseFailure) -> Void) throws(HelperUseFailure) -> Value {
        do { return try call() } catch {
            let failure = HelperUseFailure(call: error, status: status())
            reconcile(failure)
            throw failure
        }
    }
}
