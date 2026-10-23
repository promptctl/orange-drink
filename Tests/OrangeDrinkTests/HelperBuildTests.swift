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

    @Test func registrationLineSaysWhatHappened() {
        let refusal = "SMAppServiceErrorDomain 1 Operation not permitted"
        #expect(HelperRegistration(before: .unregistered(error: nil), outcome: .registered(status: "enabled")).line
                == "helper registration: cleared ok; registered; status enabled")
        #expect(HelperRegistration(before: .unregistered(error: refusal), outcome: .refused(error: refusal, status: "requiresApproval")).line
                == "helper registration: cleared \(refusal); refused (\(refusal)); status requiresApproval")
        #expect(HelperRegistration(before: .heldBy(pids: [41, 42]), outcome: .registered(status: "enabled")).line
                == "helper registration: kept for pid 41, 42; registered; status enabled")
    }

    func helperSigning() throws -> [String: Any] {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess)
        return try SigningInformation.of(try #require(code), flags: kSecCSSigningInformation | kSecCSRequirementInformation)
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
