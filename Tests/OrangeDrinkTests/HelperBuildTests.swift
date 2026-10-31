import Foundation
import Security
import Testing
@testable import OrangeDrink

/// [LAW:verifiable-goals] The built app carries its helper in the one shape launchd runs: a plist naming
/// this copy's own label, and a helper signed by the app's team, with the Hardened Runtime and no
/// entitlements. With the entitlements Xcode adds to a tool, launchd refuses the helper
/// (orange-admin-helper-b2q.qm0, cmt-4bc4dac4 §1). Every `make test` checks it, with no person needed.
struct HelperBuildTests {
    let app = Bundle.main
    let daemon: LaunchDaemon
    let identifier: String

    init() throws {
        daemon = try LaunchDaemon(in: app)
        identifier = try #require(app.bundleIdentifier)
    }

    var helper: URL { app.bundleURL.appending(path: daemon.program) }

    @Test func launchdPlistNamesThisCopysHelper() throws {
        // The Makefile's copy tag reached the build: neither the shipped label nor the `.xcode` one.
        let pattern = try Regex("\(NSRegularExpression.escapedPattern(for: identifier))\\.Helper\\.[0-9a-f]{8}\\.Debug")
        #expect(daemon.label.wholeMatch(of: pattern) != nil, "label \(daemon.label)")
        #expect(daemon.plistName == "\(daemon.label).plist")
        let plistURL = app.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(daemon.plistName)")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [identifier])
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test func helperIsSignedToServeOnlyThisApp() throws {
        let signing = try helperSigning()
        let signer = try Signer(signingInformation: signing)
        let team = try #require(try SigningInformation.ofSelf()[kSecCodeInfoTeamIdentifier as String] as? String)
        #expect(signer.team == team)
        #expect(signer.service == daemon.label)
        #expect(signer.app == identifier)
        #expect(signer.admitsDebuggableCallers, "a Debug helper admits its Debug app")
        #expect(signer.callerRequirement == "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\"")

        let codeFlags = try #require(signing[kSecCodeInfoFlags as String] as? UInt32)
        #expect(SecCodeSignatureFlags(rawValue: codeFlags).contains(.runtime))
        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        #expect(entitlements.isEmpty, "the helper carries entitlements: \(entitlements)")
        #expect(signing[kSecCodeInfoIdentifier as String] as? String == signer.service)
    }

    /// The two forms of the caller requirement, judged by Security against this test host as it runs: the
    /// team's Debug build of the app, which carries get-task-allow. A Release helper's form refuses it.
    @Test func releaseHelpersRefuseADebuggableApp() throws {
        var signing = try helperSigning()
        var plist = try #require(signing[kSecCodeInfoPList as String] as? [String: Any])
        let debug = try Signer(signingInformation: signing)
        plist["OrangeDrinkAdmitsDebuggableCallers"] = "NO"
        signing[kSecCodeInfoPList as String] = plist
        let release = try Signer(signingInformation: signing)
        #expect(release.callerRequirement == debug.callerRequirement + " and !entitlement[\"com.apple.security.get-task-allow\"]")
        #expect(try Self.selfMeets(debug.callerRequirement) == errSecSuccess)
        #expect(try Self.selfMeets(release.callerRequirement) == errSecCSReqFailed)
    }

    @Test func recordLinesSayWhatHappened() {
        typealias Registration = HelperRegistration
        let refusal = "SMAppServiceErrorDomain 1 Operation not permitted"
        let registered = Registration.Outcome(refusal: nil, status: "enabled", attempts: 3, elapsed: .milliseconds(1042))
        let refused = Registration.Outcome(refusal: refusal, status: "requiresApproval", attempts: 1, elapsed: .milliseconds(9))
        #expect(Registration.Event.launched(registered).line == "helper registration: registered; status enabled; attempt 3 after 1042 ms")
        #expect(Registration.Event.launched(refused).line == "helper registration: refused (\(refusal)); status requiresApproval; attempt 1 after 9 ms")
        let older = Registration.Handshake.otherCode(executable: "/Old/Helper")
        #expect(Registration.Event.reregistered(registered).line == "helper registration, a call found no job: registered; status enabled; attempt 3 after 1042 ms")
        #expect(Registration.Event.leftAlone(.own).line == "helper check: left the job alone; the helper answered")
        #expect(Registration.Event.leftAlone(.failed(.failed("x"))).line == "helper check: left the job alone; handshake the helper failed: x")
        #expect(Registration.Event.repaired(found: older, .unregistered(error: nil), registered, handshake: .own).line == "helper repair: other code answered (started from /Old/Helper); cleared ok; registered; status enabled; attempt 3 after 1042 ms; the helper answered")
        #expect(Registration.Event.repaired(found: older, .unregistered(error: nil), registered, handshake: older).line == "helper repair: other code answered (started from /Old/Helper); cleared ok; registered; status enabled; attempt 3 after 1042 ms; other code answered (started from /Old/Helper)")
        #expect(Registration.Event.kept(.heldBy(pids: [41, 42]), older).line == "helper check: kept for pid 41, 42; other code answered (started from /Old/Helper)")
        #expect(Registration.Event.exited(.unregistered(error: nil), status: "notRegistered").line
                == "helper at exit: cleared ok; status notRegistered")
        #expect(Registration.Event.exited(.heldBy(pids: [41]), status: "enabled").line
                == "helper at exit: kept for pid 41; status enabled")
        #expect(Registration.Event.exited(.holdersUnread(errno: 5), status: "enabled").line
                == "helper at exit: kept, process table unreadable (errno 5); status enabled")
    }

    /// A copy holds the record by the label it embeds, wherever it is: the shipped app's copies share one.
    @Test func aCopyHoldsTheRecordByItsLabel() throws {
        #expect(HelperRegistration.runsThisLabel(try #require(Processes.executablePath(of: getpid()))))
        #expect(try !HelperRegistration.otherHolders().contains(getpid()))

        let scratch = FileManager.default.temporaryDirectory.appending(path: "helper-holders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func copy(_ name: String, label: String?) throws -> String {
            let contents = scratch.appending(path: "\(name)/OrangeDrink.app/Contents")
            let executable = contents.appending(path: "MacOS/\(try #require(app.executableURL?.lastPathComponent))")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: executable)
            if let label {
                let daemons = contents.appending(path: "Library/LaunchDaemons")
                try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
                let plist: [String: Any] = ["Label": label, "MachServices": [label: true], "BundleProgram": daemon.program]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: daemons.appending(path: "\(label).plist"))
            }
            return executable.path
        }
        #expect(HelperRegistration.runsThisLabel(try copy("same", label: daemon.label)))
        #expect(!HelperRegistration.runsThisLabel(try copy("other", label: daemon.label + ".other")))
        #expect(!HelperRegistration.runsThisLabel(try copy("none", label: nil)))
        #expect(!HelperRegistration.runsThisLabel("/usr/bin/true"))
    }

    func helperSigning() throws -> [String: Any] {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess)
        return try SigningInformation.of(try #require(code), flags: kSecCSSigningInformation | kSecCSRequirementInformation)
    }

    /// A newer copy asks this of an older helper, so a change here leaves it unable to tell what answers. This stops
    /// compiling if the reply's shape changes; the wire's name for the call is the selector.
    @Test func theHandshakeStaysTheCallAnOlderHelperAnswers() {
        let _: (PrivilegedHelper, @escaping @Sendable (String, UInt32, Data) -> Void) -> Void = { $0.identity(reply: $1) }
        #expect(NSStringFromSelector(#selector(PrivilegedHelper.identity(reply:))) == "identityWithReply:")
    }

    /// The helper answers with the running reading and the app compares the file's, so one binary must read the same both ways.
    @Test func theRunningCodeAndItsFileHaveOneHash() throws {
        let running = try SigningInformation.cdhash(in: SigningInformation.ofSelf())
        let file = try SigningInformation.cdhash(in: SigningInformation.of(file: try #require(Bundle.main.executableURL)))
        #expect(running == file)
        #expect(try SigningInformation.cdhash(in: helperSigning()) == HelperRegistration.embeddedCDHash)
        #expect(HelperRegistration.embeddedCDHash != running)
    }

    /// Whether this running process meets a requirement, as the helper's listener asks of a caller.
    static func selfMeets(_ text: String) throws -> OSStatus {
        var parsed: SecRequirement?
        try #require(SecRequirementCreateWithString(text as CFString, [], &parsed) == errSecSuccess, "\(text)")
        let requirement = try #require(parsed)
        var me: SecCode?
        try #require(SecCodeCopySelf([], &me) == errSecSuccess)
        let code = try #require(me)
        return SecCodeCheckValidity(code, [], requirement)
    }
}
