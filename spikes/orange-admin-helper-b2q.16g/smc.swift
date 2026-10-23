// The SMC from user space, and the outside view of charging, for the spike's run.sh.
//   smc list            every key whose name starts CH or bf: name, type, size, bytes (no root)
//   smc read KEY        KEY's bytes in hex
//   smc write KEY HEX   write HEX to KEY (needs root); prints the IOKit and SMC results as they come
//   smc observe         one line: battery registry charging state beside the SMC's CHNC
// Build: swiftc -O smc.swift -o smc
import Foundation
import IOKit

// The AppleSMC user client's SMCKeyData_t: 80 bytes, one layout for every command. The offsets are
// the C struct's under natural alignment; packing them by hand keeps that ABI on the page.
enum Offset {
    static let key = 0, dataSize = 28, dataType = 32, result = 40, command = 42, index = 44, bytes = 48
    static let structSize = 80
}

enum Command: UInt8 { case read = 5, write = 6, keyAtIndex = 8, keyInfo = 9 }

struct Failure: Error, CustomStringConvertible {
    let description: String
}

// A four-character SMC key, parsed once from the command line or the SMC's own index.
struct Key: CustomStringConvertible {
    let code: UInt32
    init(_ name: String) throws {
        let chars = Array(name.utf8)
        guard chars.count == 4 else { throw Failure(description: "key '\(name)' is not four characters") }
        code = chars.reduce(0) { $0 << 8 | UInt32($1) }
    }
    init(code: UInt32) { self.code = code }
    var description: String { fourCC(code) }
}

func fourCC(_ v: UInt32) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) }, as: UTF8.self)
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

struct Info { let size: Int; let type: String }

final class SMC {
    private let connection: io_connect_t

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw Failure(description: "no AppleSMC service") }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == KERN_SUCCESS else { throw Failure(description: "IOServiceOpen AppleSMC: \(ioReturn(kr))") }
        connection = c
    }

    deinit { IOServiceClose(connection) }

    // [LAW:no-silent-failure] Every call surfaces the kern_return and the SMC's result byte, named
    // with the key; nothing is retried or defaulted.
    private func call(_ command: Command, _ key: UInt32, fill: (inout [UInt8]) -> Void = { _ in }) throws -> [UInt8] {
        var input = [UInt8](repeating: 0, count: Offset.structSize)
        put32(&input, Offset.key, key)
        input[Offset.command] = command.rawValue
        fill(&input)
        var output = [UInt8](repeating: 0, count: Offset.structSize)
        var outSize = Offset.structSize
        let kr = IOConnectCallStructMethod(connection, 2, input, Offset.structSize, &output, &outSize)
        guard kr == KERN_SUCCESS else {
            throw Failure(description: "\(command) \(fourCC(key)): kern_return \(ioReturn(kr))")
        }
        guard output[Offset.result] == 0 else {
            throw Failure(description: "\(command) \(fourCC(key)): SMC result 0x\(String(output[Offset.result], radix: 16))")
        }
        return output
    }

    func count() throws -> Int {
        Int(try read(Key("#KEY")).reduce(0) { $0 << 8 | UInt32($1) })
    }

    func key(at index: Int) throws -> Key {
        let out = try call(.keyAtIndex, 0) { put32(&$0, Offset.index, UInt32(index)) }
        return Key(code: get32(out, Offset.key))
    }

    func info(_ key: Key) throws -> Info {
        let out = try call(.keyInfo, key.code)
        let size = Int(get32(out, Offset.dataSize))
        // [LAW:parse-dont-validate] The one place a size meets the 32 data bytes the struct carries, so
        // read and write never index past it.
        guard size <= Offset.structSize - Offset.bytes else {
            throw Failure(description: "keyInfo \(key): \(size) bytes, more than the SMC struct carries")
        }
        return Info(size: size, type: fourCC(get32(out, Offset.dataType)))
    }

    func read(_ key: Key) throws -> [UInt8] {
        let size = try info(key).size
        let out = try call(.read, key.code) { put32(&$0, Offset.dataSize, UInt32(size)) }
        return Array(out[Offset.bytes..<Offset.bytes + size])
    }

    func write(_ key: Key, _ bytes: [UInt8]) throws {
        let size = try info(key).size
        guard bytes.count == size else {
            throw Failure(description: "write \(key): \(bytes.count) bytes given, key holds \(size)")
        }
        _ = try call(.write, key.code) {
            put32(&$0, Offset.dataSize, UInt32(size))
            $0.replaceSubrange(Offset.bytes..<Offset.bytes + size, with: bytes)
        }
    }
}

// Every 32-bit field is a native UInt32, keys and types included: a four-character code is the
// number with its first character in the high byte, not four bytes in name order.
func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
    withUnsafeBytes(of: v) { b.replaceSubrange(at..<at + 4, with: $0) }
}

func get32(_ b: [UInt8], _ at: Int) -> UInt32 {
    b[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

func ioReturn(_ kr: kern_return_t) -> String {
    let named: [kern_return_t: String] = [
        kIOReturnNotPrivileged: "kIOReturnNotPrivileged", kIOReturnBadArgument: "kIOReturnBadArgument",
        kIOReturnNotPermitted: "kIOReturnNotPermitted", kIOReturnError: "kIOReturnError",
    ]
    return String(format: "0x%08x", UInt32(bitPattern: kr)) + (named[kr].map { " (\($0))" } ?? "")
}

func parseHex(_ s: String) throws -> [UInt8] {
    let chars = Array(s)
    guard chars.count % 2 == 0, !chars.isEmpty else { throw Failure(description: "hex '\(s)' is not whole bytes") }
    return try stride(from: 0, to: chars.count, by: 2).map {
        guard let byte = UInt8(String(chars[$0...$0 + 1]), radix: 16) else { throw Failure(description: "hex '\(s)' is not hex") }
        return byte
    }
}

func battery() throws -> [String: Any] {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard entry != 0 else { throw Failure(description: "no AppleSmartBattery service") }
    defer { IOObjectRelease(entry) }
    var props: Unmanaged<CFMutableDictionary>?
    let kr = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
    guard kr == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else {
        throw Failure(description: "AppleSmartBattery properties: \(ioReturn(kr))")
    }
    return dict
}

func observe(_ smc: SMC) throws -> String {
    let reg = try battery()
    guard let charger = reg["ChargerData"] as? [String: Any] else { throw Failure(description: "AppleSmartBattery has no ChargerData") }
    func field(_ dict: [String: Any], _ name: String) throws -> Any {
        guard let v = dict[name] else { throw Failure(description: "AppleSmartBattery has no \(name)") }
        return v
    }
    let fields: [(String, Any)] = [
        ("IsCharging", try field(reg, "IsCharging")), ("ExternalConnected", try field(reg, "ExternalConnected")),
        ("CurrentCapacity", try field(reg, "CurrentCapacity")), ("InstantAmperage", try field(reg, "InstantAmperage")),
        ("NotChargingReason", try field(charger, "NotChargingReason")),
        ("ChargerInhibitReason", try field(charger, "ChargerInhibitReason")),
        ("ChargingCurrent", try field(charger, "ChargingCurrent")),
        ("CHNC", hex(try smc.read(Key("CHNC")))),
    ]
    return fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
}

func run(_ args: [String]) throws {
    let smc = try SMC()
    switch args.first {
    case "list":
        for index in 0..<(try smc.count()) {
            let key = try smc.key(at: index)
            guard key.description.hasPrefix("CH") || key.description.hasPrefix("bf") else { continue }
            // A key that refuses an unprivileged caller is listed with its refusal, not dropped: which
            // keys the SMC guards is part of the answer.
            switch Result(catching: { () throws -> String in
                let info = try smc.info(key)
                return "\(info.type) \(info.size) \(hex(try smc.read(key)))"
            }) {
            case .success(let line): print(key, line)
            case .failure(let refusal): print(key, "refused:", refusal)
            }
        }
    case "read" where args.count == 2:
        print(hex(try smc.read(Key(args[1]))))
    case "write" where args.count == 3:
        let key = try Key(args[1])
        try smc.write(key, try parseHex(args[2]))
        print("wrote \(key) \(args[2])")
    case "observe" where args.count == 1:
        print(try observe(smc))
    default:
        throw Failure(description: "usage: smc list | read KEY | write KEY HEX | observe")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("smc: \(error)\n".utf8))
    exit(1)
}
