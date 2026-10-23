import Foundation
import OSLog
import Security
import ServiceManagement
import Testing
@testable import OrangeDrink

private final class TestBundle {}

/// The privileged helper's check on a real Mac, run by `make helper-check` once OrangeDrink is approved
/// under Login Items. [LAW:verifiable-goals] Each claim rests on something read back: an exit status with an
/// error's domain and code, a euid, a path, or a line in the helper's log. Every call has a deadline, since a
/// job launchd refused shows up as a call that never answers (orange-admin-helper-b2q.qm0, cmt-4bc4dac4).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HELPER_CHECK"] != nil, "run by make helper-check once OrangeDrink is approved"))
struct HelperLive {
    static let deadline = 10
    static let refusalLine = "Dropping check-in message due to code signing requirement"

    let label: String
    let identifier: String
    /// This copy's helper, as launchd runs it: the plist's BundleProgram inside the test host, which is the app.
    let helperPath: String
    let started = Date()

    init() throws {
        let daemon = try LaunchDaemon(in: .main)
        label = daemon.label
        identifier = try #require(Bundle.main.bundleIdentifier)
        helperPath = Bundle.main.bundleURL.appending(path: daemon.program).resolvingSymlinksInPath().path
    }

    @Test func acceptsOnlyTheApp() throws {
        let status = SMAppService.daemon(plistName: "\(label).plist").status
        try #require(status == .enabled, "status \(status.name): approve OrangeDrink under System Settings › General › Login Items & Extensions › Allow in the Background")

        // The app: this test host. The label is this copy's alone, so only a byte copy of this build at
        // another path could answer instead, and the path says so.
        try expectAppAccepted()

        let client = try #require(Bundle(for: TestBundle.self).url(forAuxiliaryExecutable: "HelperCheckClient"))
        let scratch = FileManager.default.temporaryDirectory.appending(path: "helper-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Refused: the team's code under its own identifier, then other code wearing the app's identifier
        // with no team, which is what a re-signed copy of the app shows a signature check. After each, the
        // app is still accepted, so the refusal came from a reachable helper.
        let adHoc = try copy(client, to: scratch, as: "ad-hoc")
        try codesign("-f", "-s", "-", "-i", identifier, adHoc.path)
        let refused = [client, adHoc]
        for caller in refused {
            let call = try call(caller)
            #expect(call.status == 1, "\(caller.lastPathComponent): \(call.transcript)")
            #expect(call.text.contains("domain=NSCocoaErrorDomain code=4097"), "\(caller.lastPathComponent): \(call.transcript)")
            try expectAppAccepted()
        }

        // Accepted: other code, signed by the team as the app. The requirement is the team and the
        // identifier, not one build's hash, which is why it survives a rebuild.
        let teamSigned = try copy(client, to: scratch, as: "team-signed")
        try codesign("-f", "-s", try Self.ownSigningIdentity(), "-o", "runtime", "-i", identifier, teamSigned.path)
        let control = try call(teamSigned)
        #expect(control.status == 0, "team-signed: \(control.transcript)")
        let controlPid = try #require(control.text.firstMatch(of: /pid (\d+)/)?.1, "team-signed printed no pid: \(control.transcript)")

        // The helper's log separates a refusal from an unreachable helper.
        let helperLog = try helperLogSinceStart()
        #expect(helperLog.components(separatedBy: Self.refusalLine).count - 1 >= refused.count, "helper log:\n\(helperLog)")
        #expect(helperLog.contains("accepted pid \(controlPid)"), "helper log:\n\(helperLog)")

        // This launch's registration, as the app logged it. It runs off the main thread, so it is waited for.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var lines: [String] = []
        for _ in 0..<50 {
            lines = try store.getEntries(matching: NSPredicate(format: "subsystem == %@ AND category == %@", IOKitBattery.logSubsystem, "helper"))
                .map(\.composedMessage)
            if lines.contains(where: { $0.hasPrefix("helper registration: ") }) { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        #expect(lines.contains { $0.hasPrefix("helper registration: ") && $0.hasSuffix("; registered; status enabled") }, "\(lines)")
    }

    func expectAppAccepted() throws {
        let identity = try HelperClient(service: label).identity(within: Self.deadline)
        #expect(identity.euid == 0)
        #expect(URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath().path == helperPath, "the helper that answered is \(identity.executable)")
    }

    func copy(_ executable: URL, to directory: URL, as name: String) throws -> URL {
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: executable, to: destination)
        return destination
    }

    /// One call from a HelperCheckClient build, which has a deadline of its own; the runner's is twice it.
    func call(_ caller: URL) throws -> ChildProcess { try ChildProcess.run(caller.path, [label], deadline: 2 * Self.deadline) }

    func codesign(_ arguments: String...) throws {
        let result = try ChildProcess.run("/usr/bin/codesign", arguments)
        try #require(result.status == 0, "codesign \(arguments): \(result.transcript)")
    }

    /// This copy's helper's log since the test started; every copy's helper has the same name, so the
    /// predicate is the path.
    func helperLogSinceStart() throws -> String {
        let start = DateFormatter()
        start.locale = Locale(identifier: "en_US_POSIX")
        start.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let result = try ChildProcess.run("/usr/bin/log", ["show", "--start", start.string(from: started.addingTimeInterval(-1)), "--style", "compact",
                                                           "--predicate", "processImagePath == \"\(helperPath)\""])
        try #require(result.status == 0, "log show: \(result.transcript)")
        return result.text
    }

    /// The name of the certificate this test host is signed with, so the control is signed by the same team.
    static func ownSigningIdentity() throws -> String {
        let certificates = try #require(try SigningInformation.ofSelf()[kSecCodeInfoCertificates as String] as? [SecCertificate])
        let leaf = try #require(certificates.first)
        return try #require(SecCertificateCopySubjectSummary(leaf) as String?)
    }
}
