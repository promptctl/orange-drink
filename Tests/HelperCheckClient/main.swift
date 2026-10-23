import Foundation

// HelperCheckClient SERVICE: calls the helper at SERVICE once, the way the app does, and exits 0 with its
// identity, 1 with the error that ended the connection, or 2 when nothing came back in time. HelperLive runs
// it as built and re-signed, to see whom the helper refuses. The first line is always this process's pid,
// which the helper's log names when it accepts a connection.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: HelperCheckClient MACH-SERVICE\n".utf8))
    exit(64)
}
print("pid \(getpid())")
do {
    let identity = try HelperClient(service: CommandLine.arguments[1]).identity(within: 10)
    print("identity \(identity.executable) euid \(identity.euid)")
    exit(0)
} catch {
    print(error.description)
    switch error {
    case .connection: exit(1)
    case .noReply: exit(2)
    }
}
