import Foundation
import Testing
@testable import OrangeDrink

@Suite struct UsbmuxFrames {
    @Test func headerIsLittleEndianLengthVersionTypeTag() throws {
        let frame = try usbmuxEncode(["MessageType": "ListDevices"], tag: 9)
        #expect(frame.count >= 16)
        #expect(Array(frame[0..<4]) == [UInt8(frame.count & 0xff), UInt8(frame.count >> 8), 0, 0])
        #expect(Array(frame[4..<8]) == [1, 0, 0, 0])
        #expect(Array(frame[8..<12]) == [8, 0, 0, 0])
        #expect(Array(frame[12..<16]) == [9, 0, 0, 0])
    }

    @Test func readerHoldsAPartialFrameUntilItsLengthArrives() throws {
        let frame = try usbmuxEncode(["MessageType": "Result", "Number": 0])
        var reader = UsbmuxFrameReader()
        reader.append(Array(frame[0..<10]))
        #expect(try reader.next() == nil)
        reader.append(Array(frame[10...]))
        let body = try #require(try reader.next())
        #expect(body["MessageType"] as? String == "Result")
        #expect(try reader.next() == nil)
    }

    @Test func readerYieldsTwoFramesFromOneRead() throws {
        var reader = UsbmuxFrameReader()
        reader.append(try usbmuxEncode(["MessageType": "Result", "Number": 0]) + usbmuxEncode(["MessageType": "Detached", "DeviceID": 4]))
        #expect(try reader.next()?["MessageType"] as? String == "Result")
        #expect(try reader.next()?["MessageType"] as? String == "Detached")
    }

    @Test func impossibleLengthIsATypedError() {
        var reader = UsbmuxFrameReader()
        reader.append([4, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0])
        #expect(throws: UsbmuxFrameError.lengthOutOfRange(4)) { try reader.next() }
    }

    @Test func attachedUSBAndNetworkDevicesDecode() throws {
        let usb = try usbmuxEvent(["MessageType": "Attached", "DeviceID": 7,
                                   "Properties": ["ConnectionType": "USB", "SerialNumber": "UDID-1"]])
        #expect(usb == .attached(AttachedDevice(handle: 7, connection: .usb(udid: "UDID-1"))))
        let wifi = try usbmuxEvent(["MessageType": "Attached", "DeviceID": 8,
                                    "Properties": ["ConnectionType": "Network", "SerialNumber": "UDID-1"]])
        #expect(wifi == .attached(AttachedDevice(handle: 8, connection: .network)))
    }

    @Test func detachedAndListenResultDecode() throws {
        #expect(try usbmuxEvent(["MessageType": "Detached", "DeviceID": 7]) == .detached(handle: 7))
        #expect(try usbmuxEvent(["MessageType": "Result", "Number": 0]) == .other)
        #expect(throws: UsbmuxFrameError.nonZeroResult(5)) { try usbmuxEvent(["MessageType": "Result", "Number": 5]) }
    }

    @Test func unknownConnectionTypeIsADeviceThatIsNotTheCable() throws {
        let event = try usbmuxEvent(["MessageType": "Attached", "DeviceID": 1,
                                     "Properties": ["ConnectionType": "Bluetooth", "SerialNumber": "X"]])
        #expect(event == .attached(AttachedDevice(handle: 1, connection: .other("Bluetooth"))))
        #expect(throws: UsbmuxFrameError.missingKey("ConnectionType")) {
            try usbmuxEvent(["MessageType": "Attached", "DeviceID": 1, "Properties": ["SerialNumber": "X"]])
        }
    }

    @Test func pairRecordReplyIsTheRecordOrNotTrusted() throws {
        #expect(try usbmuxPairRecord(["PairRecordData": Data([1, 2])]) == Data([1, 2]))
        // The reply usbmuxd gave for an unknown UDID.
        #expect(throws: UsbmuxFrameError.noPairRecord) { try usbmuxPairRecord(["MessageType": "Result", "Number": 2]) }
        #expect(throws: UsbmuxFrameError.missingKey("PairRecordData")) { try usbmuxPairRecord(["MessageType": "Result", "Number": 0]) }
    }

    @Test func listDevicesDecodesEveryEntry() throws {
        let devices = try usbmuxDeviceList(["DeviceList": [
            ["DeviceID": 4, "Properties": ["ConnectionType": "USB", "SerialNumber": "A"]],
            ["DeviceID": 5, "Properties": ["ConnectionType": "Network", "SerialNumber": "A"]],
        ]])
        #expect(devices == [AttachedDevice(handle: 4, connection: .usb(udid: "A")),
                            AttachedDevice(handle: 5, connection: .network)])
        #expect(throws: UsbmuxFrameError.missingKey("DeviceList")) { try usbmuxDeviceList([:]) }
    }
}
