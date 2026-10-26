import Foundation
import os
import Security
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The in-process PKCS#12 yields an identity carrying the pair record's certificate, and a TLS
// handshake with that identity is bound by the call deadline.
@Suite(.serialized) struct PairIdentity {
    @available(macOS 15.0, *)
    @Test func theInProcessPKCS12CarriesThePairRecordsCertificate() throws {
        let identity = try pairIdentity(certificatePEM: testIdentityCertificatePEM, keyPEM: testIdentityKeyPEM)
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        let der = try #require(certificate.map { SecCertificateCopyData($0) as Data })
        #expect([UInt8](der) == (try pemBody(testIdentityCertificatePEM)))
    }

    /// The PKCS#12 build and import cost about 6 ms of CPU, so one pair record is built into an identity once; a
    /// different record, as a device paired again brings, gets its own.
    @available(macOS 15.0, *)
    @Test func aPairRecordIsBuiltIntoAnIdentityOnce() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        let identities = PairIdentities()
        let first = try identities.identity(certificatePEM: testIdentityCertificatePEM, keyPEM: testIdentityKeyPEM)
        let again = try identities.identity(certificatePEM: testIdentityCertificatePEM, keyPEM: testIdentityKeyPEM)
        #expect(first === again)
        let repaired = try identities.identity(certificatePEM: testIdentityCertificatePEM, keyPEM: testIdentityKeyPEM + Data("\n".utf8))
        #expect(repaired !== first)
        #expect(try await log.count("iphone host identity built: ", awaiting: 2) == 2)
        #expect(try log.messages().filter { $0.hasPrefix("iphone host identity built: ") } == [
            "iphone host identity built: 1 pair records", "iphone host identity built: 2 pair records"])
    }

    /// A device just plugged in is reached by its pacer and its Wi-Fi sync switch at once; its record is built once, so
    /// every caller holds the one identity.
    @available(macOS 15.0, *)
    @Test func aPairRecordAskedForAtOnceIsBuiltOnce() throws {
        let identities = PairIdentities()
        let results = OSAllocatedUnfairLock<[Result<SecIdentity, any Error>]>(uncheckedState: [])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let result = Result { try identities.identity(certificatePEM: testIdentityCertificatePEM, keyPEM: testIdentityKeyPEM) }
            results.withLockUnchecked { $0.append(result) }
        }
        let built = try results.withLockUnchecked { $0 }.map { try $0.get() }
        #expect(built.count == 8 && built.allSatisfy { $0 === built[0] })
    }

    @available(macOS 15.0, *)
    @available(macOS, deprecated: 10.15, message: "drives TLSChannel, which uses SecureTransport; see lm3.8pk")
    @Test(.timeLimit(.minutes(1)))
    func aPeerThatNeverAnswersTheClientHelloEndsAsATimeout() throws {
        let identity = try pairIdentity(certificatePEM: testIdentityCertificatePEM, keyPEM: testIdentityKeyPEM)
        let (socket, peer) = try TimedSocketDeadline.pair()
        defer { close(peer) }
        #expect(throws: IPhoneReadError.timeout) { try TLSChannel.handshake(over: socket, identity: identity) }
    }
}
