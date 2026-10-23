import Foundation
import ServiceManagement

// HelperSpike register|status|unregister|call. run.sh launches it with `open`, so BTM sees a GUI app;
// results go to stdout, failures to stderr, which run.sh treats as the failure.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

extension SMAppService.Status {
    var name: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

// Every exit path ends with this line: the app can exit before `open -W` attaches to it, so run.sh
// waits for the line rather than for `open`. Nonisolated, because exit() runs it on whichever thread
// called exit, the XPC reply's included; a closure here would inherit the main actor and trap there.
nonisolated func printEndOfRun() {
    print("-- end of run")
    fflush(stdout)
}
atexit(printEndOfRun)

let daemon: LaunchDaemon
do { daemon = try LaunchDaemon(in: .main) } catch { fail("\(error)") }
let service = SMAppService.daemon(plistName: daemon.plist.lastPathComponent)

switch CommandLine.arguments.dropFirst().first {
case "register":
    do { try service.register() } catch { fail("register failed: \(error as NSError)") }
    print("registered; status \(service.status.name)")
case "status":
    print("status \(service.status.name)")
case "unregister":
    do { try service.unregister() } catch { fail("unregister failed: \(error as NSError)") }
    print("unregistered; status \(service.status.name)")
case "call":
    print("app \(Bundle.main.bundlePath)")
    do { callHelper(service: try daemon.machService) } catch { fail("\(error)") }
case let other:
    fail("usage: HelperSpike register|status|unregister|call (got \(other ?? "nothing"))")
}
