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
    /// [LAW:types-are-the-program] A Mac that cannot pause charging stays so for the helper's life: nothing reads the
    /// SMC again, and every call answers with the reason at once.
    enum State: Equatable {
        case supported(holders: Set<ObjectIdentifier>)
        case unsupported(ChargingFailure)
    }

    private(set) var state = State.supported(holders: [])
    private let open: () throws(ChargingFailure) -> any ChargeInhibitAccess
    private let marker: any PauseRecord

    /// `open` reaches CHTE, once per reconcile, so a Mac without an SMC client fails the reconcile that needed it.
    init(open: @escaping () throws(ChargingFailure) -> any ChargeInhibitAccess, marker: any PauseRecord) {
        self.open = open
        self.marker = marker
    }

    /// A connection holds charging paused until it resumes, or until it ends.
    func pause(for holder: ObjectIdentifier) -> Outcome { reconcile("pause", holders: { $0.insert(holder) }) }

    func resume(for holder: ObjectIdentifier) -> Outcome { reconcile("resume", holders: { $0.remove(holder) }) }

    /// A connection ended, so what it held is let go.
    func drop(_ holder: ObjectIdentifier) -> Outcome { reconcile("connection ended", holders: { $0.remove(holder) }) }

    /// Something may have changed CHTE under the helper: its start, or a power-source change.
    func check(_ trigger: String) -> Outcome { reconcile(trigger, holders: { _ in }) }

    /// The helper is ending on purpose: every hold is let go, so charging is given back before it exits.
    func end(_ reason: String) -> Outcome { reconcile(reason, holders: { $0.removeAll() }) }

    /// What one reconcile did, as the helper logs it and a call replies with it.
    struct Outcome {
        let result: Result<Void, ChargingFailure>
        let line: String
    }

    /// [LAW:dataflow-not-control-flow] Every trigger runs the same steps: change the holders, read the marker and
    /// CHTE, and perform what `ChargingInhibit.reconcile` says; only the holders vary.
    private func reconcile(_ trigger: String, holders change: (inout Set<ObjectIdentifier>) -> Void) -> Outcome {
        guard case .supported(var holders) = state else {
            guard case .unsupported(let failure) = state else { fatalError("unreachable") }
            return Outcome(result: .failure(failure), line: "charging \(trigger): \(failure)")
        }
        change(&holders)
        state = .supported(holders: holders)
        do {
            let key = try open()
            let marked = try marker.isMarked()
            let read = try key.read()
            let steps = ChargingInhibit.reconcile(leases: holders.count, marked: marked, read: read.inhibit)
            for step in steps { try perform(step, on: key) }
            let did = steps.isEmpty ? "nothing to do" : steps.map(\.text).joined(separator: ", ")
            return Outcome(result: .success(()), line: "charging \(trigger): \(holders.count) holding, marked \(marked), \(ChargingInhibit.key) \(Self.hex(read.bytes)): \(did)")
        } catch {
            if case .unsupported = error { state = .unsupported(error) }
            return Outcome(result: .failure(error), line: "charging \(trigger) failed: \(error)")
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
                throw .failed("\(ChargingInhibit.key) reads \(Self.hex(back.bytes)) after charging was allowed; the pause record is kept")
            }
            try marker.unmark()
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
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
