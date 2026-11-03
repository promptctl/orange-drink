import Foundation
import ServiceManagement

/// The helper file in this copy of the app, as read right after a call failed, beside the status read then.
enum HelperFile: Equatable {
    case readable
    /// A copy moved or deleted while it runs: why the file could not be read.
    case unreadable(String)

    /// [LAW:parse-dont-validate] The registration's read of the file, kept as what it found.
    init(_ read: Result<Data, HelperFailure>) {
        switch read {
        case .success: self = .readable
        case .failure(let failure): self = .unreadable(failure.description)
        }
    }
}

/// Why a helper-backed control did not act: the call's own error, and the helper's approval and file when it failed.
///
/// [LAW:no-silent-failure] Each fact is kept. An unapproved helper has no job for launchd to look up, so its
/// call fails at once as NSCocoaErrorDomain 4099 (orange-admin-helper-b2q.1d4); the status says that is why,
/// and the call's error stays as the evidence.
struct HelperUseFailure: Error, Equatable, CustomStringConvertible {
    let call: HelperCallError
    let status: SMAppService.Status
    let helperFile: HelperFile

    /// [LAW:one-source-of-truth] What the failure comes down to: what the screen says, how the hold settles, and what
    /// the registration does about it all read this.
    enum Cause: Equatable {
        /// This copy has no helper file to run, and approval and registration both need it, so only a copy opened
        /// anew has a helper.
        case helperFileUnreadable
        /// The user can fix it by allowing the helper under Login Items.
        case needsApproval
        /// Background task management holds no record, so launchd has no job for the helper.
        case notRegistered
        /// The record says enabled, and the helper gave no reply: launchd may hold a job it will not run.
        case notAnswering
        case other
    }

    var cause: Cause {
        switch (call, status, helperFile) {
        // It answered, so whatever the status says now, it is there.
        case (.failed, _, _), (.unsupported, _, _): .other
        case (_, _, .unreadable): .helperFileUnreadable
        case (_, .requiresApproval, _): .needsApproval
        case (_, let status, _) where status.hasNoRecord: .notRegistered
        case (.noReply, .enabled, _): .notAnswering
        default: .other
        }
    }

    var description: String {
        let file = if case .unreadable(let reason) = helperFile { "; helper file unreadable: \(reason)" } else { "" }
        return "\(call.description) (cause \(cause), helper status \(status.name)\(file))"
    }
}

/// [LAW:single-enforcer] The app's one way to the privileged helper: every helper-backed control calls through
/// here, and the client is private, so every failure arrives explained.
struct HelperAccess {
    private let client: HelperClient
    /// The daemon's plist, which names its SMAppService. The service is made at each read, since it is not
    /// Sendable and a control's write runs off the main actor.
    private let plistName: String
    private let registration: HelperRegistration

    init(daemon: LaunchDaemon) {
        self.init(service: daemon.label, plistName: daemon.plistName, registration: .app)
    }

    init(service: String, plistName: String, registration: HelperRegistration) {
        client = HelperClient(service: service)
        self.plistName = plistName
        self.registration = registration
    }

    func setLowPowerMode(_ on: Bool) throws(HelperUseFailure) {
        try explained { () throws(HelperCallError) in try client.setLowPowerMode(on) }
    }

    func pauseCharging(lost: @escaping @Sendable (ChargeLease) -> Void) throws(HelperUseFailure) -> ChargeLease {
        try explained { () throws(HelperCallError) in try client.pauseCharging(lost: lost) }
    }

    func release(_ lease: ChargeLease) throws(HelperUseFailure) {
        try explained { () throws(HelperCallError) in try lease.release() }
    }

    func resumeCharging() throws(HelperUseFailure) {
        try explained { () throws(HelperCallError) in try client.resumeCharging() }
    }

    /// [LAW:one-source-of-truth] Read fresh: the user approves or revokes in System Settings at any time.
    func status() -> SMAppService.Status { SMAppService.daemon(plistName: plistName).status }

    /// [LAW:single-enforcer] Every call comes after the registration's steps ahead of it, so none meets a service not
    /// registered yet, or a job half repaired.
    private func explained<Value>(_ call: () throws(HelperCallError) -> Value) throws(HelperUseFailure) -> Value {
        registration.waitForSteps()
        return try Self.explained(call, status: status, helperFile: registration.helperFile, reconcile: registration.reconcile(after:))
    }

    /// [LAW:effects-at-boundaries] Runs `call`; only a failed call reads `status` and `helperFile`, once each, and the
    /// failure carries both. `reconcile` hears the failure before the caller does, and returns at once.
    static func explained<Value>(_ call: () throws(HelperCallError) -> Value, status: () -> SMAppService.Status,
                                 helperFile: () -> HelperFile, reconcile: (HelperUseFailure) -> Void) throws(HelperUseFailure) -> Value {
        do { return try call() } catch {
            let failure = HelperUseFailure(call: error, status: status(), helperFile: helperFile())
            reconcile(failure)
            throw failure
        }
    }
}
