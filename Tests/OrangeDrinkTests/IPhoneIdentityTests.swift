import Foundation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] What lockdown says a device is parses to the name, kind and Bluetooth address its fixture header names,
// and anything the parser cannot stand behind is a typed error: a device is never listed without the address that joins it to its
// Bluetooth twin.
@Suite struct IPhoneIdentityParse {
    static func values(_ xml: String) throws -> [String: Any] {
        try #require(try plistDictionary(Data(xml.utf8))["Device"] as? [String: Any])
    }

    /// The values lockdown answers for a stand-in device.
    static func standIn(name: Any = "Brandon's iPhone", model: Any = "iPhone16,2", address: Any = "6c:3a:ff:d9:74:42") -> [String: Any] {
        ["DeviceName": name, "ProductType": model, "BluetoothAddress": address]
    }

    @Test func aPhoneRecordedFromARealDeviceIsNamedAPhoneAndClaimsItsBluetoothAddress() throws {
        let identity = try parseIPhoneIdentity(try Self.values(iPhone16_2_identityXML))
        #expect(identity == IPhoneIdentity(name: "Test iPhone", productType: "iPhone16,2", bluetooth: try #require(BluetoothAddress("dc-10-57-00-00-01"))))
        #expect(identity.kind == .phone)
    }

    @Test func aVisionProRecordedFromARealDeviceIsNeitherAPhoneNorATablet() throws {
        let identity = try parseIPhoneIdentity(try Self.values(visionPro_identityXML))
        #expect(identity.name == "Test Vision Pro")
        #expect(identity.bluetooth.key == "2c-57-ce-00-00-02")
        #expect(identity.kind == .accessory)
    }

    @Test func aReplyCarryingTheNameBrandonsIPhoneAndModeliPhone16_2IsThatNameAndAPhone() throws {
        let identity = try parseIPhoneIdentity(Self.standIn())
        #expect(identity.name == "Brandon's iPhone")
        #expect(identity.kind == .phone)
        #expect(identity.bluetooth == BluetoothAddress("6c-3a-ff-d9-74-42"))
    }

    @Test func aReplyCarryingModeliPad13_1IsATablet() throws {
        #expect(try parseIPhoneIdentity(Self.standIn(name: "Studio iPad", model: "iPad13,1")).kind == .tablet)
    }

    /// What kind a model is, by the shape Apple's identifiers have: the family name, digits, a comma, digits, and nothing
    /// else on either side.
    @Test(arguments: [
        ("iPhone16,2", DeviceKind.phone), ("iPhone8,1", .phone), ("iPad13,1", .tablet), ("iPad8,12", .tablet),
        ("iPod9,1", .accessory), ("RealityDevice14,1", .accessory), ("Watch7,1", .accessory),
        ("iPhone", .accessory), ("iPhone16", .accessory), ("MyiPhone16,2", .accessory), ("iPhone16,2 Pro", .accessory),
        ("iPadPro1,1", .accessory), ("", .accessory), ("iPhone\u{661}\u{666},\u{662}", .accessory),
    ])
    func aModelIsAPhoneOrATabletOnlyByItsIdentifiersShape(model: String, kind: DeviceKind) {
        #expect(DeviceKind(productType: model) == kind)
    }

    @Test func aBlankNameIsAnIdentityAndIsLeftToTheDeviceNameChoiceToReplace() throws {
        #expect(try parseIPhoneIdentity(Self.standIn(name: "")).name == "")
    }

    @Test(arguments: IPhoneIdentity.lockdownKeys)
    func aMissingKeyIsATypedErrorNamingIt(key: String) {
        var reply = Self.standIn()
        reply[key] = nil
        #expect(throws: IPhoneParseError.missingKey(key)) { try parseIPhoneIdentity(reply) }
    }

    @Test(arguments: IPhoneIdentity.lockdownKeys)
    func aValueOfAnotherTypeIsATypedErrorNamingTheKey(key: String) {
        var reply = Self.standIn()
        reply[key] = 7
        #expect(throws: IPhoneParseError.wrongType(key)) { try parseIPhoneIdentity(reply) }
    }

    /// A phone listed without its claim would be its own row beside its Bluetooth twin, so an address that is not one fails the read.
    @Test(arguments: ["", "not an address", "6c:3a:ff:d9:74", "6c:3a:ff:d9:74:42:00", "6c:3a:ff:d9:74:zz", "6c:3a-ff:d9-74:42"])
    func anAddressThatIsNotOneIsATypedError(address: String) {
        #expect(throws: IPhoneParseError.invalid("BluetoothAddress")) { try parseIPhoneIdentity(Self.standIn(address: address)) }
    }

    @Test func theLockdownKeysAreExactlyTheKeysTheParserReads() throws {
        // Every key the edge asks for is needed, and the parser needs no key the edge does not ask for.
        let reply = Self.standIn()
        #expect(Set(reply.keys) == Set(IPhoneIdentity.lockdownKeys))
        #expect(try parseIPhoneIdentity(reply.merging(["Extra": "ignored"]) { $1 }) == parseIPhoneIdentity(reply))
    }

    @Test func theReadsLogLineNamesTheModelKindAndAddressAndNotTheUsersName() throws {
        let line = String(describing: try parseIPhoneIdentity(try Self.values(iPhone16_2_identityXML)))
        #expect(line == "iPhone16,2 (phone), bluetooth dc-10-57-00-00-01")
    }
}
