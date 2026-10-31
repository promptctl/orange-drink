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

        // The helper's log separates a refusal from an unreachable helper. Its lines reach the store a moment
        // after the calls, so the log is read until they are there.
        func complete(_ log: String) -> Bool {
            log.components(separatedBy: Self.refusalLine).count - 1 >= refused.count && log.contains("accepted pid \(controlPid)")
        }
        var helperLog = try helperLogSinceStart()
        for _ in 0..<10 where !complete(helperLog) {
            Thread.sleep(forTimeInterval: 0.5)
            helperLog = try helperLogSinceStart()
        }
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
        #expect(lines.contains { $0.hasPrefix("helper registration: registered; status enabled;") }, "\(lines)")
    }

    /// What a launch does after a crash: the record and job are already there. An `unregister` first would have the
    /// `register` after it refused (orange-admin-helper-b2q.8ew).
    @Test func theLaunchsStepOverARunningJobLeavesItAnswering() throws {
        let status = SMAppService.daemon(plistName: "\(label).plist").status
        try #require(status == .enabled, "status \(status.name): approve OrangeDrink under System Settings › General › Login Items & Extensions › Allow in the Background")
        try expectAppAccepted()
        HelperRegistration.app.launch()
        HelperRegistration.app.waitForSteps()
        try expectAppAccepted()
    }

    /// Low Power Mode through the helper, read back from pmset on the source the Mac is on, from the system as the
    /// app reads it, and from the helper's log, with every other source left as it was; then put back
    /// (orange-admin-helper-b2q.0ld).
    @Test func setsLowPowerModeOnTheCurrentSourceOnly() throws {
        let status = SMAppService.daemon(plistName: "\(label).plist").status
        try #require(status == .enabled, "status \(status.name): approve OrangeDrink under System Settings › General › Login Items & Extensions › Allow in the Background")
        let key = try PowerModeKey(listing: Self.pmset("-g"))
        let source = try PmsetSource.current()
        let start = try Self.values(of: key)
        // The helper writes one bit, so it can put back only a 0 or a 1 (not High Power's 2).
        let was = try #require(start[source.heading], "pmset -g custom lists no \(source.heading) \(key.rawValue): \(start)")
        try #require(["0", "1"].contains(was), "\(source.heading) \(key.rawValue) is \(was); this check could not put that back, so it does not run")
        let wasOn = was == "1"
        let client = HelperClient(service: label)
        defer { try? client.setLowPowerMode(wasOn) }

        for on in [!wasOn, wasOn] {
            try client.setLowPowerMode(on)
            var expected = start
            expected[source.heading] = on ? "1" : "0"
            #expect(try Self.values(of: key) == expected, "\(key.rawValue) after asking for \(on) on \(source.heading)")
            // The system's own state, as the app reads it, can lag the reply (it did, turning off on this Mac), so it
            // is waited for.
            for _ in 0..<10 where ProcessInfo.processInfo.isLowPowerModeEnabled != on { Thread.sleep(forTimeInterval: 0.5) }
            #expect(ProcessInfo.processInfo.isLowPowerModeEnabled == on, "ProcessInfo after asking for \(on)")
        }

        let lines = [!wasOn, wasOn].map { LowPowerModeWrite.line($0, peer: getpid(), .success(key.arguments(on: $0, source: source))) }
        var helperLog = try helperLogSinceStart()
        for _ in 0..<10 where !lines.allSatisfy(helperLog.contains) {
            Thread.sleep(forTimeInterval: 0.5)
            helperLog = try helperLogSinceStart()
        }
        for line in lines { #expect(helperLog.contains(line), "helper log:\n\(helperLog)") }
    }

    static func pmset(_ arguments: String...) throws -> String {
        let result = try ChildProcess.run("/usr/bin/pmset", arguments)
        try #require(result.status == 0, "pmset \(arguments): \(result.transcript)")
        return result.text
    }

    /// The key's value under each power source's heading in `pmset -g custom`.
    static func values(of key: PowerModeKey) throws -> [String: String] {
        var heading = "", values: [String: String] = [:]
        for line in try pmset("-g", "custom").split(separator: "\n") {
            let fields = line.split(separator: " ")
            if !line.hasPrefix(" ") { heading = String(line) }
            if fields.first == Substring(key.rawValue), let value = fields.dropFirst().first { values[heading] = String(value) }
        }
        return values
    }

    func expectAppAccepted() throws {
        let identity = try HelperClient(service: label).identity()
        #expect(identity.euid == 0)
        #expect(URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath().path == helperPath, "the helper that answered is \(identity.executable)")
    }

    func copy(_ executable: URL, to directory: URL, as name: String) throws -> URL {
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: executable, to: destination)
        return destination
    }

    /// One call from a HelperCheckClient build, which has a deadline of its own; the runner's is twice it.
    func call(_ caller: URL) throws -> ChildProcess { try ChildProcess.run(caller.path, [label], deadline: TimeInterval(2 * HelperClient.deadline)) }

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

/// A job launchd will not run, repaired by what the app does when a call finds it, on the real background task
/// management and launchd. Run alone by `make helper-repair-check`: it re-signs this build's helper for a moment, which
/// HelperBuildTests, reading the same file, could otherwise meet.
///
/// [LAW:verifiable-goals] launchd refuses a helper re-signed ad hoc, and goes on refusing once the good helper is back
/// (orange-admin-helper-b2q.qm0, cmt-4bc4dac4 §5). The status still reads enabled, so only the reply tells.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HELPER_REPAIR_CHECK"] != nil, "run by make helper-repair-check once OrangeDrink is approved"))
struct HelperRepairLive {
    @Test(.timeLimit(.minutes(2))) func aJobLaunchdWillNotRunIsRepaired() async throws {
        let daemon = try LaunchDaemon(in: .main)
        let helper = Bundle.main.bundleURL.appending(path: daemon.program).resolvingSymlinksInPath()
        let client = HelperClient(service: daemon.label)
        let status = SMAppService.daemon(plistName: daemon.plistName).status
        try #require(status == .enabled, "status \(status.name): approve OrangeDrink under System Settings › General › Login Items & Extensions › Allow in the Background")
        try #require(Self.reply(client) == nil, "the helper does not answer before the check starts")

        let log = try BatteryLog(category: "helper")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "helper-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let good = scratch.appending(path: helper.lastPathComponent)
        try FileManager.default.copyItem(at: helper, to: good)
        // A new file in its place, so the kernel holds no verdict on the re-signed one.
        func restore() throws {
            let incoming = helper.appendingPathExtension("good")
            try FileManager.default.copyItem(at: good, to: incoming)
            guard rename(incoming.path, helper.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        var restored = false
        defer {
            do {
                if !restored { try restore() }
                try FileManager.default.removeItem(at: scratch)
            } catch { Issue.record("the good helper was not put back: \(error)") }
        }

        let signed = try ChildProcess.run("/usr/bin/codesign", ["-f", "-s", "-", helper.path])
        try #require(signed.status == 0, "codesign: \(signed.transcript)")
        // The running helper ends on its file changing, so the replies stop once it has gone.
        let end = ContinuousClock.now + .seconds(30)
        var refusal = Self.reply(client)
        // A call in flight as the helper ends fails as a connection error, which is not launchd refusing it yet.
        while ContinuousClock.now < end {
            if case .noReply = refusal { break }
            refusal = Self.reply(client)
        }
        guard case .noReply = refusal else {
            Issue.record("launchd ran or refused the re-signed helper unexpectedly: \(String(describing: refusal))")
            return
        }
        // A second refused spawn: after only one, launchd simply ran the good helper once it was back.
        try #require(Self.reply(client) != nil, "launchd ran the re-signed helper")
        try restore()
        restored = true

        // The good helper is back and launchd still will not run it: this is the wedge, with the status as it was.
        #expect(SMAppService.daemon(plistName: daemon.plistName).status == .enabled)
        var failure: HelperUseFailure?
        do throws(HelperUseFailure) { try HelperAccess(daemon: daemon).resumeCharging() } catch { failure = error }
        try #require(failure?.cause == .notAnswering, "the call ended in \(String(describing: failure))")

        HelperRegistration.app.waitForSteps()
        let identity = try client.identity()
        #expect(identity.euid == 0)
        #expect(URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath() == helper)
        #expect(try await log.logged("helper repair: "))
        // [LAW:verifiable-goals] Cleared, or a running copy with this label kept the job and nothing here ran. A second
        // attempt or later, or `register` was never refused and the refusal window this exists to cross was not met.
        let repair = try #require(try log.messages().first { $0.hasPrefix("helper repair: ") })
        let match = try #require(repair.firstMatch(of: #/^helper repair: cleared ok; registered; status enabled; attempt (\d+) after \d+ ms; the helper answered$/#), "\(repair)")
        #expect(try #require(Int(match.1)) > 1, "\(repair)")
    }

    private static func reply(_ client: HelperClient) -> HelperCallError? {
        do throws(HelperCallError) { _ = try client.identity(); return nil } catch { return error }
    }
}
