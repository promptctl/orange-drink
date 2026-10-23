import Foundation
import IOKit

/// Whether the SMC lets the battery charge: the two values the helper ever writes to CHTE, the charge-inhibit key
/// orange-admin-helper-b2q.16g found on Apple silicon.
///
/// [LAW:types-are-the-program] No other bytes can reach the SMC: a write takes one of these two cases.
enum ChargingInhibit: Equatable, Sendable {
    case paused, allowed

    static let key = "CHTE"

    /// CHTE's four bytes, as the SMC holds them: 01000000 holds charging off, 00000000 lets it run.
    var bytes: [UInt8] {
        switch self {
        case .paused: [1, 0, 0, 0]
        case .allowed: [0, 0, 0, 0]
        }
    }

    /// The case these bytes are, or nil for a value the helper never writes.
    init?(bytes: [UInt8]) {
        guard let inhibit = [Self.paused, .allowed].first(where: { $0.bytes == bytes }) else { return nil }
        self = inhibit
    }
}

/// One thing a reconcile does, in the order it does them.
enum ChargingStep: Equatable, Sendable {
    /// Records that a pause of this helper's may be outstanding, before the pause is written.
    case mark
    case write(ChargingInhibit)
    /// Clears that record, once charging has been written back and read back as allowed.
    case unmark
}

extension ChargingInhibit {
    /// [LAW:one-source-of-truth] What brings CHTE to what the helper's holders want, from the three facts that decide
    /// it: how many connections hold a pause, whether a pause of this helper's may be outstanding (the marker, which
    /// outlives the helper), and what CHTE holds now (nil: neither value).
    ///
    /// A helper ends only a pause it made: with no holder and no marker, CHTE is another writer's and is left alone,
    /// whatever it holds.
    static func reconcile(leases: Int, marked: Bool, read: ChargingInhibit?) -> [ChargingStep] {
        if leases > 0 { return (marked ? [] : [.mark]) + (read == .paused ? [] : [.write(.paused)]) }
        guard marked else { return [] }
        return (read == .allowed ? [] : [.write(.allowed)]) + [.unmark]
    }
}

/// Why a charging call did not do what it was asked.
///
/// [LAW:types-are-the-program] Two facts a caller acts on differently: a Mac whose SMC cannot hold charging is so for
/// the rest of the run, so it is asked no more; anything else may pass, so it is asked again at the next change.
enum ChargingFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The SMC lacks CHTE, holds it as something other than a four-byte ui32, or refuses it even to root.
    case unsupported(String)
    case failed(String)

    var description: String {
        switch self {
        case .unsupported(let reason): "this Mac cannot pause charging: \(reason)"
        case .failed(let reason): reason
        }
    }

    /// The reply a charging call sends over XPC, which carries no Swift enum: a kind and its words. Kind 0 is
    /// success, 1 unsupported, 2 failed.
    static func reply(_ outcome: Result<Void, ChargingFailure>) -> (kind: Int, description: String?) {
        switch outcome {
        case .success: (0, nil)
        case .failure(.unsupported(let reason)): (1, reason)
        case .failure(.failed(let reason)): (2, reason)
        }
    }

    /// [LAW:parse-dont-validate] A reply read back: a kind the helper does not send is a failure naming it, never
    /// a success.
    static func parse(kind: Int, description: String?) -> Result<Void, ChargingFailure> {
        switch (kind, description) {
        case (0, nil): .success(())
        case (1, let reason?): .failure(.unsupported(reason))
        case (2, let reason?): .failure(.failed(reason))
        default: .failure(.failed("unreadable reply from the helper: kind \(kind), \(description ?? "no description")"))
        }
    }
}

/// CHTE as the helper reads and writes it, through the AppleSMC user client. Ported from
/// spikes/orange-admin-helper-b2q.16g/smc.swift, cut to the one key.
///
/// [LAW:no-silent-failure] Every IOKit return and SMC result reaches the caller as a ChargingFailure naming the key
/// and the code; nothing is retried or defaulted.
final class ChargeInhibitKey {
    /// The AppleSMC user client's SMCKeyData_t: 80 bytes, one layout for every command. The offsets are the C struct's
    /// under natural alignment; packing them by hand keeps that ABI on the page.
    private enum Offset {
        static let key = 0, dataSize = 28, dataType = 32, result = 40, command = 42, bytes = 48
        static let structSize = 80
    }

    private enum Command: UInt8 { case read = 5, write = 6, keyInfo = 9 }

    /// The SMC's result byte for a key it does not have.
    private static let keyNotFound: UInt8 = 0x84

    private let connection: io_connect_t
    private let code = ChargingInhibit.key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

    init() throws(ChargingFailure) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw .unsupported("no AppleSMC service") }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard kr == KERN_SUCCESS else { throw Self.failure("IOServiceOpen AppleSMC", kr) }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    /// What CHTE holds: one of the helper's two values, or nil with the bytes for a value it never writes.
    func read() throws(ChargingFailure) -> (inhibit: ChargingInhibit?, bytes: [UInt8]) {
        try checkShape()
        let out = try call(.read) { Self.put32(&$0, Offset.dataSize, 4) }
        let bytes = Array(out[Offset.bytes..<Offset.bytes + 4])
        return (ChargingInhibit(bytes: bytes), bytes)
    }

    func write(_ inhibit: ChargingInhibit) throws(ChargingFailure) {
        try checkShape()
        _ = try call(.write) {
            Self.put32(&$0, Offset.dataSize, 4)
            $0.replaceSubrange(Offset.bytes..<Offset.bytes + 4, with: inhibit.bytes)
        }
    }

    /// [LAW:parse-dont-validate] CHTE is a four-byte ui32 wherever the helper can use it; any other shape is a Mac it
    /// cannot pause, said once, before a byte is read or written.
    private func checkShape() throws(ChargingFailure) {
        let out = try call(.keyInfo)
        try Self.checkShape(type: Self.fourCC(Self.get32(out, Offset.dataType)), size: Self.get32(out, Offset.dataSize))
    }

    static func checkShape(type: String, size: UInt32) throws(ChargingFailure) {
        guard size == 4, type == "ui32" else { throw .unsupported("\(ChargingInhibit.key) is \(type), \(size) bytes, not ui32, 4 bytes") }
    }

    private func call(_ command: Command, fill: (inout [UInt8]) -> Void = { _ in }) throws(ChargingFailure) -> [UInt8] {
        var input = [UInt8](repeating: 0, count: Offset.structSize)
        Self.put32(&input, Offset.key, code)
        input[Offset.command] = command.rawValue
        fill(&input)
        var output = [UInt8](repeating: 0, count: Offset.structSize)
        var outSize = Offset.structSize
        let kr = IOConnectCallStructMethod(connection, 2, input, Offset.structSize, &output, &outSize)
        guard kr == KERN_SUCCESS else { throw Self.failure("\(command) \(ChargingInhibit.key)", kr) }
        let result = output[Offset.result]
        guard result == 0 else {
            let what = "\(command) \(ChargingInhibit.key): SMC result 0x\(String(result, radix: 16))"
            throw result == Self.keyNotFound ? .unsupported(what + " (key not found)") : .failed(what)
        }
        return output
    }

    /// A refusal of privilege, to a helper running as root, is this Mac's answer for good; any other return may pass.
    private static func failure(_ what: String, _ kr: kern_return_t) -> ChargingFailure {
        let code = String(format: "0x%08x", UInt32(bitPattern: kr))
        return kr == kIOReturnNotPrivileged ? .unsupported("\(what): kern_return \(code) (kIOReturnNotPrivileged)") : .failed("\(what): kern_return \(code)")
    }

    /// Every 32-bit field is a native UInt32, keys and types included: a four-character code is the number with its
    /// first character in the high byte, not four bytes in name order.
    private static func put32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        withUnsafeBytes(of: value) { bytes.replaceSubrange(at..<at + 4, with: $0) }
    }

    private static func get32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private static func fourCC(_ value: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
    }
}
