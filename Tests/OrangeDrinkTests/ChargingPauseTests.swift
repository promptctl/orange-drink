import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract on the helper's side: only CHTE's two values are ever written; a pause is
// recorded before it is written and the record goes only once charging reads back as allowed; with no holder and no
// record, CHTE is another writer's and is left alone; a Mac that cannot pause is asked no more; a reply crosses XPC
// and reads back as itself, and anything else reads back as a failure.

/// CHTE in memory: what it holds, and every write.
final class FakeCHTE: ChargeInhibitAccess {
    var bytes: [UInt8]
    var writes: [ChargingInhibit] = []
    /// What the next read-back after a write returns, when it is not what was written.
    var stuck: [UInt8]?

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func read() throws(ChargingFailure) -> (inhibit: ChargingInhibit?, bytes: [UInt8]) { (ChargingInhibit(bytes: bytes), bytes) }

    func write(_ inhibit: ChargingInhibit) throws(ChargingFailure) {
        writes.append(inhibit)
        bytes = stuck ?? inhibit.bytes
    }
}

final class FakeMarker: PauseRecord {
    var marked: Bool
    var changes: [String] = []
    init(marked: Bool) { self.marked = marked }
    func isMarked() throws(ChargingFailure) -> Bool { marked }
    func mark() throws(ChargingFailure) { marked = true; changes.append("mark") }
    func unmark() throws(ChargingFailure) { marked = false; changes.append("unmark") }
}

@Suite struct ChargingPauseTests {
    static let paused: [UInt8] = [1, 0, 0, 0], allowed: [UInt8] = [0, 0, 0, 0]

    @Test func eachValueIsItsBytesAndAnyOtherBytesAreNeither() {
        #expect(ChargingInhibit.paused.bytes == Self.paused)
        #expect(ChargingInhibit.allowed.bytes == Self.allowed)
        #expect(ChargingInhibit(bytes: Self.paused) == .paused)
        #expect(ChargingInhibit(bytes: [2, 0, 0, 0]) == nil)
    }

    @Test(arguments: [1, 2])
    func aHolderMarksBeforeItPausesAndWritesOnlyWhatDiffers(holders: Int) {
        #expect(ChargingInhibit.reconcile(leases: holders, marked: false, read: .allowed) == [.mark, .write(.paused)])
        #expect(ChargingInhibit.reconcile(leases: holders, marked: true, read: .allowed) == [.write(.paused)])
        #expect(ChargingInhibit.reconcile(leases: holders, marked: true, read: .paused) == [])
        #expect(ChargingInhibit.reconcile(leases: holders, marked: true, read: nil) == [.write(.paused)])
    }

    @Test func withNoHolderOnlyAPauseOfOursIsEnded() {
        #expect(ChargingInhibit.reconcile(leases: 0, marked: true, read: .paused) == [.write(.allowed), .unmark])
        #expect(ChargingInhibit.reconcile(leases: 0, marked: true, read: nil) == [.write(.allowed), .unmark])
        #expect(ChargingInhibit.reconcile(leases: 0, marked: true, read: .allowed) == [.unmark])
        // Another writer's pause, or anything else it wrote, is left alone.
        for read in [ChargingInhibit.paused, .allowed, nil] {
            #expect(ChargingInhibit.reconcile(leases: 0, marked: false, read: read) == [])
        }
    }

    static func holds(_ chte: FakeCHTE, _ marker: FakeMarker) -> ChargingHolds {
        ChargingHolds(open: { () throws(ChargingFailure) in chte }, marker: marker)
    }

    @Test func anotherWritersPauseIsLeftAloneAtStartAndAtAPowerChange() {
        let chte = FakeCHTE(Self.paused), marker = FakeMarker(marked: false)
        let holds = Self.holds(chte, marker)
        for trigger in ["helper start", "power source changed"] {
            let outcome = holds.check(trigger)
            #expect(outcome.line == "charging \(trigger): 0 holding, marked false, CHTE 01000000: nothing to do")
        }
        #expect(chte.writes == [] && marker.changes == [])
    }

    @Test func aPauseADeadHelperLeftIsEndedOnceAtTheNextStart() {
        let chte = FakeCHTE(Self.paused), marker = FakeMarker(marked: true)
        let holds = Self.holds(chte, marker)
        #expect(holds.check("helper start").line == "charging helper start: 0 holding, marked true, CHTE 01000000: allowed, unmarked")
        #expect(chte.writes == [.allowed] && marker.changes == ["unmark"])
        _ = holds.check("power source changed")
        #expect(chte.writes == [.allowed] && marker.changes == ["unmark"])
    }

    @Test func aHolderPausesUntilItResumesOrItsConnectionEnds() {
        let chte = FakeCHTE(Self.allowed), marker = FakeMarker(marked: false)
        let holds = Self.holds(chte, marker)
        // Kept alive for the test, so the two holders cannot share an address.
        let leases = (FakeLease(), FakeLease())
        let first = ObjectIdentifier(leases.0), second = ObjectIdentifier(leases.1)
        defer { withExtendedLifetime(leases) {} }
        _ = holds.pause(for: first)
        _ = holds.pause(for: second)
        #expect(chte.writes == [.paused] && marker.changes == ["mark"])
        _ = holds.resume(for: first)
        #expect(chte.writes == [.paused])
        // The firmware let charging run again under a holder: the next power change puts the pause back.
        chte.bytes = Self.allowed
        _ = holds.check("power source changed")
        #expect(chte.writes == [.paused, .paused])
        _ = holds.drop(second)
        #expect(chte.writes == [.paused, .paused, .allowed] && marker.changes == ["mark", "unmark"])
        #expect(holds.state == .supported(holders: []))
    }

    @Test func endingLetsGoOfEveryHolder() {
        let chte = FakeCHTE(Self.allowed), marker = FakeMarker(marked: false)
        let holds = Self.holds(chte, marker)
        _ = holds.pause(for: ObjectIdentifier(FakeLease()))
        #expect(holds.end("helper exits: SIGTERM").line == "charging helper exits: SIGTERM: 0 holding, marked true, CHTE 01000000: allowed, unmarked")
        #expect(chte.bytes == Self.allowed && !marker.marked)
    }

    @Test func theRecordStaysWhenChargingDoesNotReadBackAsAllowed() {
        let chte = FakeCHTE(Self.paused), marker = FakeMarker(marked: true)
        chte.stuck = Self.paused
        let holds = Self.holds(chte, marker)
        let outcome = holds.check("helper start")
        #expect(outcome.line == "charging helper start failed: CHTE reads 01000000 after charging was allowed; the pause record is kept")
        #expect(marker.marked)
    }

    @Test func aMacThatCannotPauseIsAskedNoMore() {
        final class Opens { var count = 0 }
        let opens = Opens()
        let holds = ChargingHolds(open: { () throws(ChargingFailure) in
            opens.count += 1
            throw .unsupported("read CHTE: SMC result 0x84 (key not found)")
        }, marker: FakeMarker(marked: false))
        _ = holds.check("helper start")
        let paused = holds.pause(for: ObjectIdentifier(FakeLease()))
        _ = holds.check("power source changed")
        #expect(opens.count == 1)
        #expect(paused.result.failure == .unsupported("read CHTE: SMC result 0x84 (key not found)"))
        #expect(holds.state == .unsupported(.unsupported("read CHTE: SMC result 0x84 (key not found)")))
    }

    @Test func aCHTEOfAnyOtherShapeIsAMacThatCannotPause() throws {
        try ChargeInhibitKey.checkShape(type: "ui32", size: 4)
        #expect { try ChargeInhibitKey.checkShape(type: "ui8 ", size: 1) } throws: { ($0 as? ChargingFailure) == .unsupported("CHTE is ui8 , 1 bytes, not ui32, 4 bytes") }
        #expect { try ChargeInhibitKey.checkShape(type: "hex_", size: 4) } throws: { if case .unsupported = $0 as? ChargingFailure { true } else { false } }
    }

    @Test func aReplyReadsBackAsItselfAndAnythingElseAsAFailure() {
        let outcomes: [Result<Void, ChargingFailure>] = [.success(()), .failure(.unsupported("u")), .failure(.failed("f"))]
        for outcome in outcomes {
            let reply = ChargingFailure.reply(outcome)
            #expect(ChargingFailure.parse(kind: reply.kind, description: reply.description).failure == outcome.failure)
        }
        #expect(ChargingFailure.parse(kind: 7, description: "x").failure == .failed("unreadable reply from the helper: kind 7, x"))
        #expect(ChargingFailure.parse(kind: 0, description: "x").failure != nil)
        #expect(ChargingFailure.parse(kind: 1, description: nil).failure != nil)
        if case .failure(.unsupported("u")) = HelperCallError.charging(kind: 1, description: "u") {} else { Issue.record("unsupported did not map to HelperCallError.unsupported") }
        if case .failure(.failed("f")) = HelperCallError.charging(kind: 2, description: "f") {} else { Issue.record("failed did not map to HelperCallError.failed") }
    }
}
