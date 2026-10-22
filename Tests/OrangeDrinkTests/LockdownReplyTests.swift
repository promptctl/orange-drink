import Foundation
import Testing
@testable import OrangeDrink

@Suite struct LockdownReplies {
    private func frame(_ body: [String: Any]) throws -> [UInt8] {
        [UInt8](try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0))
    }

    @Test func anErrorReplyIsARefusalNotAMissingKey() throws {
        let locked = try frame(["Request": "StartService", "Error": "PasswordProtected"])
        #expect(throws: IPhoneReadError.refused("PasswordProtected")) { try decodeReply(locked) }
        let reply = try decodeReply(try frame(["Request": "StartService", "Port": 51234]))
        #expect(reply["Port"] as? Int == 51234)
    }

    @Test func pemBodyReadsCRLFAndRejectsAnEmptyBody() throws {
        let lf = Data("-----BEGIN CERTIFICATE-----\nAQID\nBA==\n-----END CERTIFICATE-----\n".utf8)
        let crlf = Data("-----BEGIN CERTIFICATE-----\r\nAQID\r\nBA==\r\n-----END CERTIFICATE-----\r\n".utf8)
        #expect(try pemBody(lf) == [1, 2, 3, 4])
        #expect(try pemBody(crlf) == [1, 2, 3, 4])
        #expect(throws: PKCS12Error.badPEM) {
            try pemBody(Data("-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n".utf8))
        }
    }
}
