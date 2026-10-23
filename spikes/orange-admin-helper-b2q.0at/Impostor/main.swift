import Foundation

// Different code from the app; run.sh signs it ad hoc with the app's identifier, which any local
// process can do. Impostor SERVICE calls the helper the way the app does.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: Impostor MACH-SERVICE\n".utf8))
    exit(64)
}
print("impostor pid \(getpid())")
callHelper(service: CommandLine.arguments[1])
