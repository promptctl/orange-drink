import Foundation
import Security
import Testing
@testable import OrangeDrink

/// [LAW:verifiable-goals] The built app carries its helper in the one shape launchd runs: a plist naming
/// this copy's own label, and a helper signed by the app's team, with the Hardened Runtime and no
/// entitlements. With the entitlements Xcode injects into a Debug build, launchd refuses the helper
/// (orange-admin-helper-b2q.qm0, cmt-4bc4dac4 §1). Every `make test` checks it, with no person needed.
struct HelperBuildTests {
    let app = Bundle.main
    var helper: URL { app.bundleURL.appending(path: "Contents/MacOS/OrangeDrinkHelper") }

    @Test func launchdPlistNamesThisCopysHelper() throws {
        let daemon = try LaunchDaemon(in: app)
        let identifier = try #require(app.bundleIdentifier)
        // The Makefile's copy tag reached the build: neither the shipped label nor the `.xcode` one.
        let pattern = try Regex("\(NSRegularExpression.escapedPattern(for: identifier))\\.Helper\\.[0-9a-f]{8}\\.Debug")
        #expect(daemon.label.wholeMatch(of: pattern) != nil, "label \(daemon.label)")
        #expect(daemon.plistName == "\(daemon.label).plist")
        let plistURL = app.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(daemon.plistName)")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/OrangeDrinkHelper")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [identifier])
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test func helperIsSignedToServeOnlyThisApp() throws {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess)
        let helperCode = try #require(code)
        let signer = try Signer(code: helperCode)
        let identifier = try #require(app.bundleIdentifier)
        let team = try Self.ownTeam()
        #expect(signer.team == team)
        #expect(signer.service == (try LaunchDaemon(in: app)).label)
        #expect(signer.app == identifier)
        #expect(signer.callerRequirement == "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\"")

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        try #require(SecCodeCopySigningInformation(helperCode, flags, &info) == errSecSuccess)
        let signing = try #require(info as? [String: Any])
        let codeFlags = try #require(signing[kSecCodeInfoFlags as String] as? UInt32)
        #expect(SecCodeSignatureFlags(rawValue: codeFlags).contains(.runtime))
        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        #expect(entitlements.isEmpty, "the helper carries entitlements: \(entitlements)")
        #expect(signing[kSecCodeInfoIdentifier as String] as? String == signer.service)
    }

    @Test func registrationLineSaysWhatHappened() {
        let refusal = "SMAppServiceErrorDomain 1 Operation not permitted"
        #expect(HelperRegistration(cleared: "ok", outcome: .registered(status: "enabled")).line
                == "helper registration: cleared ok; registered; status enabled")
        #expect(HelperRegistration(cleared: refusal, outcome: .refused(error: refusal, status: "requiresApproval")).line
                == "helper registration: cleared \(refusal); refused (\(refusal)); status requiresApproval")
    }

    /// The team of the running test host, which is the app.
    static func ownTeam() throws -> String {
        var me: SecCode?
        try #require(SecCodeCopySelf([], &me) == errSecSuccess)
        let code = try #require(me)
        var info: CFDictionary?
        try #require(SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
        return try #require((info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}
