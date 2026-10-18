import Foundation
import OSLog
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The ticket's check: the service's values are the ones ioreg and
// pmset show, read at the same moment. Facts that cannot move between two reads must be
// equal; the live electrical readings may drift by what a moment of load changes.
@Suite(.serialized) struct BatteryLive {
    @Test func matchesPmset() throws {
        let reading = try #require(try IOKitBattery.read(), "this check needs a Mac with a battery")
        let batt = try run("/usr/bin/pmset", "-g", "batt")
        let ac = try run("/usr/bin/pmset", "-g", "ac")
        let line = try #require(batt.split(separator: "\n").first { $0.contains("InternalBattery") }.map(String.init))
        let match = try #require(line.wholeMatch(of: /.*\t(\d+)%; ([A-Za-z ;]+?)(?:; (\d+:\d+|\(no estimate\)) remaining)? present: true/))
        #expect(reading.chargePercent == Int(match.1))

        switch reading.power {
        case .battery(let timeToEmpty):
            #expect(match.2 == "discharging")
            #expect(ac.contains("No adapter attached."))
            #expect(Self.pmsetDuration(match.3) == timeToEmpty)
        case .adapter(let watts, let charging):
            let adapterWatts = try #require(ac.firstMatch(of: /Wattage = (\d+)W/)?.1)
            #expect(watts == .init(value: Double(adapterWatts)!, unit: .watts))
            switch charging {
            case .charging(let timeToFull):
                #expect(match.2 == "charging" || match.2 == "finishing charge")
                #expect(Self.pmsetDuration(match.3) == timeToFull)
            case .notCharging: #expect(match.2 == "AC attached; not charging")
            case .full: #expect(match.2 == "charged")
            }
        }
    }

    /// pmset prints "h:mm" for an estimate and "(no estimate)" while the system has none.
    static func pmsetDuration(_ text: Substring?) -> Duration? {
        guard let text, let parts = text.wholeMatch(of: /(\d+):(\d+)/) else { return nil }
        return .seconds((Int(parts.1)! * 60 + Int(parts.2)!) * 60)
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
                                                                             Bundle.main.bundleIdentifier!, "battery"))
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
