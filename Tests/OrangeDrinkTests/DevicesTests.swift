import Foundation
import Observation
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The list from simulated reports: no Bluetooth in the room.
struct DeviceListTests {
    static let mouse = Device(id: DeviceID(address: "AA"), name: "Magic Mouse", kind: .accessory,
                              levels: .single(BatteryLevel(percent: 37, approximate: false)))
    static let pods = Device(id: DeviceID(address: "BB"), name: "AirPods", kind: .accessory,
                             levels: .earbuds(left: BatteryLevel(percent: 50, approximate: true), right: nil,
                                              case: BatteryLevel(percent: 80, approximate: false)))

    @Test func holdsEveryReportedDevice() {
        var list = DeviceList()
        list.apply(.reported(Self.pods))
        list.apply(.reported(Self.mouse))
        #expect(list.devices == [Self.pods, Self.mouse])
    }

    @Test func aLevelChangeReplacesTheDevice() {
        var list = DeviceList()
        list.apply(.reported(Self.mouse))
        let drained = Device(id: Self.mouse.id, name: Self.mouse.name, kind: .accessory,
                             levels: .single(BatteryLevel(percent: 36, approximate: false)))
        list.apply(.reported(drained))
        #expect(list.devices == [drained])
    }

    @Test func aDisconnectRemovesTheDevice() {
        var list = DeviceList()
        list.apply(.reported(Self.mouse))
        list.apply(.reported(Self.pods))
        list.apply(.gone(Self.mouse.id))
        #expect(list.devices == [Self.pods])
    }

    @Test func aReplayedReportChangesNothing() {
        var list = DeviceList()
        list.apply(.reported(Self.mouse))
        let once = list
        list.apply(.reported(Self.mouse))
        #expect(list == once)
    }

    @Test func lowestIsTheLevelThatRunsOutFirst() {
        #expect(Self.pods.levels.lowest == BatteryLevel(percent: 50, approximate: true))
        #expect(Self.mouse.levels.lowest == BatteryLevel(percent: 37, approximate: false))
        #expect(DeviceLevels.none.lowest == nil)
    }

    @Test(arguments: [
        (UInt32(0x02), "Pixel", DeviceKind.phone), (0, "Brandon’s iPhone", .phone), (0, "Brandon’s iPad", .tablet),
        (0x04, "Beats Studio Buds +", .accessory), (0x05, "Magic Trackpad", .accessory), (0, "DISTO X3", .accessory),
    ])
    func classifiesByClassThenName(majorClass: UInt32, name: String, kind: DeviceKind) {
        #expect(DeviceKind.classify(majorClass: majorClass, name: name) == kind)
    }
}

@MainActor struct DevicesModelTests {
    /// The list once `accepted` holds for it. [LAW:no-ambient-temporal-coupling] Awaited through Observation, never polled.
    private func list(of model: DevicesModel, once accepted: (DeviceList) -> Bool) async -> DeviceList {
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        while !accepted(model.list) {
            withObservationTracking { _ = model.list } onChange: { change.yield() }
            guard await next.next() != nil else { break }
        }
        return model.list
    }

    @Test func followsReportsLevelChangesAndDisconnects() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events)
        send.yield(.reported(DeviceListTests.mouse))
        send.yield(.reported(DeviceListTests.pods))
        #expect(await list(of: model) { $0.devices.count == 2 }.devices == [DeviceListTests.pods, DeviceListTests.mouse])
        send.yield(.gone(DeviceListTests.mouse.id))
        #expect(await list(of: model) { $0.devices.count == 1 }.devices == [DeviceListTests.pods])
    }

    @Test func aFailedSubscriptionIsOnTheModel() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events)
        send.finish(throwing: BluetoothDevicesError.registration)
        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        var next = changes.makeAsyncIterator()
        while model.failure == nil {
            withObservationTracking { _ = model.failure } onChange: { change.yield() }
            guard await next.next() != nil else { break }
        }
        #expect(model.failure as? BluetoothDevicesError == .registration)
    }
}

// [LAW:verifiable-goals] The ticket's step on a real Mac, run by `make devices-check`: the first
// sweep's devices, printed for comparison with Control Center, and each checked against
// system_profiler, the source System Settings renders, at the same moment.
@MainActor struct DevicesLive {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICES_CHECK"] != nil, "run by make devices-check with devices connected"))
    func matchesSystemProfiler() async throws {
        let connected = try Self.profilerConnected()
        try #require(!connected.isEmpty, "this check needs paired devices connected")
        var list = DeviceList()
        for try await event in BluetoothDevices.events() {
            list.apply(event)
            if connected.keys.allSatisfy({ name in list.devices.contains { $0.name == name } }) { break }
        }
        for device in list.devices {
            print("device: \(device.name) | \(device.kind) | \(device.levels)")
            if let profiled = connected[device.name] {
                #expect(profiled == Self.percents(device.levels), "\(device.name) differs from system_profiler")
            }
        }
    }

    static func percents(_ levels: DeviceLevels) -> [String: Int] {
        switch levels {
        case .none: [:]
        case .single(let level): ["Single": level.percent]
        case .earbuds(let left, let right, let `case`):
            ["Left": left?.percent, "Right": right?.percent, "Case": `case`?.percent].compactMapValues { $0 }
        }
    }

    /// name → "Left"/"Right"/"Case"/"Main" → percent, for every connected device with a name.
    static func profilerConnected() throws -> [String: [String: Int]] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controller = try #require((root["SPBluetoothDataType"] as? [[String: Any]])?.first)
        var result: [String: [String: Int]] = [:]
        for entry in controller["device_connected"] as? [[String: [String: Any]]] ?? [] {
            for (name, properties) in entry {
                func percent(_ key: String) -> Int? { (properties[key] as? String).flatMap { Int($0.dropLast()) } }
                result[name] = ["Left": percent("device_batteryLevelLeft"), "Right": percent("device_batteryLevelRight"),
                                "Case": percent("device_batteryLevelCase"), "Single": percent("device_batteryLevelMain")]
                    .compactMapValues { $0 }
            }
        }
        return result
    }
}
