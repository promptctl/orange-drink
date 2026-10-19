import Foundation
import IOKit.ps
import notify
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The ticket's check: the service's values are the ones ioreg and
// pmset show, read at the same moment. Facts that cannot move between two reads must be
// equal; the live electrical readings may drift by what a moment of load changes.
@Suite(.serialized) struct BatteryLive {
    @Test func matchesPmset() throws {
        // [LAW:no-ambient-temporal-coupling] powerd may publish between two reads, so the
        // reading is bracketed: a value sampled between two pmset samples equals one of them.
        let before = try pmsetBattery()
        let reading = try #require(try IOKitBattery.read(), "this check needs a Mac with a battery")
        let after = try pmsetBattery()
        let ac = try run("/usr/bin/pmset", "-g", "ac")
        #expect([before.percent, after.percent].contains(reading.chargePercent))
        let estimates = [before.estimate, after.estimate]
        #expect(Self.pmsetStates(for: reading.power).contains(after.state))

        switch reading.power {
        case .battery(let timeToEmpty):
            #expect(ac.contains("No adapter attached."))
            #expect(estimates.contains(timeToEmpty))
        case .adapter(let watts, let charging):
            let adapterWatts = ac.firstMatch(of: /Wattage = (\d+)W/)?.1
            #expect(watts == adapterWatts.map { .init(value: Double($0)!, unit: .watts) })
            if case .charging(let timeToFull) = charging { #expect(estimates.contains(timeToFull)) }
        }
    }

    /// pmset.m's five state words: one for a battery, four for an adapter. [LAW:one-source-of-truth]
    /// The one map from a reading's power to those words; every pmset check reads it.
    static let pmsetDischarging = "discharging"
    static func pmsetStates(for power: PowerSource) -> [String] {
        switch power {
        case .battery: [pmsetDischarging]
        case .adapter(_, .charging): ["charging", "finishing charge"]
        case .adapter(_, .notCharging): ["AC attached; not charging"]
        case .adapter(_, .full): ["charged"]
        }
    }

    struct PmsetBattery { let percent: Int; let state: String; let estimate: Duration? }

    /// The InternalBattery line of `pmset -g batt`. pmset.m prints "; h:mm remaining", or
    /// "; (no estimate)" while the system has none, then may append " rawExternalConnected: N"
    /// and, under a non-Good health, " (Health/Confidence)".
    func pmsetBattery() throws -> PmsetBattery {
        let batt = try run("/usr/bin/pmset", "-g", "batt")
        let line = try #require(batt.split(separator: "\n").first { $0.contains("InternalBattery") })
        let match = try #require(line.wholeMatch(of: /.*\t(\d+)%; ([A-Za-z ;]+?)(?:; (?:(\d+):(\d+) remaining|\(no estimate\)))?(?: rawExternalConnected: \d+)?(?: \([^)]*\))? present: true/))
        let estimate: Duration? = match.3.map { .seconds((Int($0)! * 60 + Int(match.4!)!) * 60) }
        return PmsetBattery(percent: Int(match.1)!, state: String(match.2), estimate: estimate)
    }

    @Test func matchesIoreg() throws {
        let reading = try #require(try IOKitBattery.read())
        let plist = try run("/usr/sbin/ioreg", "-a", "-r", "-c", "AppleSmartBattery")
        let entries = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as! [[String: Any]]
        let registry = try #require(entries.first)
        #expect(reading.capacity.design.value == registry["DesignCapacity"] as? Double)
        #expect(reading.cycles.count == registry["CycleCount"] as? Int)
        #expect(reading.cycles.rated == registry["DesignCycleCount9C"] as? Int)
        #expect(abs(reading.capacity.current.value - Double(registry["AppleRawCurrentCapacity"] as! Int)) <= 50)
        #expect(abs(reading.capacity.full.value - Double(registry["AppleRawMaxCapacity"] as! Int)) <= 50)
        #expect(abs(reading.temperature.value - Double(registry["Temperature"] as! Int) / 100) <= 1)
        #expect(abs(reading.voltage.value - Double(registry["Voltage"] as! Int) / 1000) <= 0.2)
        #expect(abs(reading.current.value - Double(registry["Amperage"] as! Int)) <= 1500)
    }

    @Test func everyReadIsLogged() throws {
        let log = try BatteryLog()
        let reading = try #require(try IOKitBattery.read())
        #expect(try log.messages().contains("battery read: \(String(describing: reading))"))
    }

    @Test func subscriptionStartsWithTheCurrentReading() async throws {
        let log = try BatteryLog()
        var readings = BatteryMonitor.readings().makeAsyncIterator()
        let published = try #require(try await readings.next(), "the stream ended before its first reading")
        let first = try #require(published, "this check needs a Mac with a battery")
        let direct = try #require(try IOKitBattery.read())
        #expect(first.capacity.design == direct.capacity.design)
        #expect(first.cycles == direct.cycles)
        #expect(try log.messages().contains { $0.hasPrefix("battery notifications: registered token ") })
    }

    /// The app holds its subscription from launch, which is what `make cpu-check` measures.
    @Test func appModelHoldsTheCurrentReading() async throws {
        let model = await BatteryModel()
        let direct = try #require(try IOKitBattery.read())
        for _ in 0..<20 {
            if case .known(let reading?) = await model.state {
                #expect(reading.cycles == direct.cycles)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("no reading reached the model within 2 s")
    }

    /// The ticket's step on a real Mac, run by `make unplug-check` with a person at the cable.
    /// Each event is checked against pmset at the moment it arrives, and against powerd's own
    /// source-change post for the one-second bound.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNPLUG_CHECK"] != nil, "run by make unplug-check with a person at the cable"))
    func plugAndUnplug() async throws {
        struct Arrival {
            let reading: BatteryReading; let at: ContinuousClock.Instant; let pmset: PmsetBattery; let after: BatteryReading
            /// [LAW:no-ambient-temporal-coupling] Stamped first, then pmset, then a second read, so
            /// the stamp predates the pmset spawn and pmset's percent is bracketed by two readings.
            init(_ reading: BatteryReading, pmset: () throws -> PmsetBattery, read: () throws -> BatteryReading) rethrows {
                self.reading = reading; at = .now; self.pmset = try pmset(); after = try read()
            }
        }
        let start = try #require(try IOKitBattery.read(), "this check needs a Mac with a battery")
        guard case .adapter = start.power else { Issue.record("start with the adapter plugged in"); return }
        let log = try BatteryLog()
        let posts = OSAllocatedUnfairLock<[ContinuousClock.Instant]>(initialState: [])
        var token: Int32 = 0
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, DispatchQueue(label: "posts")) { _ in
            posts.withLock { $0.append(.now) }
        }
        try #require(status == NOTIFY_STATUS_OK)
        defer { notify_cancel(token) }
        let run = Task { () -> (unplugged: Arrival, plugged: Arrival)? in
            var unplugged: Arrival?
            FileHandle.standardError.write(Data("\n>>> Unplug the adapter now.\n".utf8))
            for try await event in BatteryMonitor.events() {
                switch (event, unplugged) {
                case (.unplugged(let reading), nil):
                    unplugged = try Arrival(reading, pmset: pmsetBattery, read: readBattery)
                    FileHandle.standardError.write(Data("\n>>> Plug it back in now.\n".utf8))
                case (.plugged(let reading), let unplugged?):
                    return (unplugged, try Arrival(reading, pmset: pmsetBattery, read: readBattery))
                default:
                    continue
                }
            }
            return nil
        }
        let deadline = Task { try await Task.sleep(for: .seconds(120)); run.cancel() }
        defer { deadline.cancel() }
        let arrivals = try #require(try await run.value, "no unplug followed by a plug within 120 s")

        guard case .battery = arrivals.unplugged.reading.power else {
            Issue.record("unplug event carried \(arrivals.unplugged.reading.power)"); return
        }
        guard case .adapter = arrivals.plugged.reading.power else {
            Issue.record("plug event carried \(arrivals.plugged.reading.power)"); return
        }
        // The kind, not the charging detail: powerd publishes "not charging" and then "charging"
        // within the time a pmset sample takes, so the detail is bracketed in matchesPmset instead.
        #expect(arrivals.unplugged.pmset.state == Self.pmsetDischarging)
        #expect(arrivals.plugged.pmset.state != Self.pmsetDischarging)
        for arrival in [arrivals.unplugged, arrivals.plugged] {
            #expect([arrival.reading.chargePercent, arrival.after.chargePercent].contains(arrival.pmset.percent))
            let gap = posts.withLock { $0 }.filter { $0 <= arrival.at }.map { arrival.at - $0 }.min()
            #expect(try #require(gap, "powerd posted no source change before the event") <= .seconds(1))
        }

        let messages = try log.messages()
        #expect(messages.contains("battery event: \(String(describing: BatteryEvent.unplugged(arrivals.unplugged.reading)))"))
        #expect(messages.contains("battery event: \(String(describing: BatteryEvent.plugged(arrivals.plugged.reading)))"))
    }

    func readBattery() throws -> BatteryReading { try #require(try IOKitBattery.read()) }

    func run(_ command: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(command) exited \(process.terminationStatus)")
        return String(decoding: output, as: UTF8.self)
    }
}
