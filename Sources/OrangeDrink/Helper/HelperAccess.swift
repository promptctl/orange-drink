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

    /// Whether the user can fix it by allowing the helper under Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    var description: String { "\(call.description) (helper status \(status.name))" }
}

/// [LAW:single-enforcer] The app's one way to the privileged helper: every helper-backed control calls through
/// here, and the client is private, so every failure arrives explained.
struct HelperAccess {
    private let client: HelperClient
    /// The daemon's plist, which names its SMAppService. The service is made at each read, since it is not
    /// Sendable and a control's write runs off the main actor.
    private let plistName: String

    init(daemon: LaunchDaemon) { self.init(service: daemon.label, plistName: daemon.plistName) }

    init(service: String, plistName: String) {
        client = HelperClient(service: service)
        self.plistName = plistName
    }

    func setLowPowerMode(_ on: Bool) throws(HelperUseFailure) {
        try Self.explained({ () throws(HelperCallError) in try client.setLowPowerMode(on) }, status: status)
    }

    func pauseCharging(lost: @escaping @Sendable (ObjectIdentifier) -> Void) throws(HelperUseFailure) -> ChargeLease {
        try Self.explained({ () throws(HelperCallError) in try client.pauseCharging(lost: lost) }, status: status)
    }

    func release(_ lease: ChargeLease) throws(HelperUseFailure) {
        try Self.explained({ () throws(HelperCallError) in try lease.release() }, status: status)
    }

    func resumeCharging() throws(HelperUseFailure) {
        try Self.explained({ () throws(HelperCallError) in try client.resumeCharging() }, status: status)
    }

    /// [LAW:one-source-of-truth] Read fresh: the user approves or revokes in System Settings at any time.
    func status() -> SMAppService.Status { SMAppService.daemon(plistName: plistName).status }

    /// [LAW:effects-at-boundaries] Runs `call`; only a failed call reads `status`, once, and the failure carries both.
    static func explained<Value>(_ call: () throws(HelperCallError) -> Value, status: () -> SMAppService.Status) throws(HelperUseFailure) -> Value {
        do { return try call() } catch { throw HelperUseFailure(call: error, status: status()) }
    }
}
