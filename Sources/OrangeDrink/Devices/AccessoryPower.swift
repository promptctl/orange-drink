import Foundation
import IOKit.ps

/// Every Bluetooth accessory's battery as macOS publishes it: power management's accessory sources, the
/// list `pmset -g accps` prints. bluetoothd posts each part of a set as its own source (an earbud, the
/// case), where IOBluetooth's battery properties held one earbud of a set system_profiler gave three
/// parts for (orange-devices-bue.1e6).
struct AccessoryPower {
    private typealias CopySourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    /// IOKit's private source filter: every source, accessories included. The public
    /// `IOPSCopyPowerSourcesInfo` answers with the Mac's own battery alone.
    private static let allSources: Int32 = 4

    private let copySources: CopySourcesByType

    /// [LAW:single-enforcer] The private symbol is resolved once, at the border: an OS without it is one
    /// this edge does not understand, which fails the subscription instead of reading as no levels.
    init() throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else {
            throw BluetoothDevicesError.missingSymbol("IOPSCopyPowerSourcesByType")
        }
        copySources = unsafeBitCast(symbol, to: CopySourcesByType.self)
    }

    /// [LAW:effects-at-boundaries] The one read of power management's sources; `levels(from:)` is the parse.
    func read() throws -> [[String: Any]] {
        try PowerSources.descriptions(copySources(Self.allSources), copiedBy: "IOPSCopyPowerSourcesByType")
    }

    /// What one read of the sources says: each device's levels by the name System Settings shows for it,
    /// and every source it could not attribute, so a sweep can say what it left out.
    struct Levels: Equatable {
        var byName: [String: DeviceLevels] = [:]
        var unattributed: [String] = []

        /// [LAW:nothing-unseen] How the names of the connected devices met these levels: the devices power
        /// management has no battery for, and the sets no connected device claimed (a set in its case
        /// nearby, or one whose name differs from the device's). A name that misses is named here instead
        /// of reading as a device with no battery.
        func attribution(of names: [String]) -> Attribution {
            let names = Set(names)
            return Attribution(unlevelled: names.subtracting(byName.keys).sorted(),
                               unclaimed: Set(byName.keys).subtracting(names).sorted())
        }
    }

    struct Attribution: Equatable {
        let unlevelled: [String]
        let unclaimed: [String]
    }

    /// [LAW:parse-dont-validate] The crossing from power management's untyped sources to levels. The parts
    /// of one set share a Group Identifier, and a source with none is a set of its own. A set's name is its
    /// buds' (its case is "<name> Case"); a set whose name another set also has cannot be told apart from
    /// it, so neither has levels. Capacities are percentages here, and 0 is a reading: a drained case.
    static func levels(from sources: [[String: Any]]) -> Levels {
        var result = Levels()
        var sets: [String: [Part]] = [:]
        for (index, source) in sources.enumerated() where source[kIOPSTypeKey] as? String == "Accessory Source" {
            switch Part.parse(source) {
            case .success(let parts): sets[source["Group Identifier"] as? String ?? "ungrouped \(index)", default: []] += parts
            case .failure(let reason): result.unattributed.append(reason.description)
            }
        }
        var named: [String: [DeviceLevels]] = [:]
        for parts in sets.values {
            switch DeviceLevels.parse(parts) {
            case .success(let (name, levels)): named[name, default: []].append(levels)
            case .failure(let reason): result.unattributed.append(reason.description)
            }
        }
        for (name, levels) in named {
            if levels.count == 1 { result.byName[name] = levels[0] }
            else { result.unattributed.append("\(levels.count) sets named \(name)") }
        }
        result.unattributed.sort()
        return result
    }

    /// One battery of a set, as one source reports it.
    fileprivate struct Part {
        enum Role: String { case single = "Single", left = "Left", right = "Right", `case` = "Case" }
        let name: String
        let role: Role
        let level: BatteryLevel

        /// A Combined source is both buds at once; it carries each bud as a source of its own under
        /// "Combined Parts", and with none it is one level for the set. Every source is at least one
        /// part, so no set is empty, and a capacity is read only from the source whose level it is.
        static func parse(_ source: [String: Any]) -> Result<[Part], Unattributed> {
            let name = source[kIOPSNameKey] as? String ?? "unnamed source"
            let identifier = source["Part Identifier"] as? String
            if identifier == "Combined", let combined = source["Combined Parts"] as? [[String: Any]], !combined.isEmpty {
                return combined.reduce(.success([])) { parts, source in
                    parts.flatMap { parts in Part.parse(source).map { parts + $0 } }
                }
            }
            guard let role = identifier == "Combined" ? .single : identifier.flatMap(Role.init) else {
                return .failure(Unattributed("\(name): part \(identifier ?? "missing")"))
            }
            guard let current = source[kIOPSCurrentCapacityKey] as? Int, let max = source[kIOPSMaxCapacityKey] as? Int,
                  max > 0, (0...max).contains(current)
            else { return .failure(Unattributed("\(name): no capacity")) }
            return .success([Part(name: name, role: role, level: BatteryLevel(percent: current * 100 / max, approximate: false))])
        }
    }

    fileprivate struct Unattributed: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private extension DeviceLevels {
    /// One set's parts as the device's levels: a lone Single is the device's one battery; earbuds and a
    /// case are the parts of a set. A set holding both kinds, or one part twice, says two things at once.
    static func parse(_ parts: [AccessoryPower.Part]) -> Result<(String, DeviceLevels), AccessoryPower.Unattributed> {
        let name = parts.first { $0.role != .case }?.name
            ?? parts[0].name.replacing(#/ Case$/#, with: "")
        let roles = Dictionary(grouping: parts, by: \.role)
        guard roles.values.allSatisfy({ $0.count == 1 }) else {
            return .failure(.init("\(name): \(parts.map(\.role.rawValue).sorted()) repeats a part"))
        }
        if let single = roles[.single]?.first {
            guard parts.count == 1 else { return .failure(.init("\(name): Single beside \(parts.map(\.role.rawValue).sorted())")) }
            return .success((name, .single(single.level)))
        }
        return .success((name, .earbuds(left: roles[.left]?.first?.level, right: roles[.right]?.first?.level,
                                        case: roles[.case]?.first?.level)))
    }
}
