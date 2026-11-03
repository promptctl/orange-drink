// Opens a new, hidden instance of Terminal and has it run a shell command, so the command's process is Terminal's
// and no window reaches the screen. Run by `make app-energy-check`; usage: hidden-terminal <command>.
// Prints the instance's pid; killing it hangs up the command's tty, which ends the command.
// A second instance, not the person's Terminal: windows show or hide with their app, and hiding the person's
// Terminal would hide their windows too. It ignores saved state so it neither restores nor overwrites theirs.
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("hidden-terminal: \(message)\n".data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: hidden-terminal <command>") }
guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { fail("no Terminal") }
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.hides = true
configuration.activates = false
configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
// The handler runs on another queue; the semaphore both waits for it and publishes `opened` to this thread.
var opened: Result<NSRunningApplication, Error>?
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: terminal, configuration: configuration) { app, error in
    opened = app.map { .success($0) } ?? .failure(error ?? CocoaError(.featureUnsupported))
    done.signal()
}
done.wait()
let app: NSRunningApplication
do { app = try opened!.get() } catch { fail("Terminal did not open: \(error)") }

// Terminal's `do script` ('core'/'dosc'), sent to this instance's pid: a script naming Terminal reaches the person's.
let doScript = NSAppleEventDescriptor(eventClass: AEEventClass(0x636F_7265), eventID: AEEventID(0x646F_7363),
                                      targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
                                      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
doScript.setParam(NSAppleEventDescriptor(string: CommandLine.arguments[1]), forKeyword: AEKeyword(keyDirectObject))
// Terminal can answer with an error in its reply rather than fail the send.
do {
    let reply = try doScript.sendEvent(options: [.waitForReply], timeout: 30)
    if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(code))
    }
} catch {
    app.forceTerminate()
    fail("Terminal did not run the command: \(error)")
}
print(app.processIdentifier)
