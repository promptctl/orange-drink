import CommonCrypto
import Foundation
import Security

// [LAW:one-source-of-truth] The pair record's cert and key become a SecIdentity through one path: encode a PKCS#12
// in-process, then SecPKCS12Import reads it. No openssl, no keychain, no temporary files.
// Key: pbeWithSHAAnd3-KeyTripleDES-CBC (RFC 7292 Appendix B KDF). Integrity: HMAC-SHA1 over the AuthenticatedSafe
// (RFC 7292 section 4). Without the MAC SecPKCS12Import rejects the file.

enum PKCS12Error: Error, Equatable {
    case badPEM
    case cryptFailed(Int32)
    case importFailed(OSStatus)
    case noIdentity
}

/// The lockdown host identity: the pair record's certificate and PKCS#8 key, both PEM.
/// Memory-only import (macOS 15+): the key never enters a keychain, so signing needs no keychain access grant. An
/// unsigned host waited on that grant forever in the probe. The reader refuses to run earlier (see openLockdown).
@available(macOS 15.0, *)
func pairIdentity(certificatePEM: Data, keyPEM: Data) throws -> SecIdentity {
    let pfx = try makePKCS12(certDER: try pemBody(certificatePEM), pkcs8DER: try pemBody(keyPEM), password: pfxPassword)
    var items: CFArray?
    let options = [kSecImportExportPassphrase as String: pfxPassword, kSecImportToMemoryOnly as String: true] as CFDictionary
    let status = SecPKCS12Import(pfx as CFData, options, &items)
    guard status == errSecSuccess else { throw PKCS12Error.importFailed(status) }
    guard let first = (items as? [[String: Any]])?.first, let item = first[kSecImportItemIdentity as String] else {
        throw PKCS12Error.noIdentity
    }
    // [LAW:types-are-the-program] The item is checked to be a SecIdentity before it is typed as one.
    let ref = item as CFTypeRef
    guard CFGetTypeID(ref) == SecIdentityGetTypeID() else { throw PKCS12Error.noIdentity }
    return unsafeDowncast(ref as AnyObject, to: SecIdentity.self)
}

// The password only keys this in-process file; nothing is stored.
private let pfxPassword = "orangedrink"

private func derLen(_ n: Int) -> [UInt8] {
    if n < 0x80 { return [UInt8(n)] }
    var bytes: [UInt8] = []
    var v = n
    while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
    return [UInt8(0x80 | bytes.count)] + bytes
}

private func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + derLen(body.count) + body }
private func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
private func octets(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
private func explicit(_ n: UInt8, _ b: [UInt8]) -> [UInt8] { tlv(0xA0 | n, b) }

private func integer(_ v: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    var x = v
    repeat { bytes.insert(UInt8(x & 0xff), at: 0); x >>= 8 } while x > 0
    if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
    return tlv(0x02, bytes)
}

// OID to DER from its arcs, base-128 for the rest. Only the fixed OIDs below are encoded.
private func oid(_ a: [Int]) -> [UInt8] {
    var body: [UInt8] = [UInt8(a[0] * 40 + a[1])]
    for arc in a.dropFirst(2) {
        var chunk: [UInt8] = [UInt8(arc & 0x7f)]
        var v = arc >> 7
        while v > 0 { chunk.insert(UInt8(0x80 | (v & 0x7f)), at: 0); v >>= 7 }
        body += chunk
    }
    return tlv(0x06, body)
}

// RFC 7292 B.2 key derivation with SHA-1 and a BMPString password. Input and output buffers are separate:
// the Hi/Bi update is written into `I` from a copy, never from the buffer it reads.
private func pkcs12KDF(password: String, salt: [UInt8], iterations: Int, id: UInt8, length: Int) -> [UInt8] {
    let u = 20, v = 64
    var pw: [UInt8] = []
    for unit in password.utf16 { pw += [UInt8(unit >> 8), UInt8(unit & 0xff)] }
    pw += [0, 0]
    let D = [UInt8](repeating: id, count: v)
    func fill(_ src: [UInt8]) -> [UInt8] {
        if src.isEmpty { return [] }
        let n = v * ((src.count + v - 1) / v)
        return (0..<n).map { src[$0 % src.count] }
    }
    var I = fill(salt) + fill(pw)
    var out: [UInt8] = []
    for _ in 0..<((length + u - 1) / u) {
        var hash = [UInt8](repeating: 0, count: u)
        let digest = D + I
        CC_SHA1(digest, CC_LONG(digest.count), &hash)
        for _ in 1..<iterations {
            let input = hash
            var next = [UInt8](repeating: 0, count: u)
            CC_SHA1(input, CC_LONG(input.count), &next)
            hash = next
        }
        out += hash
        let B = (0..<v).map { hash[$0 % u] }
        var j = 0
        while j * v < I.count {
            var block = Array(I[(j * v)..<(j * v + v)])
            var carry = 1
            for k in stride(from: v - 1, through: 0, by: -1) {
                let s = Int(block[k]) + Int(B[k]) + carry
                block[k] = UInt8(s & 0xff)
                carry = s >> 8
            }
            I.replaceSubrange((j * v)..<(j * v + v), with: block)
            j += 1
        }
    }
    return Array(out.prefix(length))
}

private func encrypt3DES(key: [UInt8], iv: [UInt8], plain: [UInt8]) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSize3DES)
    var moved = 0
    let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding),
                         key, key.count, iv, plain, plain.count, &out, out.count, &moved)
    guard status == kCCSuccess else { throw PKCS12Error.cryptFailed(status) }
    return Array(out.prefix(moved))
}

/// The DER between a PEM's armor lines. LF or CRLF: Swift reads "\r\n" as one Character, so a split on "\n" alone
/// would never split a CRLF file. An empty body is not DER.
func pemBody(_ pem: Data) throws -> [UInt8] {
    let text = String(decoding: pem, as: UTF8.self)
    let b64 = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
    guard let bytes = Data(base64Encoded: b64), !bytes.isEmpty else { throw PKCS12Error.badPEM }
    return [UInt8](bytes)
}

private func makePKCS12(certDER: [UInt8], pkcs8DER: [UInt8], password: String) throws -> Data {
    let salt: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }
    let iterations = 2048
    let key = pkcs12KDF(password: password, salt: salt, iterations: iterations, id: 1, length: 24)
    let iv = pkcs12KDF(password: password, salt: salt, iterations: iterations, id: 2, length: 8)
    let encrypted = try encrypt3DES(key: key, iv: iv, plain: pkcs8DER)
    let pbeAlg = seq(oid([1, 2, 840, 113549, 1, 12, 1, 3]), seq(octets(salt), integer(iterations)))
    let encryptedKeyInfo = seq(pbeAlg, octets(encrypted))
    // localKeyID ties the key bag to its certificate bag; SecPKCS12Import pairs them by it.
    let localKeyID: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    let bagAttrs = tlv(0x31, seq(oid([1, 2, 840, 113549, 1, 9, 21]), tlv(0x31, octets(localKeyID))))
    let keyBag = seq(oid([1, 2, 840, 113549, 1, 12, 10, 1, 2]), explicit(0, encryptedKeyInfo), bagAttrs)
    let certBagValue = seq(oid([1, 2, 840, 113549, 1, 9, 22, 1]), explicit(0, octets(certDER)))
    let certBag = seq(oid([1, 2, 840, 113549, 1, 12, 10, 1, 3]), explicit(0, certBagValue), bagAttrs)
    let safeContents = seq(keyBag, certBag)
    // AuthenticatedSafe is a SEQUENCE OF ContentInfo; each data ContentInfo wraps one SafeContents.
    let safeContentsInfo = seq(oid([1, 2, 840, 113549, 1, 7, 1]), explicit(0, octets(safeContents)))
    let authenticatedSafe = seq(safeContentsInfo)
    let authSafe = seq(oid([1, 2, 840, 113549, 1, 7, 1]), explicit(0, octets(authenticatedSafe)))
    // Integrity MAC: HMAC-SHA1 over the AuthenticatedSafe bytes, key from the KDF with ID 3.
    let macSalt: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }
    let macKey = pkcs12KDF(password: password, salt: macSalt, iterations: iterations, id: 3, length: 20)
    var mac = [UInt8](repeating: 0, count: 20)
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), macKey, macKey.count, authenticatedSafe, authenticatedSafe.count, &mac)
    let macData = seq(seq(seq(oid([1, 3, 14, 3, 2, 26]), tlv(0x05, [])), octets(mac)), octets(macSalt), integer(iterations))
    return Data(seq(integer(3), authSafe, macData))
}
