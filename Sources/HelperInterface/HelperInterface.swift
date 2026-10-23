import Foundation
import os
import Security

/// The privileged helper's XPC interface. [LAW:single-enforcer] The helper's listener admits only the app
/// (see `Signer.callerRequirement`), so nothing here checks the caller again.
@objc protocol PrivilegedHelper {
    /// The connection's handshake: the helper's executable path and its effective user id. A reply proves the
    /// helper accepted the caller, runs as root, and is the copy inside the app the caller expected.
    func identity(reply: @escaping @Sendable (String, UInt32) -> Void)
}

struct HelperFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The launchd plist an app embeds for its helper. [LAW:one-source-of-truth] project.yml writes it from
/// HELPER_LABEL; the app and the check client read the label back from here and never spell it.
struct LaunchDaemon {
    let plistName: String
    let label: String
    /// The helper's path inside the app, its `BundleProgram`.
    let program: String

    /// [LAW:parse-dont-validate] The bundle's one plist, or a failure naming what was found instead.
    init(in app: Bundle) throws(HelperFailure) {
        let directory = app.bundleURL.appending(path: "Contents/Library/LaunchDaemons")
        let plists: [URL]
        do { plists = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) } catch {
            throw HelperFailure("no launchd plist directory at \(directory.path): \(error)")
        }
        guard plists.count == 1, let plist = plists.first else { throw HelperFailure("expected one launchd plist in \(directory.path), found \(plists.map(\.lastPathComponent))") }
        let contents: [String: Any]?
        do { contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] } catch {
            throw HelperFailure("\(plist.path) is not a property list: \(error)")
        }
        guard let label = contents?["Label"] as? String, let services = contents?["MachServices"] as? [String: Any], services.keys.sorted() == [label],
              let program = contents?["BundleProgram"] as? String else {
            throw HelperFailure("\(plist.path) needs a Label, exactly that one MachServices entry, and a BundleProgram")
        }
        plistName = plist.lastPathComponent
        self.label = label
        self.program = program
    }
}

/// A signature's signing information: where the helper's identity and its rule for callers are read from.
enum SigningInformation {
    static func of(_ code: SecStaticCode, flags: UInt32 = kSecCSSigningInformation) throws(HelperFailure) -> [String: Any] {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: flags), &info)
        guard status == errSecSuccess, let info = info as? [String: Any] else { throw HelperFailure("no signing information: OSStatus \(status)") }
        return info
    }

    /// The running process's own, read from the running code rather than the file on disk, so a file
    /// replaced after launch cannot change it. A running SecCode is accepted wherever a SecStaticCode is;
    /// Swift keeps the two types apart, hence the cast.
    static func ofSelf(flags: UInt32 = kSecCSSigningInformation) throws(HelperFailure) -> [String: Any] {
        var me: SecCode?
        let status = SecCodeCopySelf([], &me)
        guard status == errSecSuccess, let me else { throw HelperFailure("SecCodeCopySelf: OSStatus \(status)") }
        return try of(unsafeBitCast(me, to: SecStaticCode.self), flags: flags)
    }
}

/// What a signed helper says about itself: the facts its caller requirement is built from.
struct Signer: Equatable {
    let team: String
    /// The helper's Mach service, which is its launchd label and its bundle identifier.
    let service: String
    /// The bundle identifier of the one app the helper serves.
    let app: String
    /// Whether a caller may carry get-task-allow, which lets other code of the same user attach to it and
    /// act through it. Only a Debug helper admits one, because its Debug app carries it.
    let admitsDebuggableCallers: Bool

    /// [LAW:one-source-of-truth] Every fact comes from one signature: the team, and the Info.plist bound
    /// into it, never a file read off disk. [LAW:parse-dont-validate] A helper without a team, ad hoc for
    /// instance, has no requirement to enforce, so it has no `Signer` at all.
    init(signingInformation info: [String: Any]) throws(HelperFailure) {
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { throw HelperFailure("the helper's signature has no team") }
        guard let plist = info[kSecCodeInfoPList as String] as? [String: Any] else { throw HelperFailure("the helper's signature binds no Info.plist") }
        guard let service = plist["CFBundleIdentifier"] as? String, !service.isEmpty,
              let app = plist["OrangeDrinkAppIdentifier"] as? String, !app.isEmpty,
              let admits = plist["OrangeDrinkAdmitsDebuggableCallers"] as? String, ["YES", "NO"].contains(admits) else {
            throw HelperFailure("the helper's Info.plist lacks CFBundleIdentifier, OrangeDrinkAppIdentifier, or a YES/NO OrangeDrinkAdmitsDebuggableCallers: \(plist)")
        }
        self.team = team
        self.service = service
        self.app = app
        admitsDebuggableCallers = admits == "YES"
    }

    /// Code Apple's CA issued to this helper's own team, carrying the app's identifier, and, outside Debug,
    /// not debuggable. A rebuild leaves it unchanged, and a process that is not the team's build of the app
    /// cannot meet it.
    var callerRequirement: String {
        let teamBuildOfTheApp = "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
        return admitsDebuggableCallers ? teamBuildOfTheApp : teamBuildOfTheApp + " and !entitlement[\"com.apple.security.get-task-allow\"]"
    }
}

struct HelperIdentity: Equatable, Sendable {
    let executable: String
    let euid: UInt32
}

enum HelperCallError: Error, CustomStringConvertible, Equatable {
    /// The connection ended without a reply. [LAW:no-silent-failure] A refused caller sees only
    /// NSCocoaErrorDomain 4097, as an unreachable helper would; the helper's log tells them apart.
    case connection(domain: String, code: Int, description: String)
    /// Neither a reply nor an error in time: launchd may have refused or wedged the job.
    case noReply(seconds: Int, service: String)

    var description: String {
        switch self {
        case .connection(let domain, let code, let description): "call failed: domain=\(domain) code=\(code) \(description)"
        case .noReply(let seconds, let service):
            "no reply in \(seconds) s: launchd may have refused or wedged the job; see `launchctl print system/\(service)` (last exit reason)"
        }
    }
}

/// Calls the helper the way the app does. One connection per call, so a call never holds the helper alive.
struct HelperClient {
    let service: String

    func identity(within seconds: Int) throws(HelperCallError) -> HelperIdentity {
        let connection = NSXPCConnection(machServiceName: service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelper.self)
        connection.resume()
        defer { connection.invalidate() }
        // The first of the reply and the error wins; the other, if it comes, is dropped.
        let result = OSAllocatedUnfairLock<Result<HelperIdentity, HelperCallError>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<HelperIdentity, HelperCallError>) -> Void = { outcome in
            result.withLock { if $0 == nil { $0 = outcome } }
            done.signal()
        }
        let helper = connection.remoteObjectProxyWithErrorHandler { error in
            let error = error as NSError
            finish(.failure(.connection(domain: error.domain, code: error.code, description: error.localizedDescription)))
        } as! PrivilegedHelper
        helper.identity { executable, euid in finish(.success(HelperIdentity(executable: executable, euid: euid))) }
        guard done.wait(timeout: .now() + .seconds(seconds)) == .success, let outcome = result.withLock({ $0 }) else {
            throw .noReply(seconds: seconds, service: service)
        }
        return try outcome.get()
    }
}
