import Foundation

// Different code from the app; run.sh signs it ad hoc with the app's identifier, which any local
// process can do. Impostor APP calls the helper the way the app at APP does, finding its Mach
// service in that app's launchd plist.
guard CommandLine.arguments.count == 2, let app = Bundle(path: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: Impostor PATH-TO-HelperSpike.app\n".utf8))
    exit(64)
}
print("impostor pid \(getpid())")
do { callHelper(service: try LaunchDaemon(in: app).machService) } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
