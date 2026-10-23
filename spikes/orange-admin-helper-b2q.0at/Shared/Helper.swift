import Foundation
import Security

/// The helper's one call. The reply is lines of `name: value`, printed as they arrive.
@objc protocol HelperProtocol {
    func whoAmI(reply: @escaping @Sendable (String) -> Void)
}

/// The launchd plist the app embeds. [LAW:one-source-of-truth] Its file name, Label, and Mach
/// service are written there once; the app and the helper both read them back from the app bundle.
struct LaunchDaemon {
    let plist: URL

    init(in app: Bundle) throws {
        let directory = app.bundleURL.appending(path: "Contents/Library/LaunchDaemons")
        let plists = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard plists.count == 1, let plist = plists.first else { throw Failure("expected one launchd plist in \(directory.path), found \(plists)") }
        self.plist = plist
    }

    var machService: String {
        get throws {
            let contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            guard let services = contents?["MachServices"] as? [String: Any], services.count == 1, let name = services.keys.first else {
                throw Failure("expected one MachServices entry in \(plist.path)")
            }
            return name
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// What a code signature says: identifier, team, and cdhash.
func signing(of code: SecStaticCode) -> String {
    var info: CFDictionary?
    let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    guard status == errSecSuccess, let info = info as? [String: Any] else { return "unreadable (OSStatus \(status))" }
    let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? "none"
    let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
    let cdhash = (info[kSecCodeInfoUnique as String] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "none"
    return "identifier=\(identifier) team=\(team) cdhash=\(cdhash)"
}

/// Calls the helper once and exits: 0 with its reply, 1 with the error that ended the connection.
/// [LAW:no-silent-failure] A refusal reaches the caller as NSCocoaErrorDomain 4097, the same error as a
/// helper that went away; only the helper's log ("Dropping check-in message due to code signing
/// requirement") tells them apart.
func callHelper(service: String) -> Never {
    let connection = NSXPCConnection(machServiceName: service, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    connection.resume()
    let helper = connection.remoteObjectProxyWithErrorHandler { error in
        let error = error as NSError
        FileHandle.standardError.write(Data("call failed: domain=\(error.domain) code=\(error.code) \(error.localizedDescription)\n".utf8))
        exit(1)
    } as! HelperProtocol
    helper.whoAmI { reply in
        print(reply)
        exit(0)
    }
    dispatchMain()
}
