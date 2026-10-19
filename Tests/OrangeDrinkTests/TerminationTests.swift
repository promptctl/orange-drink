import AppKit
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the log says about a quit: who asked, and from where.
@MainActor struct TerminationTests {
    @Test func aQuitAppleEventNamesItsSender() {
        let sentence = TerminationRequest.quitEvent(senderPID: 412, senderName: "osascript").sentence(stack: ["delegate", "b"])
        #expect(sentence == "quit Apple event from pid 412 (osascript); stack: b")
    }

    @Test func aSenderWithoutANameIsStillNamedByItsPid() {
        #expect(TerminationRequest.quitEvent(senderPID: 7, senderName: nil).sentence(stack: []).hasPrefix("quit Apple event from pid 7 (unknown)"))
    }

    @Test func aQuitEventWithoutAReadableSenderIsNotTakenForAQuitFromInside() {
        let sentence = TerminationRequest.quitEvent(senderPID: nil, senderName: nil).sentence(stack: [])
        #expect(sentence.hasPrefix("quit Apple event with no readable sender pid"))
    }

    @Test func aQuitFromInsideTheAppSaysSoAndCarriesTheStackThatAskedForIt() {
        let stack = (0..<50).map { "frame\($0)" }
        let sentence = TerminationRequest.inApp.sentence(stack: stack)
        #expect(sentence.hasPrefix("quit request from inside the app; stack: frame1 <- frame2"))
        #expect(sentence.hasSuffix("frame30") && !sentence.contains("frame31") && !sentence.contains("frame0 "))
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
        #expect(TerminationRequest.current(event: quit) == .quitEvent(senderPID: nil, senderName: nil))
    }

    @Test func loggingARequestNeverStopsTheQuit() {
        #expect(TerminationLog().applicationShouldTerminate(NSApp) == .terminateNow)
    }
}
