import Foundation
import Security

// The effectful edge of the iPhone reader: sockets, usbmuxd and lockdown requests, and SecureTransport.
// [LAW:effects-at-boundaries] Every blocking call happens here, under a deadline; the parsers beside it stay pure.
// [LAW:no-silent-failure] Every failure is a typed IPhoneReadError. Nothing here exits the process.

enum IPhoneReadError: Error, Equatable {
    case usbmuxUnavailable(errno: Int32)
    case usbmux(UsbmuxFrameError)
    case socket(errno: Int32)
    case closed
    case timeout
    case tls(OSStatus)
    case identity(PKCS12Error)
    case lockdown(String)
    /// The device answered with an Error: PasswordProtected while locked, InvalidHostID once trust is revoked.
    case refused(String)
    /// The relay answered Success with no entry: what it does for a class the device does not publish (the Vision Pro
    /// asked for AppleSmartBattery, cmt-9996a69e).
    case noPowerSource
    case parse(IPhoneParseError)
    case encoding(String)
    case unsupported(String)
    case replyTooLarge(Int)
}

// Not exported to Swift; value from Security/SecureTransport.h. SSLHandshake returns it when the device's certificate
// is ready to evaluate. It is signed by the pair record's own root, not a system CA, and it is not pinned: a device
// claiming a trusted iPhone's UDID can only misreport its own battery, and the host's CertificateVerify signs this
// session's transcript, so it cannot be replayed to a real device.
private let errSSLServerAuthCompleted: OSStatus = -9841

/// Every usbmuxd and lockdown request gets this long, measured from when the call starts.
let callDeadline = Duration.seconds(10)

/// A point on the monotonic clock after which a call fails with `.timeout`.
struct Deadline {
    private let instant: ContinuousClock.Instant
    init(after duration: Duration) { instant = ContinuousClock.now.advanced(by: duration) }
    var passed: Bool { ContinuousClock.now >= instant }
}

/// A connected socket with a one-second wake-up (SO_RCVTIMEO and SO_SNDTIMEO). The wake-up only lets a loop re-check
/// its deadline; a timed call checks the clock on every return, not only when the socket is quiet.
final class TimedSocket: Sendable {
    let fd: Int32

    /// Throws if the socket cannot take its wake-up: without it no deadline can be checked.
    init(fd: Int32) throws(IPhoneReadError) {
        self.fd = fd
        var wake = timeval(tv_sec: 1, tv_usec: 0)
        var on: Int32 = 1
        let options = [
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wake, socklen_t(MemoryLayout<timeval>.size)),
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wake, socklen_t(MemoryLayout<timeval>.size)),
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)),
        ]
        // No close here: fd is already stored, so a throw from this init still runs deinit, which closes it.
        if options.contains(-1) { throw IPhoneReadError.socket(errno: errno) }
    }

    deinit { close(fd) }

    func readExact(_ n: Int, until deadline: Deadline) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = recvInto(fd, &out, at: got)
            if r > 0 {
                got += r
            } else if r == 0 {
                throw IPhoneReadError.closed
            } else if !isRetry(errno) {
                throw IPhoneReadError.socket(errno: errno)
            }
            if deadline.passed { throw IPhoneReadError.timeout }
        }
        return out
    }

    func writeAll(_ bytes: [UInt8], until deadline: Deadline) throws {
        var sent = 0
        while sent < bytes.count {
            let r = bytes.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return send(fd, base + sent, bytes.count - sent, 0)
            }
            if r > 0 {
                sent += r
            } else if r == 0 {
                throw IPhoneReadError.closed
            } else if !isRetry(errno) {
                throw IPhoneReadError.socket(errno: errno)
            }
            if deadline.passed { throw IPhoneReadError.timeout }
        }
    }

    /// The Listen read. Returns the bytes that arrived, or nil on the one-second wake-up with nothing read.
    /// No deadline: a quiet Listen connection is normal, and the caller checks for cancellation on each wake-up.
    func receiveSome(max: Int) throws -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: max)
        let r = recvInto(fd, &out, at: 0)
        if r > 0 { return Array(out[0..<r]) }
        if r == 0 { throw IPhoneReadError.closed }
        if isRetry(errno) { return nil }
        throw IPhoneReadError.socket(errno: errno)
    }
}

/// The errnos that mean "nothing moved yet, call again": the one-second wake-up, or a signal that interrupted the call.
private func isRetry(_ err: Int32) -> Bool { err == EAGAIN || err == EWOULDBLOCK || err == EINTR }

private func recvInto(_ fd: Int32, _ out: inout [UInt8], at offset: Int) -> Int {
    out.withUnsafeMutableBytes { buf in
        guard let base = buf.baseAddress else { return -1 }
        return recv(fd, base + offset, buf.count - offset, 0)
    }
}

// MARK: - SecureTransport

/// The TLS callbacks' state. The channel owns it, because SecureTransport holds an unretained pointer to it.
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
private final class TLSBox {
    let fd: Int32
    var deadline = Deadline(after: callDeadline)
    var timedOut = false
    init(fd: Int32) { self.fd = fd }
}

// Read and write loop over recv/send until the buffer is full. EAGAIN before the deadline is a wait, so SecureTransport
// never sees errSSLWouldBlock. Past the deadline the callback sets `timedOut` and returns errSSLClosedAbort.
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
private let tlsRead: SSLReadFunc = { conn, data, len in
    let box = Unmanaged<TLSBox>.fromOpaque(conn).takeUnretainedValue()
    let want = len.pointee
    var got = 0
    while got < want {
        let r = recv(box.fd, data + got, want - got, 0)
        if r == 0 { len.pointee = got; return errSSLClosedGraceful }
        if r > 0 {
            got += r
        } else if !isRetry(errno) {
            len.pointee = got
            return errSSLClosedAbort
        }
        if box.deadline.passed { box.timedOut = true; len.pointee = got; return errSSLClosedAbort }
    }
    len.pointee = got
    return noErr
}

@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
private let tlsWrite: SSLWriteFunc = { conn, data, len in
    let box = Unmanaged<TLSBox>.fromOpaque(conn).takeUnretainedValue()
    let want = len.pointee
    var sent = 0
    while sent < want {
        let r = send(box.fd, data + sent, want - sent, 0)
        if r > 0 {
            sent += r
        } else if !isRetry(errno) {
            len.pointee = sent
            return errSSLClosedAbort
        }
        if box.deadline.passed { box.timedOut = true; len.pointee = sent; return errSSLClosedAbort }
    }
    len.pointee = sent
    return noErr
}

/// A TLS session over a TimedSocket, with the pair record's host identity as the client certificate.
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
final class TLSChannel {
    private let context: SSLContext
    private let box: TLSBox
    private let socket: TimedSocket  // held so the fd outlives the box that points at it

    private init(context: SSLContext, box: TLSBox, socket: TimedSocket) {
        self.context = context
        self.box = box
        self.socket = socket
    }

    deinit { _ = SSLClose(context) }

    static func handshake(over socket: TimedSocket, identity: SecIdentity) throws -> TLSChannel {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else { throw IPhoneReadError.tls(errSecAllocate) }
        let box = TLSBox(fd: socket.fd)
        let channel = TLSChannel(context: context, box: box, socket: socket)
        let setup = [
            SSLSetIOFuncs(context, tlsRead, tlsWrite),
            SSLSetConnection(context, Unmanaged.passUnretained(box).toOpaque()),
            SSLSetCertificate(context, [identity] as CFArray),
            SSLSetSessionOption(context, .breakOnServerAuth, true),
        ]
        // [LAW:no-silent-failure] A rejected setup call would handshake without the identity; fail here instead.
        if let failed = setup.first(where: { $0 != noErr }) { throw IPhoneReadError.tls(failed) }
        box.deadline = Deadline(after: callDeadline)
        while true {
            let status = SSLHandshake(context)
            if box.timedOut { throw IPhoneReadError.timeout }
            if status == errSSLServerAuthCompleted { continue }
            if status == noErr { return channel }
            throw IPhoneReadError.tls(status)
        }
    }

    func write(_ bytes: [UInt8], until deadline: Deadline) throws {
        box.deadline = deadline
        var sent = 0
        while sent < bytes.count {
            var processed = 0
            let status = bytes.withUnsafeBytes { buf -> OSStatus in
                guard let base = buf.baseAddress else { return errSecParam }
                return SSLWrite(context, base + sent, bytes.count - sent, &processed)
            }
            if box.timedOut { throw IPhoneReadError.timeout }
            guard status == noErr else { throw IPhoneReadError.tls(status) }
            sent += processed
        }
    }

    func read(_ n: Int, until deadline: Deadline) throws -> [UInt8] {
        box.deadline = deadline
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            var processed = 0
            let status = out.withUnsafeMutableBytes { buf -> OSStatus in
                guard let base = buf.baseAddress else { return errSecParam }
                return SSLRead(context, base + got, n - got, &processed)
            }
            if box.timedOut { throw IPhoneReadError.timeout }
            guard status == noErr else { throw IPhoneReadError.tls(status) }
            got += processed
        }
        return out
    }
}

// MARK: - usbmuxd

private let usbmuxPath = "/var/run/usbmuxd"

func openUsbmux() throws -> TimedSocket {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPhoneReadError.usbmuxUnavailable(errno: errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let copied = usbmuxPath.withCString { source in
        withUnsafeMutableBytes(of: &addr.sun_path) { strlcpy($0.baseAddress!.assumingMemoryBound(to: CChar.self), source, capacity) }
    }
    guard copied < capacity else { close(fd); throw IPhoneReadError.usbmuxUnavailable(errno: ENAMETOOLONG) }
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else {
        let err = errno
        close(fd)
        throw IPhoneReadError.usbmuxUnavailable(errno: err)
    }
    return try TimedSocket(fd: fd)
}

/// One reply frame, read under the deadline.
func readUsbmuxFrame(_ socket: TimedSocket, until deadline: Deadline) throws -> [String: Any] {
    let length = try usbmuxFrameLength(try socket.readExact(16, until: deadline))
    return try plistDictionary(Data(try socket.readExact(length - 16, until: deadline)))
}

func sendUsbmux(_ socket: TimedSocket, _ body: [String: Any], until deadline: Deadline) throws {
    try socket.writeAll(try usbmuxEncode(body), until: deadline)
}

/// Every failure leaves the public entry points as an IPhoneReadError: the lower layers keep their own typed errors,
/// and this is the one place they are mapped.
func typedReadErrors<T>(_ body: () throws -> T) throws(IPhoneReadError) -> T {
    do { return try body() } catch let error as IPhoneReadError {
        throw error
    } catch let error as UsbmuxFrameError {
        throw IPhoneReadError.usbmux(error)
    } catch let error as PKCS12Error {
        throw IPhoneReadError.identity(error)
    } catch let error as IPhoneParseError {
        throw IPhoneReadError.parse(error)
    } catch {
        throw IPhoneReadError.encoding(String(describing: error))
    }
}

/// One request on its own usbmuxd connection, replied to with one frame.
func usbmuxRequest(_ body: [String: Any]) throws(IPhoneReadError) -> [String: Any] {
    try typedReadErrors {
        let socket = try openUsbmux()
        let deadline = Deadline(after: callDeadline)
        try sendUsbmux(socket, body, until: deadline)
        return try readUsbmuxFrame(socket, until: deadline)
    }
}

/// Every device usbmuxd has attached now, over the cable or Wi-Fi.
func usbmuxListDevices() throws(IPhoneReadError) -> [AttachedDevice] {
    let reply = try usbmuxRequest(["MessageType": "ListDevices", "ClientVersionString": "orange-drink", "ProgName": "orange-drink"])
    return try typedReadErrors { try usbmuxDeviceList(reply) }
}

/// A usbmuxd connection subscribed with Listen. After the reply the same socket carries Attached, Detached, and
/// Paired messages.
func usbmuxListen() throws(IPhoneReadError) -> TimedSocket {
    try typedReadErrors {
        let socket = try openUsbmux()
        let deadline = Deadline(after: callDeadline)
        try sendUsbmux(socket, ["MessageType": "Listen", "ClientVersionString": "orange-drink", "ProgName": "orange-drink"],
                       until: deadline)
        try usbmuxCheckResult(try readUsbmuxFrame(socket, until: deadline))
        return socket
    }
}

/// A usbmuxd Connect to a device's TCP port. After the reply the same socket carries that port's byte stream.
func usbmuxConnect(handle: Int, port: Int) throws(IPhoneReadError) -> TimedSocket {
    // [LAW:no-silent-failure] A port that does not fit the wire field is a typed error; UInt16(port) would trap.
    guard let wirePort = UInt16(exactly: port) else { throw IPhoneReadError.lockdown("Port \(port) out of range") }
    return try typedReadErrors {
        let socket = try openUsbmux()
        let deadline = Deadline(after: callDeadline)
        try sendUsbmux(socket, ["MessageType": "Connect", "DeviceID": handle,
                                "PortNumber": Int(wirePort.bigEndian),
                                "ClientVersionString": "orange-drink", "ProgName": "orange-drink"], until: deadline)
        try usbmuxCheckResult(try readUsbmuxFrame(socket, until: deadline))
        return socket
    }
}

// MARK: - lockdown and the diagnostics relay

/// One lockdown or relay connection: big-endian length-prefixed plists, TLS once the service asks for it.
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
final class PlistStream {
    private let socket: TimedSocket
    private var tls: TLSChannel?

    init(socket: TimedSocket) { self.socket = socket }

    func startTLS(identity: SecIdentity) throws {
        tls = try TLSChannel.handshake(over: socket, identity: identity)
    }

    /// One request and its reply under one deadline. The reply is returned as raw bytes; the caller decodes it.
    func request(_ body: [String: Any]) throws -> [UInt8] {
        let deadline = Deadline(after: callDeadline)
        let payload = [UInt8](try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0))
        let frame = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) } + payload
        if let tls {
            try tls.write(frame, until: deadline)
        } else {
            try socket.writeAll(frame, until: deadline)
        }
        let header = try read(4, until: deadline)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        // The bound the usbmux path applies: a corrupt length must not allocate gigabytes before any check.
        guard (0...maxFrameLength).contains(length) else { throw IPhoneReadError.replyTooLarge(length) }
        return try read(length, until: deadline)
    }

    private func read(_ n: Int, until deadline: Deadline) throws -> [UInt8] {
        if let tls { return try tls.read(n, until: deadline) }
        return try socket.readExact(n, until: deadline)
    }
}

/// The reply plist, with the control bytes a serial-number string can carry stripped first (XML forbids them).
/// [LAW:single-enforcer] Every lockdown and relay reply passes here, so a refusal is thrown once, before any caller
/// reads a key the refusal does not carry.
func decodeReply(_ bytes: [UInt8]) throws -> [String: Any] {
    let reply = try plistDictionary(Data(bytes.filter { !($0 < 0x20 && ![0x09, 0x0a, 0x0d].contains($0)) }))
    if let error = reply["Error"] { throw IPhoneReadError.refused(String(describing: error)) }
    return reply
}

/// One battery read from the device behind a usbmuxd handle: a lockdown session, the diagnostics relay, and the
/// IORegistry IOPMPowerSource entry. IOPMPowerSource, not its AppleSmartBattery subclass: the Vision Pro publishes its
/// battery only under the superclass (orange-iphone-watch-lm3.7iy cmt-9996a69e).
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
/// Every outcome leaves one line in the log.
func readIPhoneBattery(handle: Int, udid: String) throws(IPhoneReadError) -> IPhoneBatteryReading {
    do {
        let reading = try typedReadErrors { try readBattery(handle: handle, udid: udid) }
        IPhoneMonitor.log.info("iphone read: \(udid, privacy: .public) handle \(handle): \(String(describing: reading), privacy: .public)")
        return reading
    } catch {
        IPhoneMonitor.log.error("iphone read failed: \(udid, privacy: .public) handle \(handle): \(String(describing: error), privacy: .public)")
        throw error
    }
}

/// The longest one battery read can take: readBattery's eight calls (ReadPairRecord, Connect, StartSession, session TLS,
/// StartService, Connect, relay TLS, IORegistry), each under callDeadline, which a socket notices on its next
/// one-second wake-up. A step added to openLockdown or readBattery is a step added here.
let readWorstCase = (callDeadline + .seconds(1)) * 8

/// Switches the device's Wi-Fi sync, the box Finder labels "Show this iPhone when on Wi-Fi", on or off. On, usbmuxd
/// reaches the device over the network once the cable is out. Every outcome leaves one line in the log.
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport, the only client-identity TLS that lockdown accepts here; see lm3.8pk")
func setIPhoneWifiSync(_ on: Bool, handle: Int, udid: String) throws(IPhoneReadError) {
    let state = on ? "on" : "off"
    do {
        try typedReadErrors {
            let lockdown = try openLockdown(handle: handle, udid: udid)
            _ = try decodeReply(try lockdown.stream.request(["Request": "SetValue", "Domain": "com.apple.mobile.wireless_lockdown",
                                                             "Key": "EnableWifiConnections", "Value": on]))
        }
        IPhoneMonitor.log.info("iphone wifi sync \(state, privacy: .public): \(udid, privacy: .public) handle \(handle)")
    } catch {
        IPhoneMonitor.log.error("iphone wifi sync \(state, privacy: .public) failed: \(udid, privacy: .public) handle \(handle): \(String(describing: error), privacy: .public)")
        throw error
    }
}

/// A lockdown session with the device behind a usbmuxd handle, under the host identity from its pair record: the trust
/// the user granted with "Trust This Computer", with no pairing of our own.
@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport; see lm3.8pk")
private struct Lockdown {
    let stream: PlistStream
    let identity: SecIdentity
}

@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport; see lm3.8pk")
private func openLockdown(handle: Int, udid: String) throws -> Lockdown {
    // [LAW:no-silent-failure] macOS 14 has no memory-only import, so the reader refuses to run there rather than write
    // the host key into a keychain. Checked first, so the pair record's private key is never loaded on a Mac that
    // cannot use it. Whether the deployment target moves to 15 is the owner's call.
    guard #available(macOS 15.0, *) else { throw IPhoneReadError.unsupported("reading an iPhone needs macOS 15") }
    let record = try usbmuxRequest(["MessageType": "ReadPairRecord", "PairRecordID": udid,
                                    "ClientVersionString": "orange-drink", "ProgName": "orange-drink"])
    let pair = try plistDictionary(try usbmuxPairRecord(record))
    guard let hostID = pair["HostID"] as? String, let systemBUID = pair["SystemBUID"] as? String,
          let certPEM = pair["HostCertificate"] as? Data, let keyPEM = pair["HostPrivateKey"] as? Data else {
        throw IPhoneReadError.lockdown("pair record")
    }
    let identity = try pairIdentity(certificatePEM: certPEM, keyPEM: keyPEM)

    let stream = PlistStream(socket: try usbmuxConnect(handle: handle, port: 62078))
    let session = try decodeReply(try stream.request(["Request": "StartSession", "HostID": hostID, "SystemBUID": systemBUID]))
    if session["EnableSessionSSL"] as? Bool == true { try stream.startTLS(identity: identity) }
    return Lockdown(stream: stream, identity: identity)
}

@available(macOS, deprecated: 10.15, message: "lockdown TLS is SecureTransport; see lm3.8pk")
private func readBattery(handle: Int, udid: String) throws -> IPhoneBatteryReading {
    let lockdown = try openLockdown(handle: handle, udid: udid)
    let service = try decodeReply(try lockdown.stream.request(["Request": "StartService", "Service": "com.apple.mobile.diagnostics_relay"]))
    guard let port = service["Port"] as? Int else { throw IPhoneReadError.lockdown("Port") }

    let relay = PlistStream(socket: try usbmuxConnect(handle: handle, port: port))
    if service["EnableServiceSSL"] as? Bool == true { try relay.startTLS(identity: lockdown.identity) }
    let reply = try decodeReply(try relay.request(["Request": "IORegistry", "EntryClass": "IOPMPowerSource"]))
    return try parseIPhoneBattery(try powerSourceEntry(reply))
}

/// The entry inside an IORegistry reply. A Success with no Diagnostics is the relay's way of saying it found none.
func powerSourceEntry(_ reply: [String: Any]) throws(IPhoneReadError) -> [String: Any] {
    guard let diagnostics = reply["Diagnostics"] else {
        throw reply["Status"] as? String == "Success" ? .noPowerSource : .lockdown("Diagnostics")
    }
    guard let entry = (diagnostics as? [String: Any])?["IORegistry"] as? [String: Any] else {
        throw .lockdown("Diagnostics.IORegistry")
    }
    return entry
}
