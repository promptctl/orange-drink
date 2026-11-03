// The one recorder behind every hardware check in the Makefile, the checks that need a real Mac and a person at a cable.
// `run` runs a check's test and posts the outcome on the lit ticket the branch names, so a result never depends on
// someone copying it from the terminal. It reads nothing from the person: the test observes every fact it records (the
// Makefile says why). `status` says, for that ticket, whether each check's latest result still holds for HEAD, so a
// person is needed again only when the code changed.
//
// usage: hardware-check run <check> [--test <id> --bundle <xcresult>] --covers <path>... -- <command>...
//        hardware-check status (--check <check> <path>...)...
// A check with a --test is an xcodebuild run whose result bundle holds the test's outcome. One without is a script: it
// exits 0 when every reading held, and anything else is a fail, with the reason on the lines it prints as
// `» failure: <reason>`.
// run exits 0 only when the check passed and its result is on the ticket.
import Foundation

/// [LAW:one-source-of-truth] exception: printForTheRecord in Tests/OrangeDrinkTests/PrintForTheRecord.swift prints it.
let recordMark = "» "
/// [LAW:one-source-of-truth] exception: `fail` in scripts/vm-check-lib and scripts/release-helper-check.swift print it.
/// What follows a marked line's `» ` is the reason a script's reading did not hold, recorded as a failure.
let failureMark = "failure: "

enum CheckError: Error, CustomStringConvertible {
    case usage(String)
    case failed([String], status: Int32)
    case noResult(test: String, bundle: String)
    case skipped(test: String)
    case unknownResult(test: String, String)
    case malformedRecord(comment: String, String)
    case noTicket(String)
    case notBuilt(String)

    var description: String {
        switch self {
        case .usage(let detail): "\(detail)\nusage: hardware-check run <check> [--test <id> --bundle <xcresult>] --covers <path>... -- <command>...\n       hardware-check status (--check <check> <path>...)..."
        case .failed(let command, let status): "\(command.joined(separator: " ")) exited \(status)"
        case .noResult(let test, let bundle): "\(bundle) holds no result for \(test): the build failed or the test never ran; nothing was posted"
        case .skipped(let test): "\(test) was skipped, so it checked nothing: its TEST_RUNNER_ variable did not reach it; nothing was posted"
        case .unknownResult(let test, let result): "\(test) ended as \"\(result)\", which is not Passed or Failed"
        case .malformedRecord(let comment, let detail): "comment \(comment) starts as a hardware check record but \(detail)"
        case .noTicket(let branch): "the branch \(branch) names no lit ticket; hardware results are posted on the ticket the branch names"
        case .notBuilt(let path): "the covered path \(path) is not on disk, so the test cannot build it; nothing was run"
        }
    }
}

// MARK: - Processes

/// Runs a command to completion and returns its standard output, trimmed. Its standard error reaches the terminal, and
/// a non-zero exit throws.
@discardableResult
func capture(_ command: [String], environment: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = command
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let output = Pipe()
    process.standardOutput = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CheckError.failed(command, status: process.terminationStatus) }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Runs the check's command with its output shown as it arrives, and returns its exit status and the lines marked
/// for the record: the failure reasons a script gave, and the rest. Its stdin is /dev/null: a check takes nothing from
/// the person but their hands.
func stream(_ command: [String]) throws -> (status: Int32, printed: [String], said: [String]) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = command
    // xcodebuild buffers its output into a pipe unless told not to, which would hold back the person's instructions.
    process.environment = ProcessInfo.processInfo.environment.merging(["NSUnbufferedIO": "YES"]) { $1 }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    var pending = Data()
    var printed: [String] = []
    var said: [String] = []
    func take(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasPrefix(recordMark) else { return }
        // Told apart before trimming, so a reason of only whitespace is still a reason.
        let marked = String(text.dropFirst(recordMark.count))
        if marked.hasPrefix(failureMark) { said.append(String(marked.dropFirst(failureMark.count)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        else { printed.append(marked.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
        FileHandle.standardOutput.write(chunk)
        pending.append(chunk)
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            take(pending[pending.startIndex..<end])
            pending.removeSubrange(pending.startIndex...end)
        }
    }
    take(pending)
    process.waitUntilExit()
    return (process.terminationStatus, printed, said)
}

// MARK: - What a run covered

/// The git object id of each covered path in `tree`: a content hash that changes exactly when a file under the path
/// changes. A path the tree does not hold has no entry. [LAW:one-source-of-truth] run and status both hash through
/// here; they differ only in the tree they pass.
func objectIDs(of paths: [String], in tree: String) throws -> [String: String] {
    // One path per listing: given a path and another inside it, ls-tree descends and lists the outer one's children.
    try paths.reduce(into: [:]) { ids, path in
        let id = try capture(["git", "ls-tree", "--format=%(objectname)", tree, "--", path])
        ids[path] = id.isEmpty ? nil : id
    }
}

/// The covered paths as they are on disk, uncommitted and untracked files included, as a tree: the code the test is
/// about to build. Written through a scratch index under build/, so the real index is untouched.
func workingTree(_ paths: [String]) throws -> String {
    try FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
    let index = ["GIT_INDEX_FILE": FileManager.default.currentDirectoryPath + "/build/hardware-check.index"]
    try capture(["git", "read-tree", "HEAD"], environment: index)
    try capture(["git", "add", "--all", "--"] + paths, environment: index)
    return try capture(["git", "write-tree"], environment: index)
}

/// The ticket the current branch names. Branches here are ticket ids.
func ticket() throws -> String {
    let branch = try capture(["git", "symbolic-ref", "--short", "HEAD"])
    // lit exits 4, entity_not_found, when no ticket has the id.
    do { try capture(["lit", "show", branch, "--field", "id"]) } catch CheckError.failed(_, status: 4) { throw CheckError.noTicket(branch) }
    return branch
}

// MARK: - The record

/// What a check can put on the ticket. A skipped test checked nothing, so it is not a result: it would stand in
/// `status` over the last real one.
enum Outcome: String {
    case pass, fail

    init(xcresult: String, test: String) throws {
        switch xcresult {
        case "Passed": self = .pass
        case "Failed": self = .fail
        case "Skipped": throw CheckError.skipped(test: test)
        default: throw CheckError.unknownResult(test: test, xcresult)
        }
    }
}

struct TestNode: Decodable {
    let nodeType: String
    let name: String
    let nodeIdentifier: String?
    let result: String?
    let children: [TestNode]?

    var all: [TestNode] { [self] + (children ?? []).flatMap(\.all) }
}

/// The test's outcome and failure messages, from the result bundle: the bundle, not the exit status, says whether the
/// test ran at all, since a test whose TEST_RUNNER_ variable never reached it is skipped and still exits 0.
func outcome(of test: String, in bundle: String) throws -> (Outcome, failures: [String]) {
    let json = try capture(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle])
    struct Results: Decodable { let testNodes: [TestNode] }
    let nodes = try JSONDecoder().decode(Results.self, from: Data(json.utf8)).testNodes.flatMap(\.all)
    guard let node = nodes.first(where: { $0.nodeType == "Test Case" && $0.nodeIdentifier == test }),
          let result = node.result else { throw CheckError.noResult(test: test, bundle: bundle) }
    return (try Outcome(xcresult: result, test: test), node.all.filter { $0.nodeType == "Failure Message" }.map(\.name))
}

/// One comment, one `key: value` per line, so a person reads it and `Recorded` parses it.
struct Record {
    let check: String
    let outcome: Outcome
    let commit: String
    let covers: [(path: String, id: String)]
    /// Covered paths whose code on disk was not HEAD's when the test was built.
    let uncommitted: [String]
    let printed: [String]
    let failures: [String]

    var body: String {
        (["hardware check: \(check)", "result: \(outcome.rawValue)", "commit: \(commit)"]
            + uncommitted.map { "uncommitted: \($0)" }
            + covers.map { "covers: \($0.id) \($0.path)" }
            + printed.map { "printed: \($0)" }
            + failures.flatMap { $0.split(separator: "\n").map { "failure: \($0)" } }).joined(separator: "\n")
    }
}

/// A check's record as `status` reads it back from a comment.
struct Recorded {
    let outcome: Outcome
    let commit: String
    let covers: [String: String]
    let failures: [String]

    /// The record in a comment: nil when the comment is not one of `check`'s records (its first line is not
    /// `hardware check: <check>`), and an error naming the comment when it starts as one and does not parse.
    static func parse(_ comment: Comment, check: String) throws -> Recorded? {
        let lines = comment.body.split(separator: "\n").map(String.init)
        guard lines.first == "hardware check: \(check)" else { return nil }
        func values(_ key: String) -> [String] { lines.filter { $0.hasPrefix("\(key): ") }.map { String($0.dropFirst(key.count + 2)) } }
        func malformed(_ detail: String) -> CheckError { .malformedRecord(comment: comment.id, detail) }
        guard let result = values("result").first, let outcome = Outcome(rawValue: result) else { throw malformed("has no result: pass or fail") }
        guard let commit = values("commit").first else { throw malformed("has no commit") }
        let covers = try values("covers").map { line -> (String, String) in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw malformed("has a covers line that is not <object id> <path>: \(line)") }
            return (parts[1], parts[0])
        }
        guard !covers.isEmpty else { throw malformed("covers no paths") }
        return Recorded(outcome: outcome, commit: commit, covers: Dictionary(covers) { $1 }, failures: values("failure"))
    }
}

/// A lit comment, as `lit export` writes it.
struct Comment: Decodable {
    let id: String
    let issue_id: String
    let body: String
    let created_at: String
}

// MARK: - Commands

/// How a check's outcome is read: from a test's result bundle, or, for a script, from its exit status.
enum Judge {
    case test(String, bundle: String)
    case exitStatus
}

func run(check: String, judge: Judge, covers paths: [String], command: [String]) throws -> Int32 {
    // Everything the post needs that can fail is settled before the person is asked to do anything.
    let ticket = try ticket()
    let commit = try capture(["git", "rev-parse", "HEAD"])
    let built = try objectIDs(of: paths, in: try workingTree(paths))
    let covers = try paths.map { path in
        guard let id = built[path] else { throw CheckError.notBuilt(path) }
        return (path: path, id: id)
    }
    // A covered path HEAD does not hold is new on disk: uncommitted, like any other path whose code is not HEAD's.
    let committed = try objectIDs(of: paths, in: "HEAD")

    let (status, marked, said) = try stream(command)
    // A script says why a reading failed on a marked line that starts `failure: `. Those lines are a reason only under
    // a non-zero exit; from a command that exited 0 they are printed like the rest.
    let exited = status == 0 ? [] : said + ["\(command[0]) exited \(status)"]
    let printed = status == 0 ? marked + said.map { failureMark + $0 } : marked
    let (result, failures): (Outcome, [String])
    switch judge {
    case .test(let id, let bundle):
        let (tested, testFailures) = try outcome(of: id, in: bundle)
        // A passing test under a failing run is a failed check, so the ticket and make's exit status say the same thing.
        (result, failures) = (exited.isEmpty ? tested : .fail, testFailures + exited)
    case .exitStatus:
        // Any other status is a fail too, with the setup its reason names (a VM image that is missing), as `status` says.
        (result, failures) = (status == 0 ? .pass : .fail, exited)
    }
    let record = Record(check: check, outcome: result, commit: commit, covers: covers,
                        uncommitted: paths.filter { built[$0] != committed[$0] }, printed: printed, failures: failures)
    // Posted from a file, so a failed post leaves the person's run on disk, and the error names the command that
    // posts it.
    let file = "build/\(check).record"
    try record.body.write(toFile: file, atomically: true, encoding: .utf8)
    try capture(["lit", "comment", "add", ticket, "--by", "make \(check)", "--body-file", file])
    print("\n\(check): \(result.rawValue), posted on \(ticket)")
    return result == .pass ? 0 : 1
}

func status(checks: [(name: String, paths: [String])]) throws {
    let ticket = try ticket()
    struct Export: Decodable { let comments: [Comment] }
    // lit writes created_at with a fraction of a second, or with none when the fraction is zero.
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    func instant(_ comment: Comment) throws -> Date {
        guard let date = fractional.date(from: comment.created_at) ?? whole.date(from: comment.created_at) else {
            throw CheckError.malformedRecord(comment: comment.id, "has an unreadable created_at \(comment.created_at)")
        }
        return date
    }
    let comments = try JSONDecoder().decode(Export.self, from: Data(try capture(["lit", "export"]).utf8)).comments
        .filter { $0.issue_id == ticket }
        .map { (at: try instant($0), comment: $0) }
        .sorted { $0.at < $1.at }
        .map(\.comment)
    print("hardware checks on \(ticket), for HEAD:")
    for (name, paths) in checks {
        let latest = try comments.compactMap { try Recorded.parse($0, check: name) }.last
        let head = try objectIDs(of: paths, in: "HEAD")
        // A path the record does not cover (one declared since), or one HEAD no longer holds, counts as changed.
        let line = switch latest.map({ recorded in (recorded, paths.filter { recorded.covers[$0] == nil || recorded.covers[$0] != head[$0] }) }) {
        case nil: "never run"
        case let (recorded, changed)? where changed.isEmpty:
            "stands (\(recorded.outcome.rawValue), \(recorded.commit.prefix(7)))" + recorded.failures.map { "\n    failure: \($0)" }.joined()
        case let (_, changed)?: "stale: \(changed.joined(separator: " "))"
        }
        print("  \(name): \(line)")
    }
}

// MARK: - Arguments

/// The arguments after the subcommand: leading positionals, then `--flag value...` groups, then `--` and a command.
func groups(_ arguments: ArraySlice<String>) -> (positional: [String], flags: [(String, [String])], command: [String]) {
    let split = arguments.firstIndex(of: "--")
    let command = split.map { Array(arguments[($0 + 1)...]) } ?? []
    var positional: [String] = []
    var flags: [(String, [String])] = []
    for argument in arguments[..<(split ?? arguments.endIndex)] {
        if argument.hasPrefix("--") { flags.append((String(argument.dropFirst(2)), [])) }
        else if flags.isEmpty { positional.append(argument) }
        else { flags[flags.count - 1].1.append(argument) }
    }
    return (positional, flags, command)
}

do {
    let arguments = CommandLine.arguments.dropFirst()
    let (positional, flags, command) = groups(arguments.dropFirst())
    func values(_ flag: String) -> [String] { flags.filter { $0.0 == flag }.flatMap(\.1) }
    // A flag no subcommand reads is refused, not ignored, so a caller still passing one learns it does nothing.
    func refuseFlags(except known: Set<String>) throws {
        if let unknown = flags.map(\.0).first(where: { !known.contains($0) }) { throw CheckError.usage("no flag --\(unknown)") }
    }
    func one(_ flag: String) throws -> String {
        guard let value = values(flag).first, values(flag).count == 1 else { throw CheckError.usage("--\(flag) takes one value") }
        return value
    }
    switch arguments.first {
    case "run":
        try refuseFlags(except: ["test", "bundle", "covers"])
        guard positional.count == 1, !values("covers").isEmpty, !command.isEmpty else {
            throw CheckError.usage("run takes one check name, at least one --covers path, and a command after --")
        }
        // A bundle with no test, or a test with no bundle, leaves it unsaid which result to read.
        guard values("test").isEmpty == values("bundle").isEmpty else {
            throw CheckError.usage("--test and --bundle are given together or not at all")
        }
        let judge: Judge = values("test").isEmpty ? .exitStatus : .test(try one("test"), bundle: try one("bundle"))
        exit(try run(check: positional[0], judge: judge, covers: values("covers"), command: command))
    case "status":
        try refuseFlags(except: ["check"])
        let checks = flags.filter { $0.0 == "check" }.map { (name: $0.1.first ?? "", paths: Array($0.1.dropFirst())) }
        guard !checks.isEmpty, checks.allSatisfy({ !$0.name.isEmpty && !$0.paths.isEmpty }) else {
            throw CheckError.usage("status takes --check <check> <path>... for each check")
        }
        try status(checks: checks)
    default:
        throw CheckError.usage("no subcommand")
    }
} catch {
    FileHandle.standardError.write(Data("hardware-check: \(error)\n".utf8))
    exit(1)
}
