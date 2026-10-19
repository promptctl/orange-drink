import AppKit
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the log says about a quit: who asked, and from where.
@MainActor struct TerminationTests {
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

    @Test func loggingARequestNeverStopsTheQuit() {
        #expect(TerminationLog().applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }
}
