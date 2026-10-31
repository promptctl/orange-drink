import AppKit
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the log says about a quit: who asked, and from where.
@MainActor struct TerminationTests {
    private let quits = QuitRecords(url: FileManager.default.temporaryDirectory.appending(components: UUID().uuidString, "quits.log"), build: "test build")

    @Test func aQuitAppleEventNamesItsSender() {
        let lines = TerminationRequest.quitEvent(sender: .init(pid: 412, name: "osascript")).lines(stack: ["delegate", "b"])
        #expect(lines == ["quit Apple event from pid 412 (osascript)", "  b"])
    }

    @Test func aSenderWithoutANameIsStillNamedByItsPid() {
        #expect(TerminationRequest.quitEvent(sender: .init(pid: 7, name: nil)).lines(stack: []) == ["quit Apple event from pid 7 (unknown)"])
    }

    @Test func aQuitEventWithoutAReadableSenderIsNotTakenForAQuitFromInside() {
        #expect(TerminationRequest.quitEvent(sender: nil).lines(stack: []) == ["quit Apple event with no readable sender pid"])
    }

    @Test func aQuitFromInsideTheAppSaysSoAndCarriesTheFramesThatAskedForItOnePerLine() {
        let stack = (0..<50).map { "\($0)   Image   0x0000000100  frame\($0) + 4" }
        let lines = TerminationRequest.inApp.lines(stack: stack)
        #expect(lines.first == "quit request from inside the app")
        #expect(lines.count == 1 + TerminationRequest.stackDepth)
        #expect(lines[1] == "  1 Image 0x0000000100 frame1 + 4" && lines.last == "  30 Image 0x0000000100 frame30 + 4")
        #expect(lines.allSatisfy { $0.utf8.count < 1000 })
    }

    @Test func noEventAtAllIsAQuitFromInside() {
        #expect(TerminationRequest.current(event: nil) == .inApp)
    }

    @Test func anEventThatIsNotAQuitIsNeverBlamedForOne() {
        let open = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(TerminationRequest.current(event: open) == .inApp)
    }

    @Test func aQuitEventIsRecognisedAsOne() {
        let quit = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(TerminationRequest.current(event: quit) == .quitEvent(sender: nil))
    }

    @Test func aSIGTERMNamesItsSender() {
        #expect(TerminationRequest.signal(sender: .init(pid: 412, name: "zsh")).lines(stack: []) == ["SIGTERM from pid 412 (zsh)"])
    }

    @Test func aSIGTERMWhoseSenderHasGoneIsStillNamedByItsPid() {
        #expect(TerminationRequest.signal(sender: .init(pid: 7, name: nil)).lines(stack: []) == ["SIGTERM from pid 7 (unknown)"])
    }

    @Test func aSIGTERMWithoutASenderIsNotTakenForAQuitFromInside() {
        #expect(TerminationRequest.signal(sender: nil).lines(stack: []) == ["SIGTERM with no readable sender pid"])
    }

    @Test func aPidThatNamesNoProcessIsNoSender() {
        #expect(TerminationRequest.Sender.lookedUp(0) == nil)
        #expect(TerminationRequest.Sender.lookedUp(nil) == nil)
    }

    @Test func aLiveSenderIsLookedUpByName() {
        let name = TerminationRequest.Sender.lookedUp(getpid())?.name
        #expect(name == ProcessInfo.processInfo.processName)
    }

    // The ticket's own failure: a quit noticed later, after the unified log has dropped it.
    @Test func aQuitsRecordOriginAndSenderIncludedIsStillInTheStoreAfterALaterQuit() throws {
        let log = TerminationLog(records: quits, signal: SIGUSR2, terminate: {})
        log.record(.signal(sender: .init(pid: 412, name: "zsh")), stack: ["delegate", "frame"], at: Date(timeIntervalSince1970: 0))
        log.record(.inApp, stack: [], at: Date(timeIntervalSince1970: 8 * 24 * 3600))
        #expect(try String(contentsOf: quits.url, encoding: .utf8) == """
            1970-01-01T00:00:00Z pid \(getpid()) test build
            SIGTERM from pid 412 (zsh)
              frame
            1970-01-09T00:00:00Z pid \(getpid()) test build
            quit request from inside the app

            """)
    }

    // [LAW:behavior-not-structure] A real signal from a real process, end to end to the file. SIGUSR2 because the
    // test host is the app, whose own watch of SIGTERM would end it.
    @Test(.timeLimit(.minutes(1))) func aSignalFromAnotherProcessIsRecordedWithThatProcesssPid() async throws {
        let sender = Process()
        sender.executableURL = URL(filePath: "/bin/kill")
        sender.arguments = ["-USR2", "\(getpid())"]
        var log: TerminationLog?
        await withCheckedContinuation { (asked: CheckedContinuation<Void, Never>) in
            log = TerminationLog(records: quits, signal: SIGUSR2, terminate: { asked.resume() })
            log?.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            #expect(throws: Never.self) { try sender.run() }
        }
        #expect(log?.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(try String(contentsOf: quits.url, encoding: .utf8).contains("SIGTERM from pid \(sender.processIdentifier) ("))
    }

    @Test func aRecordThatCannotBeWrittenNeverStopsTheQuit() {
        let unwritable = QuitRecords(url: URL(filePath: "/dev/null/quits.log"), build: "test build")
        #expect(TerminationLog(records: unwritable, signal: SIGUSR2, terminate: {}).applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    // What macOS acts on, read from the launched test host: SwiftUI's adaptor reached the delegate at launch.
    @Test func theLaunchedAppCatchesSIGTERMWithItsSender() {
        var current = sigaction()
        sigaction(SIGTERM, nil, &current)
        #expect(current.sa_flags & SA_SIGINFO != 0)
    }
}
