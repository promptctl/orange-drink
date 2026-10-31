import Foundation

/// CHTE as the helper's reconcile reads and writes it: `ChargeInhibitKey` on the Mac, a fake in the tests.
protocol ChargeInhibitAccess {
    func read() throws(ChargingFailure) -> (inhibit: ChargingInhibit?, bytes: [UInt8])
    func write(_ inhibit: ChargingInhibit) throws(ChargingFailure)
}

extension ChargeInhibitKey: ChargeInhibitAccess {}

/// The record that a pause this helper wrote may be outstanding: a file on the Mac, a fake in the tests.
protocol PauseRecord {
    func isMarked() throws(ChargingFailure) -> Bool
    func mark() throws(ChargingFailure)
    func unmark() throws(ChargingFailure)
}

/// [LAW:one-source-of-truth] The one lasting record, per helper label, that this helper's pause may still hold CHTE.
/// It outlives the helper, so a helper that was killed while holding a pause is answered for by the next one; and it
/// is per label, so each build's helper ends only its own pause.
struct PauseMarkerFile: PauseRecord {
    let url: URL

    init(label: String, directory: URL = URL(filePath: "/Library/Application Support/OrangeDrink")) {
        url = directory.appending(path: "\(label).chargingPaused")
    }

    func isMarked() throws(ChargingFailure) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func mark() throws(ChargingFailure) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .atomic)
        } catch { throw .failed("cannot record the pause at \(url.path): \(error)") }
    }

    func unmark() throws(ChargingFailure) {
        do { try FileManager.default.removeItem(at: url) } catch { throw .failed("cannot clear the pause record at \(url.path): \(error)") }
    }
}

/// The helper's charging state: which connections hold charging paused, and whether this Mac can pause it at all.
///
/// [LAW:single-enforcer] The one owner of CHTE in the helper. It is not thread-safe: the helper reaches it only
/// through `Confined`, on its one queue of system writes.
final class ChargingHolds {
    /// [LAW:types-are-the-program] A closed helper touches the SMC no more and answers every call with its failure at
    /// once, for the rest of its life: unsupported on a Mac that cannot pause charging, failed once it is exiting.
    enum State: Equatable {
        case supported(holders: Set<ObjectIdentifier>)
        case closed(ChargingFailure)
    }

    private(set) var state = State.supported(holders: [])
    private let open: () throws(ChargingFailure) -> any ChargeInhibitAccess
    private let marker: any PauseRecord

    /// `open` reaches CHTE, once per reconcile, so a Mac without an SMC client fails the reconcile that needed it.
    init(open: @escaping () throws(ChargingFailure) -> any ChargeInhibitAccess, marker: any PauseRecord) {
        self.open = open
        self.marker = marker
    }

    /// A connection holds charging paused until it resumes, or until it ends. `deadline` is the instant its caller
    /// stops waiting.
    func pause(for holder: ObjectIdentifier, by deadline: Date) -> Outcome {
        reconcile("pause", by: deadline, holders: { $0.insert(holder) })
    }

    func resume(for holder: ObjectIdentifier, by deadline: Date) -> Outcome {
        reconcile("resume", by: deadline, holders: { $0.remove(holder) })
    }

    /// A connection ended, so what it held is let go.
    func drop(_ holder: ObjectIdentifier) -> Outcome { reconcile("connection ended", holders: { $0.remove(holder) }) }

    /// Something may have changed CHTE under the helper: its start, or a power-source change.
    func check(_ trigger: String) -> Outcome { reconcile(trigger, holders: { _ in }) }

    /// The helper is ending on purpose: every hold is let go, so charging is given back before it exits, and the
    /// helper closes, so no call that reaches it before the exit pauses again.
    func end(_ reason: String) -> Outcome {
        defer { state = .closed(.failed("not run: \(reason)")) }
        return reconcile(reason, holders: { $0.removeAll() })
    }

    /// What one reconcile did, as the helper logs it and a call replies with it.
    struct Outcome {
        let result: Result<Void, ChargingFailure>
        let line: String
    }

    /// [LAW:dataflow-not-control-flow] Every trigger runs the same steps: change the holders, read the marker and
    /// CHTE, and perform what `ChargingInhibit.reconcile` says; only the holders vary. A trigger no caller waits on has
    /// no deadline.
    private func reconcile(_ trigger: String, by deadline: Date = .distantFuture,
                           holders change: (inout Set<ObjectIdentifier>) -> Void) -> Outcome {
        var holders: Set<ObjectIdentifier>
        switch state {
        case .closed(let failure): return Outcome(result: .failure(failure), line: "charging \(trigger): \(failure)")
        case .supported(let held): holders = held
        }
        // [LAW:single-enforcer] Checked at the call's turn on the write queue, after any wait for it: a caller that
        // stopped waiting is ending the connection, which lets go of anything it held.
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else {
            let failure = ChargingFailure.failed("not run: the call's deadline passed \((-left).formatted(.number.precision(.fractionLength(1)))) s ago")
            return Outcome(result: .failure(failure), line: "charging \(trigger): \(failure)")
        }
        change(&holders)
        state = .supported(holders: holders)
        // Whether the record of a pause of ours is on disk, as the steps so far leave it.
        var recorded = false
        do {
            let marked = try marker.isMarked()
            recorded = marked
            // With no holder and no pause of ours, the rule leaves CHTE alone whatever it holds, so the SMC is not
            // opened: a helper that stays up for Low Power Mode costs a file check per power change, no more.
            guard !holders.isEmpty || marked else {
                return Outcome(result: .success(()), line: "charging \(trigger): 0 holding, marked false: nothing to do")
            }
            let key = try open()
            let read = try key.read()
            let steps = ChargingInhibit.reconcile(leases: holders.count, marked: marked, read: read.inhibit)
            for step in steps {
                try perform(step, on: key)
                recorded = (recorded || step == .mark) && step != .unmark
            }
            let did = steps.isEmpty ? "nothing to do" : steps.map(\.text).joined(separator: ", ")
            return Outcome(result: .success(()), line: "charging \(trigger): \(holders.count) holding, marked \(marked), \(ChargingInhibit.key) \(read.bytes.hex): \(did)")
        } catch {
            // [LAW:one-source-of-truth] A closed helper never touches the record again, so a refusal is this Mac's final
            // answer only while there is no record, even one this reconcile just made; and only a final one is reported
            // as unsupported, so the app stops asking exactly when the helper does. A refusal met with a record on disk
            // is a failure: the record stays, and the next reconcile, the connection's end included, answers for it.
            let reported: ChargingFailure = switch error {
            case .unsupported(let reason) where recorded: .failed("\(reason); the pause record stays, so it is tried again")
            case .unsupported, .failed: error
            }
            if case .unsupported = reported { state = .closed(reported) }
            return Outcome(result: .failure(reported), line: "charging \(trigger) failed: \(reported)")
        }
    }

    private func perform(_ step: ChargingStep, on key: any ChargeInhibitAccess) throws(ChargingFailure) {
        switch step {
        case .mark: try marker.mark()
        case .write(let inhibit): try key.write(inhibit)
        case .unmark:
            // The record goes only once CHTE reads back as allowed: a pause the helper cannot confirm ended stays
            // answered for.
            let back = try key.read()
            guard back.inhibit == .allowed else {
                throw .failed("\(ChargingInhibit.key) reads \(back.bytes.hex) after charging was allowed; the pause record is kept")
            }
            try marker.unmark()
        }
    }
}

extension ChargingStep {
    var text: String {
        switch self {
        case .mark: "marked"
        case .write(.paused): "paused"
        case .write(.allowed): "allowed"
        case .unmark: "unmarked"
        }
    }
}

/// A value reached only on one serial queue.
///
/// [LAW:no-shared-mutable-globals] The type is the rule: the value has no other way in, so every reach is in that
/// queue's order. The helper's charging holds live on its queue of system writes.
final class Confined<Value>: @unchecked Sendable {
    private let value: Value
    private let queue: DispatchQueue

    init(_ value: Value, on queue: DispatchQueue) {
        self.value = value
        self.queue = queue
    }

    func sync<Result>(_ body: (Value) -> Result) -> Result { queue.sync { body(value) } }
}
