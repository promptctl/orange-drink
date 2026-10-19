import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what the log says about a quit: who asked, and from where.
struct TerminationTests {
    @Test func aQuitAppleEventNamesItsSender() {
        let sentence = TerminationRequest.sentence(senderPID: 412, senderName: "System Events", stack: ["a", "b"])
        #expect(sentence == "quit request from pid 412 (System Events); stack: a <- b")
    }

    @Test func aSenderWithoutANameIsStillNamedByItsPid() {
        #expect(TerminationRequest.sentence(senderPID: 7, senderName: nil, stack: []).hasPrefix("quit request from pid 7 (unknown)"))
    }

    @Test func aQuitFromInsideTheAppSaysSoAndCarriesTheStackThatAskedForIt() {
        let stack = (0..<20).map { "frame\($0)" }
        let sentence = TerminationRequest.sentence(senderPID: nil, senderName: nil, stack: stack)
        #expect(sentence.hasPrefix("quit request from inside the app; stack: frame0 <- frame1"))
        #expect(sentence.hasSuffix("frame11") && !sentence.contains("frame12"))
    }
}
