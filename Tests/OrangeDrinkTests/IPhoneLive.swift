import Foundation
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The ticket's hardware step: plugging in a trusted iPhone switches on its Wi-Fi sync and reads it
// over the cable; once the cable is pulled, Wi-Fi readings or typed Wi-Fi read failures keep coming, a poll interval
// apart however often usbmuxd drops and relists the device. Run by make iphone-check with the iPhone cabled and a person
// at the cable. What a read costs is make test's: IPhoneMonitorDecisions counts the relays opened, which is the cost.
//
// Every read is held to the monitor's pacing, measured against the check's own usbmuxd Listen rather than a guess at
// usbmuxd's gaps: no read comes sooner than a poll interval after the one before, and none later than readWorstCase
// after the device's first listing once that rest is over, each give or take monitorLatency. A device usbmuxd does not
// list again fails naming usbmuxd.
@Suite(.serialized) struct IPhoneLive {
    /// How late the monitor may act on time or on usbmuxd (a pacer waking from its rest, a listing change reported), and
    /// how late this check may stamp an event's arrival.
    private static let monitorLatency = Duration.seconds(1)
    /// How long the check waits for usbmuxd to list the device again before it blames usbmuxd: longer than the 56 min
    /// it left an iPhone unlisted after a Wi-Fi sync switch-off (lm3.1tt cmt-9a8a2ba7), the step this check starts with.
    private static let usbmuxWait = Duration.seconds(60 * 60)
    /// Wi-Fi read events the phase is held to after its first.
    private static let wifiWindows = 3
    /// The cable phase, the person's pull, then every read at its latest: a run that hits it is one no bound above caught.
    static let timeLimitMinutes = 2 + 10 + (wifiWindows + 1) * Int(((IPhoneMonitor.pollInterval + monitorLatency + usbmuxWait + readWorstCase) / .seconds(60)).rounded(.up))

    @available(macOS, deprecated: 10.15, message: "drives IPhoneMonitor, which uses SecureTransport; see lm3.8pk")
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IPHONE_CHECK"] != nil, "run by make iphone-check with a cabled iPhone"),
          .timeLimit(.minutes(IPhoneLive.timeLimitMinutes)))
    func switchesOnWifiSyncThenKeepsReadingOverWifiOnceTheCableIsPulled() async throws {
        let log = try BatteryLog(category: IPhoneMonitor.logCategory)
        // The one cabled device's Wi-Fi sync is switched off before the monitor starts, so the monitor is what switches it on.
        let cabled = try usbmuxListDevices().compactMap { device -> (handle: Int, udid: String)? in
            guard case .device(let udid, .usb) = device.connection else { return nil }
            return (device.handle, udid)
        }
        try #require(cabled.count == 1, "this check needs exactly one cabled iPhone or iPad; usbmuxd lists \(cabled.count)")
        let (handle, udid) = cabled[0]
        try setIPhoneWifiSync(false, handle: handle, udid: udid, identities: PairIdentities())
        printForTheRecord("wifi sync off: \(udid)")

        let listing = try Listing(udid: udid)
        defer { listing.stop() }
        let arrivals = Arrivals()
        let consumer = Task { for await event in IPhoneMonitor.events() { arrivals.append(event) } }
        defer { consumer.cancel() }
        var cursor = 0
        var reachability: [Transport?] = []

        // The cable: one reading over USB and the Wi-Fi sync switch, for that device.
        var cableRead: ContinuousClock.Instant?
        var cableReading: IPhoneBatteryReading?
        var synced = false
        let cableEnd = ContinuousClock.now + .seconds(120)
        while cableRead == nil || !synced {
            let (event, at) = try #require(try await arrivals.event(at: cursor, until: { .now > cableEnd }),
                                           "no cable reading and Wi-Fi sync within two minutes; the monitor reported \(udid) as \(reachability.map { $0.map { "\($0)" } ?? "unreachable" })")
            cursor += 1
            switch event {
            case .reachable(udid, let transport): reachability.append(transport)
            case .unreachable(udid): reachability.append(nil)
            case .reading(udid, .usb, let value):
                cableRead = at
                cableReading = value
                printForTheRecord("cable reading: \(value)")
            case .wifiSyncOn(udid):
                synced = true
                printForTheRecord("wifi sync on: \(udid)")
            case .wifiSyncFailed(udid, let error), .readFailed(udid, _, let error), .failed(let error):
                Issue.record("cable phase: \(event) (\(error))")
                return
            default:
                continue
            }
        }
        #expect(try log.messages().contains { $0.hasPrefix("iphone wifi sync on: \(udid) ") })
        print("pull the cable now")

        // Wi-Fi: every read, over the cable until the person pulls it and over Wi-Fi after, is held to the pacing above.
        var previous = try #require(cableRead)
        var wifiEvents = 0
        var wifiReadings = 0
        while wifiEvents <= Self.wifiWindows {
            let restEnd = previous + IPhoneMonitor.pollInterval + Self.monitorLatency
            let expired = { () throws -> Bool in
                guard let listed = try listing.firstListed(atOrAfter: restEnd) else { return .now > restEnd + Self.usbmuxWait }
                return .now > listed + readWorstCase
            }
            guard let arrival = try await arrivals.event(at: cursor, until: expired) else {
                let trigger = try listing.firstListed(atOrAfter: restEnd)
                Issue.record(trigger.map { "the monitor did not read \(udid) within \(readWorstCase) of usbmuxd listing it at \($0)" }
                             ?? "usbmuxd did not list \(udid) over Wi-Fi within \(Self.usbmuxWait) of its rest ending")
                return
            }
            let (event, at) = arrival
            cursor += 1
            switch event {
            case .reachable(udid, let transport):
                reachability.append(transport)
                continue
            case .unreachable(udid):
                reachability.append(nil)
                continue
            case .reading(udid, .network, let value):
                wifiReadings += 1
                printForTheRecord("wifi reading: \(value)")
                // A battery's cycle count and design capacity hold still over minutes, so the two transports read the same.
                #expect(value.cycleCount == cableReading?.cycleCount && value.designCapacity == cableReading?.designCapacity,
                        "the Wi-Fi reading's cycles and design capacity differ from the cable reading's: \(String(describing: cableReading))")
            case .readFailed(udid, .network, let error):
                printForTheRecord("wifi read failed: \(error)")
            case .reading(udid, .usb, _), .readFailed(udid, .usb, _):
                print("still on the cable: pull it")
            case .failed(let error):
                Issue.record("monitor failed: \(error)")
                return
            default:
                continue
            }
            printForTheRecord("read gap: \(at - previous)")
            #expect(at - previous >= IPhoneMonitor.pollInterval - Self.monitorLatency, "reads came faster than the poll interval")
            previous = at
            guard case .network = event.transport else { continue }
            wifiEvents += 1
        }
        #expect(wifiReadings > 0, "every Wi-Fi read failed")

        // The monitor's reachability is usbmuxd's listing of the device, change for change: everything usbmuxd listed
        // up to a moment ago has been reported, and nothing it did not list.
        let listed = try listing.changes()
        printForTheRecord("reachability: monitor \(reachability), usbmuxd \(listed.map(\.transport))")
        #expect(Array(listed.map(\.transport).prefix(reachability.count)) == reachability,
                "the monitor's reachability differs from usbmuxd's listing")
        #expect(reachability.count >= listed.filter { $0.at < .now - Self.monitorLatency }.count,
                "the monitor did not report a listing change usbmuxd made")
    }
}

private extension IPhoneEvent {
    /// The transport a read went over, for the read events.
    var transport: Transport? {
        switch self {
        case .reading(_, let transport, _), .readFailed(_, let transport, _): transport
        default: nil
        }
    }
}

/// The check's own record of how usbmuxd lists one device, from a Listen connection of its own opened before the
/// monitor starts: the independent record the monitor's reachability and pacing are held to. Each change is the
/// transport the device is reached over from then on, the cable preferred, or nil while usbmuxd lists no handle. Once its Listen
/// fails, every read of the record throws that failure, so the check stops on it instead of blaming usbmuxd's silence.
private final class Listing: Sendable {
    struct Change { let at: ContinuousClock.Instant; let transport: Transport? }
    private struct State {
        var handles: [Int: Transport] = [:]
        var changes: [Change] = []
        var stopped = false
        var failure: (any Error)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Subscribes, then takes the snapshot, as the monitor does, and records from a thread of its own until `stop`.
    init(udid: String) throws {
        let socket = try usbmuxListen()
        try usbmuxListDevices().forEach { apply(.attached($0), udid: udid) }
        Thread { [self] in
            var reader = UsbmuxFrameReader()
            do {
                while !state.withLock({ $0.stopped }) {
                    guard let bytes = try socket.receiveSome(max: 4096) else { continue }
                    reader.append(bytes)
                    while let body = try reader.next() { apply(try usbmuxEvent(body), udid: udid) }
                }
            } catch {
                printForTheRecord("the check's own Listen failed: \(error)")
                state.withLock { $0.failure = error }
            }
        }.start()
    }

    func stop() { state.withLock { $0.stopped = true } }

    func changes() throws -> [Change] { try record { $0.changes } }

    /// The first moment at or after `instant` that usbmuxd lists the device, once it has.
    func firstListed(atOrAfter instant: ContinuousClock.Instant) throws -> ContinuousClock.Instant? {
        try record { state in
            let listedThen = state.changes.last { $0.at <= instant }?.transport != nil
            return listedThen ? instant : state.changes.first { $0.at > instant && $0.transport != nil }?.at
        }
    }

    private func record<T: Sendable>(_ read: @Sendable (State) -> T) throws -> T {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            return read(state)
        }
    }

    private func apply(_ event: UsbmuxEvent, udid: String) {
        state.withLock { state in
            switch event {
            case .attached(let device):
                guard case .device(udid, let transport) = device.connection else { return }
                state.handles[device.handle] = transport
            case .detached(let handle): state.handles.removeValue(forKey: handle)
            case .paired, .other: return
            }
            let transport = state.handles.values.max { $0 == .network && $1 == .usb }
            // Before its first change the device is unlisted, so only a listing starts the record.
            guard transport != state.changes.last.flatMap(\.transport) else { return }
            state.changes.append(Change(at: .now, transport: transport))
        }
    }
}

/// Events in arrival order with the moment each arrived, for a test that waits on each against a deadline. It checks
/// once a second.
private final class Arrivals: Sendable {
    private let events = OSAllocatedUnfairLock<[(IPhoneEvent, ContinuousClock.Instant)]>(initialState: [])

    func append(_ event: IPhoneEvent) { events.withLock { $0.append((event, .now)) } }

    /// The event at `index` and when it arrived, once it has, or nil once `expired` holds first.
    func event(at index: Int, until expired: () throws -> Bool) async throws -> (IPhoneEvent, ContinuousClock.Instant)? {
        while try !expired() {
            if let event = events.withLock({ index < $0.count ? $0[index] : nil }) { return event }
            try await Task.sleep(for: .seconds(1))
        }
        return events.withLock { index < $0.count ? $0[index] : nil }
    }
}
