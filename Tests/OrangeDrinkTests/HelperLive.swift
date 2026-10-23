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
    let started = Date()

    init() throws {
        label = try LaunchDaemon(in: .main).label
        identifier = try #require(Bundle.main.bundleIdentifier)
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
        var refused = 0
        for caller in [client, adHoc] {
            let call = try run(caller, label)
            #expect(call.status == 1, "\(caller.lastPathComponent): \(call.output)")
            #expect(call.output.contains("domain=NSCocoaErrorDomain code=4097"), "\(caller.lastPathComponent): \(call.output)")
            refused += 1
            try expectAppAccepted()
        }

        // Accepted: other code, signed by the team as the app. The requirement is the team and the
        // identifier, not one build's hash, which is why it survives a rebuild.
        let teamSigned = try copy(client, to: scratch, as: "team-signed")
        try codesign("-f", "-s", try Self.ownSigningIdentity(), "-o", "runtime", "-i", identifier, teamSigned.path)
        let control = try run(teamSigned, label)
        #expect(control.status == 0, "team-signed: \(control.output)")
        let controlPid = try #require(control.output.firstMatch(of: /pid (\d+)/)?.1, "team-signed printed no pid: \(control.output)")

        // The helper's log separates a refusal from an unreachable helper.
        let helperLog = try helperLogSinceStart()
        #expect(helperLog.components(separatedBy: Self.refusalLine).count - 1 >= refused, "helper log:\n\(helperLog)")
        #expect(helperLog.contains("accepted pid \(controlPid)"), "helper log:\n\(helperLog)")

        // This launch's registration, as the app logged it.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let lines = try store.getEntries(matching: NSPredicate(format: "subsystem == %@ AND category == %@", IOKitBattery.logSubsystem, "helper"))
            .map(\.composedMessage)
        #expect(lines.contains { $0.hasPrefix("helper registration: cleared ") && $0.hasSuffix("; registered; status enabled") }, "\(lines)")
    }

    func expectAppAccepted() throws {
        let identity = try HelperClient(service: label).identity(within: Self.deadline)
        #expect(identity.euid == 0)
        let own = Bundle.main.bundleURL.appending(path: "Contents/MacOS/OrangeDrinkHelper").resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath().path == own, "the helper that answered is \(identity.executable)")
    }

    func copy(_ executable: URL, to directory: URL, as name: String) throws -> URL {
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: executable, to: destination)
        return destination
    }

    func codesign(_ arguments: String...) throws {
        let result = try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments)
        try #require(result.status == 0, "codesign \(arguments): \(result.output)")
    }

    func helperLogSinceStart() throws -> String {
        let start = DateFormatter()
        start.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let result = try run(URL(fileURLWithPath: "/usr/bin/log"), ["show", "--start", start.string(from: started.addingTimeInterval(-1)), "--style", "compact",
                                                                  "--predicate", "process == \"OrangeDrinkHelper\""])
        try #require(result.status == 0, "log show: \(result.output)")
        return result.output
    }

    func run(_ executable: URL, _ arguments: String...) throws -> (status: Int32, output: String) { try run(executable, arguments) }

    /// Runs a process with stdout and stderr together, killed at twice the call deadline if still running.
    func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2 * Self.deadline), execute: killer)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, output)
    }

    /// The name of the certificate this test host is signed with, so the control is signed by the same team.
    static func ownSigningIdentity() throws -> String {
        var me: SecCode?
        try #require(SecCodeCopySelf([], &me) == errSecSuccess)
        let code = try #require(me)
        var info: CFDictionary?
        try #require(SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
        let certificates = try #require((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])
        let leaf = try #require(certificates.first)
        return try #require(SecCertificateCopySubjectSummary(leaf) as String?)
    }
}
