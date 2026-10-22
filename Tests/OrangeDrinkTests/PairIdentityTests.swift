import Foundation
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
