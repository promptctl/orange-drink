// Spike (orange-iphone-watch-lm3.8pk), build: swiftc -swift-version 5 -O main.swift pkcs12.swift -o probe
// Run: ./probe <usbmux DeviceID>   (DeviceID changes between sessions; read it from ListDevices)
//
// Verified end to end from Swift against a Wi-Fi-connected iPhone: the pair record's cert and key are
// encoded into an in-process PKCS#12 (pkcs12.swift) and imported with SecPKCS12Import; session TLS,
// StartService, relay TLS, and IORegistry AppleSmartBattery all complete. No openssl, no keychain.
// Prints key names and battery numbers only, never pairing material.
import Foundation
import Security

// Not exported to Swift; value from Security/SecureTransport.h.
let errSSLServerAuthCompleted: OSStatus = -9841

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

func usbmuxConnect() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket failed") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, "/var/run/usbmuxd") }
    }
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { fail("connect usbmuxd failed") }
    return fd
}

func readExact(_ fd: Int32, _ n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
        guard r > 0 else { fail("short read") }
        got += r
    }
    return out
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    while sent < bytes.count {
        let r = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
        guard r > 0 else { fail("send failed") }
        sent += r
    }
}

func plistXML(_ dict: [String: Any]) -> [UInt8] {
    [UInt8](try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0))
}

func usbmuxRequest(_ dict: [String: Any]) -> [String: Any] {
    let fd = usbmuxConnect()
    defer { close(fd) }
    let body = plistXML(dict)
    var header = [UInt8]()
    for v in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
    writeAll(fd, header + body)
    return readUsbmuxReply(fd)
}

func readUsbmuxReply(_ fd: Int32) -> [String: Any] {
    let h = readExact(fd, 16)
    let n = Int(UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24)
    let body = readExact(fd, n - 16)
    return try! PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as! [String: Any]
}

// Session over an open usbmux connection: optional TLS, length-prefixed plists (big-endian).
final class Session {
    let fd: Int32
    var ssl: SSLContext?
    init(fd: Int32) { self.fd = fd }

    func send(_ dict: [String: Any]) {
        let p = plistXML(dict)
        var frame = [UInt8]()
        withUnsafeBytes(of: UInt32(p.count).bigEndian) { frame += $0 }
        frame += p
        if let ssl { sslWrite(ssl, frame) } else { writeAll(fd, frame) }
    }

    func recv() -> [String: Any] {
        let len = readBytes(4)
        let n = Int(len[0]) << 24 | Int(len[1]) << 16 | Int(len[2]) << 8 | Int(len[3])
        // Control bytes can appear in a serial-number string that XML forbids; strip them (as battery_ioreg.py does).
        let body = readBytes(n).filter { !($0 < 0x20 && ![0x09, 0x0a, 0x0d].contains($0)) }
        return try! PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as! [String: Any]
    }

    func readBytes(_ n: Int) -> [UInt8] {
        if let ssl { return sslReadExact(ssl, n) }
        return readExact(fd, n)
    }
}

final class IOBox { let fd: Int32; init(_ fd: Int32) { self.fd = fd } }

let readCB: SSLReadFunc = { conn, data, len in
    let box = Unmanaged<IOBox>.fromOpaque(conn).takeUnretainedValue()
    var got = 0
    let want = len.pointee
    while got < want {
        let r = recv(box.fd, data + got, want - got, 0)
        if r <= 0 { len.pointee = got; return r == 0 ? errSSLClosedGraceful : errSSLClosedAbort }
        got += r
    }
    len.pointee = got
    return noErr
}

let writeCB: SSLWriteFunc = { conn, data, len in
    let box = Unmanaged<IOBox>.fromOpaque(conn).takeUnretainedValue()
    var sent = 0
    let want = len.pointee
    while sent < want {
        let r = send(box.fd, data + sent, want - sent, 0)
        if r <= 0 { len.pointee = sent; return errSSLClosedAbort }
        sent += r
    }
    len.pointee = sent
    return noErr
}

// The box must outlive the context; the Session keeps both.
var boxes: [IOBox] = []

func sslHandshake(fd: Int32, identity: SecIdentity) -> SSLContext {
    guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else { fail("SSLCreateContext") }
    let box = IOBox(fd)
    boxes.append(box)
    SSLSetIOFuncs(ctx, readCB, writeCB)
    SSLSetConnection(ctx, Unmanaged.passUnretained(box).toOpaque())
    SSLSetCertificate(ctx, [identity] as CFArray)
    SSLSetSessionOption(ctx, .breakOnServerAuth, true)
    while true {
        let st = SSLHandshake(ctx)
        print("  handshake status", st)
        if st == errSSLServerAuthCompleted { continue }   // lockdown's cert is not CA-signed; accept it
        if st == noErr { return ctx }
        fail("TLS handshake failed: OSStatus \(st)")
    }
}

func sslWrite(_ ctx: SSLContext, _ bytes: [UInt8]) {
    var sent = 0
    while sent < bytes.count {
        var processed = 0
        let st = bytes.withUnsafeBytes { SSLWrite(ctx, $0.baseAddress! + sent, bytes.count - sent, &processed) }
        guard st == noErr else { fail("SSLWrite OSStatus \(st)") }
        sent += processed
    }
}

func sslReadExact(_ ctx: SSLContext, _ n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        var processed = 0
        let st = out.withUnsafeMutableBytes { SSLRead(ctx, $0.baseAddress! + got, n - got, &processed) }
        guard st == noErr || st == errSSLWouldBlock else { fail("SSLRead OSStatus \(st)") }
        got += processed
    }
    return out
}

func runShell(_ cmd: String, _ args: [String], input: Data? = nil) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out; p.standardInput = inp
    p.standardError = FileHandle.nullDevice
    try! p.run()
    if let input { inp.fileHandleForWriting.write(input) }
    try? inp.fileHandleForWriting.close()
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return d
}

// ---- main ----
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count == 2, let deviceID = Int(args[1]) else { fail("usage: probe <usbmux DeviceID>") }

let listed = usbmuxRequest(["MessageType": "ListDevices", "ClientVersionString": "probe", "ProgName": "probe"])
let entries = listed["DeviceList"] as! [[String: Any]]
guard let entry = entries.first(where: { ($0["DeviceID"] as? Int) == deviceID }),
      let props = entry["Properties"] as? [String: Any], let udid = props["SerialNumber"] as? String else {
    fail("DeviceID \(deviceID) not in ListDevices")
}
print("device connection:", props["ConnectionType"] ?? "?")

let pairReply = usbmuxRequest(["MessageType": "ReadPairRecord", "PairRecordID": udid,
                               "ClientVersionString": "probe", "ProgName": "probe"])
let pair = try! PropertyListSerialization.propertyList(from: pairReply["PairRecordData"] as! Data, options: [], format: nil) as! [String: Any]

// Identity from the pair record's PEM, in-process: cert and key go into a temporary keychain,
// SecIdentity is looked up there, and the keychain is deleted. No openssl, no files left behind.
let hostCert = pair["HostCertificate"] as! Data
let hostKey = pair["HostPrivateKey"] as! Data
func importPEM(_ data: Data, _ type: SecExternalItemType) -> [AnyObject] {
    var fmt = SecExternalFormat.formatUnknown, t = type; var items: CFArray?
    let st = SecItemImport(data as CFData, nil, &fmt, &t, [], nil, nil, &items)
    guard st == errSecSuccess, let found = items as? [AnyObject] else { fail("SecItemImport OSStatus \(st)") }
    return found
}
// Identity: PFX built in-process (pkcs12.swift), imported with SecPKCS12Import. No keychain, no openssl.
let pfx = makePKCS12(certDER: pemBody(hostCert), pkcs8DER: pemBody(hostKey), password: "probe")
var pfxItems: CFArray?
let pfxStatus = SecPKCS12Import(pfx as CFData, [kSecImportExportPassphrase as String: "probe"] as CFDictionary, &pfxItems)
guard pfxStatus == errSecSuccess, let pfxArr = pfxItems as? [[String: Any]], let idAny = pfxArr.first?[kSecImportItemIdentity as String] else {
    fail("SecPKCS12Import of in-process PFX OSStatus \(pfxStatus)")
}
let identityRef = idAny as! SecIdentity
print("identity built in-process")

// Lockdown on the usbmux connection.
let lockFd = usbmuxConnect()
let connReply = { () -> Int in
    let body = plistXML(["MessageType": "Connect", "DeviceID": deviceID,
                         "PortNumber": Int(UInt16(62078).bigEndian), "ClientVersionString": "probe", "ProgName": "probe"])
    var h = [UInt8](); for v in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: v.littleEndian) { h += $0 } }
    writeAll(lockFd, h + body)
    return (readUsbmuxReply(lockFd)["Number"] as? Int) ?? -1
}()
guard connReply == 0 else { fail("lockdown Connect Number \(connReply)") }
let lock = Session(fd: lockFd)
lock.send(["Request": "StartSession", "HostID": pair["HostID"] as! String, "SystemBUID": pair["SystemBUID"] as! String])
let start = lock.recv()
print("StartSession EnableSessionSSL:", start["EnableSessionSSL"] ?? false)
guard start["EnableSessionSSL"] as? Bool == true else { fail("expected session TLS") }
lock.ssl = sslHandshake(fd: lockFd, identity: identityRef)
print("session TLS handshake: OK")

lock.send(["Request": "StartService", "Service": "com.apple.mobile.diagnostics_relay"])
let svc = lock.recv()
print("StartService keys:", svc.keys.sorted().filter { $0 != "SessionID" })
guard let relayPort = svc["Port"] as? Int else { fail("no Port in StartService reply") }

// Relay on its own usbmux connection.
let relayFd = usbmuxConnect()
let body2 = plistXML(["MessageType": "Connect", "DeviceID": deviceID,
                      "PortNumber": Int(UInt16(relayPort).bigEndian), "ClientVersionString": "probe", "ProgName": "probe"])
var h2 = [UInt8](); for v in [UInt32(16 + body2.count), 1, 8, 1] { withUnsafeBytes(of: v.littleEndian) { h2 += $0 } }
writeAll(relayFd, h2 + body2)
guard (readUsbmuxReply(relayFd)["Number"] as? Int) == 0 else { fail("relay Connect failed") }
let relay = Session(fd: relayFd)
if svc["EnableServiceSSL"] as? Bool == true {
    relay.ssl = sslHandshake(fd: relayFd, identity: identityRef)
    print("relay TLS handshake: OK")
}
relay.send(["Request": "IORegistry", "EntryClass": "AppleSmartBattery"])
let reply = relay.recv()
let raw = ((reply["Diagnostics"] as? [String: Any])?["IORegistry"] as? [String: Any]) ?? [:]
print("IORegistry top-level keys:", raw.keys.sorted())
if let bd = raw["BatteryData"] as? [String: Any] {
    print("BatteryData keys include:", ["CurrentCapacity", "NominalChargeCapacity", "DesignCapacity", "AppleRawMaxCapacity"].map { "\($0)=\(bd[$0] ?? "absent")" })
}
print("CycleCount:", raw["CycleCount"] ?? "absent")
