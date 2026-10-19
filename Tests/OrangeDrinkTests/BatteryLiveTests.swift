import Foundation
import OSLog
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

        switch reading.power {
        case .battery(let timeToEmpty):
            #expect(after.state == "discharging")
            #expect(ac.contains("No adapter attached."))
            #expect(estimates.contains(timeToEmpty))
        case .adapter(let watts, let charging):
            let adapterWatts = ac.firstMatch(of: /Wattage = (\d+)W/)?.1
            #expect(watts == adapterWatts.map { .init(value: Double($0)!, unit: .watts) })
            switch charging {
            case .charging(let timeToFull):
                #expect(after.state == "charging" || after.state == "finishing charge")
                #expect(estimates.contains(timeToFull))
            case .notCharging: #expect(after.state == "AC attached; not charging")
            case .full: #expect(after.state == "charged")
            }
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
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date())
        let reading = try #require(try IOKitBattery.read())
        let entries = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@ AND category == %@",
                                                                             IOKitBattery.logSubsystem, IOKitBattery.logCategory))
        #expect(entries.contains { $0.composedMessage == "battery read: \(String(describing: reading))" })
    }

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
