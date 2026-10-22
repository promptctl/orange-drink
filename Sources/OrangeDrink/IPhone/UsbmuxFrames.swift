import Foundation

// [LAW:one-source-of-truth] The usbmuxd wire format lives here and nowhere else: one header layout,
// one reader for partial frames, one decoder per message the monitor understands.
// Frame: 16-byte little-endian header (total length, version 1, type 8 = plist, tag), then an XML plist.

enum UsbmuxFrameError: Error, Equatable {
    case lengthOutOfRange(Int)
    case notAPlist
    case missingKey(String)
    case nonZeroResult(Int)
    /// usbmuxd holds no pair record for the UDID: the device has not trusted this Mac.
    case noPairRecord
}

/// How usbmuxd reaches a device: the cable, or Wi-Fi sync (Finder's "Show this iPhone when on Wi-Fi").
enum Transport: Equatable, Sendable {
    case usb
    case network
}

/// What usbmuxd says a handle is. The handle is a per-attach transport number; the UDID is the identity, the same
/// over the cable and over Wi-Fi, so one device can be held by a USB handle and a Wi-Fi handle at once.
enum DeviceConnection: Equatable {
    case device(udid: String, over: Transport)
    /// A ConnectionType this reader does not know. It is not read.
    case other(String)
}

struct AttachedDevice: Equatable {
    let handle: Int
    let connection: DeviceConnection
}

/// The messages the monitor acts on. Anything else on the Listen connection is `.other`.
enum UsbmuxEvent: Equatable {
    case attached(AttachedDevice)
    case detached(handle: Int)
    case paired(handle: Int)
    case other
}

// The largest reply the monitor accepts; usbmuxd and lockdown replies are a few KB.
let maxFrameLength = 1 << 20

/// Encodes one request frame with the given tag.
func usbmuxEncode(_ body: [String: Any], tag: UInt32 = 1) throws -> [UInt8] {
    let payload = [UInt8](try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0))
    var frame: [UInt8] = []
    for field in [UInt32(16 + payload.count), 1, 8, tag] {
        withUnsafeBytes(of: field.littleEndian) { frame += $0 }
    }
    return frame + payload
}

/// The total frame length from a 16-byte header, checked against the range the monitor accepts.
func usbmuxFrameLength(_ header: [UInt8]) throws -> Int {
    let length = (0..<4).reduce(0) { $0 | Int(header[$1]) << (8 * $1) }
    guard (16...maxFrameLength).contains(length) else { throw UsbmuxFrameError.lengthOutOfRange(length) }
    return length
}

/// Accumulates bytes from a usbmuxd connection and yields one complete frame body at a time.
/// A read that stops mid-frame keeps its bytes here, so a timeout or a would-block never drops them.
struct UsbmuxFrameReader {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) { buffer += bytes }

    /// The next complete frame's plist, or nil while the frame is still incomplete.
    mutating func next() throws -> [String: Any]? {
        guard buffer.count >= 16 else { return nil }
        let length = try usbmuxFrameLength(Array(buffer[0..<16]))
        guard buffer.count >= length else { return nil }
        let payload = Data(buffer[16..<length])
        buffer.removeFirst(length)
        return try plistDictionary(payload)
    }
}

func plistDictionary(_ data: Data) throws -> [String: Any] {
    guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        throw UsbmuxFrameError.notAPlist
    }
    return dict
}

/// The Number field of a Connect or Listen reply; zero is success.
func usbmuxCheckResult(_ body: [String: Any]) throws {
    guard let number = body["Number"] as? Int else { throw UsbmuxFrameError.missingKey("Number") }
    guard number == 0 else { throw UsbmuxFrameError.nonZeroResult(number) }
}

/// The ListDevices reply: every device usbmuxd currently holds, USB or Wi-Fi.
func usbmuxDeviceList(_ body: [String: Any]) throws -> [AttachedDevice] {
    guard let list = body["DeviceList"] as? [[String: Any]] else { throw UsbmuxFrameError.missingKey("DeviceList") }
    return try list.map { try attachedDevice($0) }
}

/// The ReadPairRecord reply's record. Without one, usbmuxd answers a Result whose Number is an errno (probed on
/// /var/run/usbmuxd): 2, ENOENT, for a well-formed UDID it holds no record for; 22, EINVAL, for a malformed UDID.
func usbmuxPairRecord(_ body: [String: Any]) throws -> Data {
    switch (body["PairRecordData"] as? Data, body["Number"] as? Int) {
    case (let data?, _): return data
    case (nil, 2): throw UsbmuxFrameError.noPairRecord
    case (nil, let number?) where number != 0: throw UsbmuxFrameError.nonZeroResult(number)
    case (nil, _): throw UsbmuxFrameError.missingKey("PairRecordData")
    }
}

/// One Listen message, decoded. Attached and Detached carry the handle; Result (the Listen reply) is `.other`
/// on success and throws on a nonzero Number.
func usbmuxEvent(_ body: [String: Any]) throws -> UsbmuxEvent {
    switch body["MessageType"] as? String {
    case "Attached": return .attached(try attachedDevice(body))
    case "Detached":
        guard let handle = body["DeviceID"] as? Int else { throw UsbmuxFrameError.missingKey("DeviceID") }
        return .detached(handle: handle)
    case "Paired":
        guard let handle = body["DeviceID"] as? Int else { throw UsbmuxFrameError.missingKey("DeviceID") }
        return .paired(handle: handle)
    case "Result":
        try usbmuxCheckResult(body)
        return .other
    default: return .other
    }
}

private func attachedDevice(_ body: [String: Any]) throws -> AttachedDevice {
    guard let handle = body["DeviceID"] as? Int else { throw UsbmuxFrameError.missingKey("DeviceID") }
    guard let props = body["Properties"] as? [String: Any] else { throw UsbmuxFrameError.missingKey("Properties") }
    let transport: Transport
    switch props["ConnectionType"] as? String {
    case "USB": transport = .usb
    case "Network": transport = .network
    case let other?: return AttachedDevice(handle: handle, connection: .other(other))
    case nil: throw UsbmuxFrameError.missingKey("ConnectionType")
    }
    guard let udid = props["SerialNumber"] as? String else { throw UsbmuxFrameError.missingKey("SerialNumber") }
    return AttachedDevice(handle: handle, connection: .device(udid: udid, over: transport))
}
