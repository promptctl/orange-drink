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

    @Test func aSweepReplacesTheListSoALateReportLeavesNoGhost() {
        var list = DeviceList()
        list.apply(.reported(Self.mouse))
        list.apply(.reported(Self.pods))
        // The mouse disconnected, but a sweep that had read it as connected reported it afterwards.
        list.apply(.gone(Self.mouse.id))
        list.apply(.reported(Self.mouse))
        list.apply(.swept([Self.pods]))
        #expect(list.devices == [Self.pods])
    }

    @Test func aSweepNamingADeviceTwiceKeepsTheLaterOne() {
        var list = DeviceList()
        let renamed = Device(id: Self.mouse.id, name: "Renamed", kind: .accessory, levels: .none)
        list.apply(.swept([Self.mouse, renamed]))
        #expect(list.devices == [renamed])
    }

    @Test func aReplayedReportChangesNothing() {
        var list = DeviceList()
        list.apply(.reported(Self.mouse))
        let once = list
        list.apply(.reported(Self.mouse))
        #expect(list == once)
    }

    @Test func lowestIsTheLevelThatRunsOutFirst() {
        // The case at 80% and a bud at 50%: the bud runs out first. With no bud reporting, the case is all there is.
        #expect(Self.pods.levels.lowest == BatteryLevel(percent: 50, approximate: true))
        #expect(DeviceLevels.earbuds(left: nil, right: nil, case: BatteryLevel(percent: 10, approximate: false)).lowest == BatteryLevel(percent: 10, approximate: false))
        #expect(DeviceLevels.earbuds(left: BatteryLevel(percent: 60, approximate: false), right: nil, case: BatteryLevel(percent: 10, approximate: false)).lowest == BatteryLevel(percent: 60, approximate: false))
        #expect(Self.mouse.levels.lowest == BatteryLevel(percent: 37, approximate: false))
        #expect(DeviceLevels.none.lowest == nil)
    }

    @Test func aConnectedDeviceWithNoLevelIsLeftOutOfTheRankingAndAnUnreadOneIsNot() {
        let keyboard = Device(id: DeviceID(address: "EE"), name: "Keyboard", kind: .accessory, levels: .none)
        let speaker = Device(id: DeviceID(address: "DD"), name: "Speaker", kind: .accessory, levels: .unread)
        var list = DeviceList()
        list.apply(.swept([Self.mouse, keyboard, speaker]))
        #expect(DeviceRanking.rows(list).map(\.id) == [Self.mouse.id, speaker.id])
        #expect(DeviceRanking.unlevelled(list) == [DeviceRow(id: keyboard.id, name: "Keyboard", kind: .accessory, level: nil)])
    }

    @Test(arguments: [
        (UInt32(0x02), "Pixel", DeviceKind.phone), (0, "Brandon’s iPhone", .phone), (0, "Brandon’s iPad", .tablet),
        (0x04, "Beats Studio Buds +", .accessory), (0x05, "Magic Trackpad", .accessory), (0, "DISTO X3", .accessory),
        (0, "Hipad Speaker", .accessory),
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

    @Test func powerdGoingSilentIsNoFailureAndItsNextAnswerRestoresTheRow() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events)
        let sources = DeviceReaderTests.Sources(unanswered: .unanswered(call: "the model's outage"))
        send.yield(sources.reader.sweep([DeviceReaderTests.peer]))
        let silent = await list(of: model) { !$0.devices.isEmpty }
        #expect(DeviceRanking.rows(silent).map(\.percent) == ["–"])
        sources.unanswered = nil
        send.yield(sources.reader.sweep([DeviceReaderTests.peer]))
        let answered = await list(of: model) { $0.devices.first?.levels != .unread }
        #expect(DeviceRanking.rows(answered).map(\.percent) == ["47%"])
        #expect(model.list.unread != .ended)
    }

    @Test func aFinishedStreamIsAFailureNotAFrozenList() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events)
        send.yield(.reported(DeviceListTests.mouse))
        _ = await list(of: model) { $0.devices.count == 1 }
        send.finish()
        let ended = await list(of: model) { $0.unread == .ended }
        #expect(ended.devices.isEmpty)
    }

    @Test func aFailedSubscriptionIsOnTheModel() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let model = DevicesModel(events: events)
        send.finish(throwing: BluetoothDevicesError.registration)
        _ = await list(of: model) { $0.unread == .ended }
    }

    @Test func onChangeIsToldOfTheEndedList() async {
        let (events, send) = AsyncThrowingStream.makeStream(of: DeviceEvent.self)
        let (told, tell) = AsyncStream.makeStream(of: DeviceList.self)
        let model = DevicesModel(events: events, onChange: { tell.yield($0) })
        send.finish()
        var lists = told.makeAsyncIterator()
        #expect(await lists.next()?.unread == .ended)
        _ = model
    }
}

// [LAW:verifiable-goals] The ticket's step on a real Mac, run by `make devices-check`: the first
// sweep's devices held to what macOS reports at the same moment: system_profiler, the source System Settings
// renders, for which devices are connected and the parts it gives levels for, and power management's accessory
// list (`pmset -g accps`) for the levels system_profiler leaves out. Every connected device either one gives a
// level for is in the sweep, and each level agrees.
@MainActor struct DevicesLive {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICES_CHECK"] != nil, "run by make devices-check with devices connected"))
    func matchesSystemProfiler() async throws {
        let connected = try Self.profilerConnected()
        try #require(!connected.isEmpty, "this check needs paired devices connected")
        let accessories = try Self.accessoryLevels()
        let log = try BatteryLog(category: "devices")
        // The first sweep is the whole connected set, and a refused host never sweeps, so the refusal ends the wait for it.
        var list = DeviceList()
        let (seen, see) = AsyncStream.makeStream(of: Seen.self)
        let subscription = Self.subscribe(see)
        defer { subscription.cancel() }
        sweep: for await next in seen {
            guard case .event(let event) = next else { continue }
            list.apply(event)
            switch event {
            case .permission(.notDetermined): print("answer the Bluetooth prompt: Allow the test host")
            case .permission(.denied), .swept: break sweep
            default: continue
            }
        }
        try #require(list.unread == nil, "macOS refused this test host Bluetooth, so nothing swept")
        try #require(!list.devices.contains { $0.levels == .unread }, "powerd did not answer the sweep; the devices log names the call")
        // system_profiler names its devices and nothing more, so the name is the only key the two lists share.
        let swept = try Dictionary(list.devices.map { ($0.name, $0) }) { _, _ in
            throw DevicesLiveError.sharedName(list.devices.map(\.name))
        }
        for device in list.devices {
            printForTheRecord("device: \(device.name) | \(device.kind) | \(device.levels)"
                              + (connected[device.name] == nil ? " | not listed by system_profiler" : ""))
        }
        printForTheRecord("pmset accessories: \(accessories.sorted { $0.key < $1.key })")
        // The sweep's line counts the devices power management had no battery for: each one the sweep holds with no levels.
        let unlevelled = list.devices.filter { $0.levels == .none }.count
        #expect(try await log.logged("no battery for \(unlevelled) "), "the sweep's line does not count \(unlevelled) devices with no battery")
        var compared = 0
        for (name, profiled) in connected {
            // pmset names an earbud set's case "<name> Case" and gives one level for a single-part device.
            var reported = profiled
            if reported.isEmpty { reported["Single"] = accessories[name] }
            if reported["Case"] == nil { reported["Case"] = accessories["\(name) Case"] }
            guard !reported.isEmpty else { continue }
            guard let device = swept[name] else {
                Issue.record("macOS reports \(name) connected at \(reported); the app's sweep does not have it")
                continue
            }
            compared += 1
            let ours = Self.percents(device.levels)
            #expect(Set(ours.keys) == Set(reported.keys), "\(name) reports parts \(ours) where macOS reports \(reported)")
            // The reads are moments apart; a level moves by at most a point or two between them.
            for (part, percent) in ours { #expect(abs(percent - (reported[part] ?? percent)) <= 2, "\(name) \(part)") }
        }
        #expect(compared > 0, "macOS gives a level for none of the connected devices \(connected.keys.sorted()), so nothing was compared")
        try await holdsToAsks(seen)
    }

    /// What a new manager says on a real radio, read from the asks and not the sweeps: the second sweep is the settle sweep of
    /// the connects a registration replays, and a stalled ask sweeps too. Resetting the grant takes the host's bundle identifier,
    /// which it shares with any installed copy of the app, so that copy asks again at its next launch.
    private func holdsToAsks(_ seen: AsyncStream<Seen>) async throws {
        let (timed, _) = await Self.nextAsk(seen)
        printForTheRecord("a timed ask of an allowed host: \(String(describing: timed))")
        try #require(timed == .heard(.allowed), "a new manager did not answer an allowed host on a real radio")
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let reset = try ChildProcess.run("/usr/bin/tccutil", ["reset", "BluetoothAlways", identifier])
        try #require(reset.status == 0, "tccutil exited \(reset.status): \(reset.errors)")
        var (refused, heard) = await Self.nextAsk(seen)
        // A sweep or two of the minute the grant went in can land before the ask that hears it.
        while refused == .heard(.allowed) { (refused, heard) = await Self.nextAsk(seen) }
        printForTheRecord("the ask after the grant was taken away: \(String(describing: refused))")
        try #require(refused == .heard(.denied), "a new manager did not refuse a host whose grant was taken away")
        let (further, after) = await Self.nextAsk(seen)
        #expect(further == .heard(.denied), "the ask after the refusal said \(String(describing: further))")
        let list = heard + after
        #expect(list.contains(.permission(.denied)), "the refusal never reached the list")
        let reads = list.drop { $0 != .permission(.denied) }.filter {
            if case .swept = $0 { true } else if case .reported = $0 { true } else { false }
        }
        #expect(reads.isEmpty, "the host read devices after its refusal: \(reads)")
    }

    /// What the check watches: the events, and the asks that led to them, in one order.
    enum Seen: Sendable {
        case asked(BluetoothPermission.Ask)
        case event(DeviceEvent)
    }

    private static func subscribe(_ see: AsyncStream<Seen>.Continuation) -> Task<Void, any Error> {
        let events = BluetoothDevices.events(asks: { timekeeper in
            let (asks, ask) = AsyncStream.makeStream(of: BluetoothPermission.Ask.self)
            let real = BluetoothPermission.asks(timekeeper: timekeeper)
            let tee = Task {
                for await asked in real {
                    see.yield(.asked(asked))
                    ask.yield(asked)
                }
            }
            ask.onTermination = { _ in tee.cancel() }
            return asks
        })
        return Task { for try await event in events { see.yield(.event(event)) } }
    }

    /// The next ask, and the events ahead of it.
    private static func nextAsk(_ seen: AsyncStream<Seen>) async -> (BluetoothPermission.Ask?, [DeviceEvent]) {
        var events: [DeviceEvent] = []
        for await next in seen {
            switch next {
            case .asked(let ask): return (ask, events)
            case .event(let event): events.append(event)
            }
        }
        return (nil, events)
    }

    enum DevicesLiveError: Error { case sharedName([String]) }

    static func percents(_ levels: DeviceLevels) -> [String: Int] {
        switch levels {
        case .none, .unread: [:]
        case .single(let level): ["Single": level.percent]
        case .earbuds(let left, let right, let `case`):
            ["Left": left?.percent, "Right": right?.percent, "Case": `case`?.percent].compactMapValues { $0 }
        }
    }

    /// Power management's accessory batteries, name → percent, from `pmset -g accps` lines such as
    /// ` -FluffPods (id=47326758)\t60%; discharging present: true`. The Mac's own battery is left out.
    static func accessoryLevels() throws -> [String: Int] {
        let pmset = try ChildProcess.run("/usr/bin/pmset", ["-g", "accps"])
        try #require(pmset.status == 0, "pmset exited \(pmset.status): \(pmset.errors)")
        let line = /^ -(?<name>.+) \(id=\d+\)\t(?<percent>\d+)%;/.anchorsMatchLineEndings()
        return Dictionary(String(decoding: pmset.output, as: UTF8.self).matches(of: line)
            .filter { !$0.name.hasPrefix("InternalBattery") }
            .map { (String($0.name), Int($0.percent)!) }) { first, _ in first }
    }

    /// name → "Left"/"Right"/"Case"/"Single" → percent, for every connected device with a name.
    static func profilerConnected() throws -> [String: [String: Int]] {
        let profiler = try ChildProcess.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        try #require(profiler.status == 0, "system_profiler exited \(profiler.status): \(profiler.errors)")
        let root = try #require(try JSONSerialization.jsonObject(with: profiler.output) as? [String: Any])
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

// [LAW:verifiable-goals] orange-devices-bue.suy: IOBluetooth answers "" for a device it has no name for yet.
struct DeviceNameTests {
    @Test func theAliasIsTheName() {
        #expect(Device.name(alias: "Brandon’s Beats", broadcast: "Beats", address: "AA") == "Brandon’s Beats")
    }

    @Test func aBlankAliasFallsToTheBroadcastName() {
        #expect(Device.name(alias: "", broadcast: "SpaceGoggles2", address: "AA") == "SpaceGoggles2")
        #expect(Device.name(alias: "  ", broadcast: "SpaceGoggles2", address: "AA") == "SpaceGoggles2")
    }

    @Test func aNameIsTrimmed() {
        #expect(Device.name(alias: " Beats\n", broadcast: nil, address: "AA") == "Beats")
        #expect(Device.name(alias: nil, broadcast: "  ", address: "AA") == "AA")
        #expect(Device.name(alias: nil, broadcast: "X", address: "AA") == "X")
    }

    @Test func noNameAtAllFallsToTheAddress() {
        #expect(Device.name(alias: "", broadcast: "", address: "2C-57-CE-D3-A7-F2") == "2C-57-CE-D3-A7-F2")
        #expect(Device.name(alias: nil, broadcast: nil, address: "AA") == "AA")
    }
}
