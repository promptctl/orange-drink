import Foundation

/// The Battery screen's three tiles for one reading. Health and temperature say what the panel's
/// Battery Information says, from the same words and conditions.
///
/// [LAW:one-source-of-truth] `BatteryInformation` owns what "Good" and "Normal" mean; the tiles
/// restate none of it.
struct StatTiles: Equatable {
    /// A status line is coloured by the reading's condition, or is plain information.
    enum Tone: Equatable {
        case condition(BatteryInformation.Condition)
        case info
    }

    struct Tile: Equatable {
        let label: Phrase
        let symbol: String
        let value: String
        let status: Phrase
        let tone: Tone
    }

    let health: Tile
    let temperature: Tile
    let cycles: Tile

    var all: [Tile] { [health, temperature, cycles] }

    init(_ reading: BatteryReading) {
        let info = BatteryInformation(reading)
        health = Tile(label: "HEALTH", symbol: "heart.fill", value: info.health.percent, status: info.health.label, tone: .condition(info.health.condition))
        temperature = Tile(label: "TEMPERATURE", symbol: "thermometer.medium", value: info.temperature.celsius,
                           status: info.temperature.status, tone: .condition(info.temperature.condition))
        cycles = Tile(label: "CYCLES", symbol: "arrow.triangle.2.circlepath", value: "\(reading.cycles.count)",
                      status: "of \(reading.cycles.rated) rated", tone: .info)
    }
}

extension BatteryReading {
    /// "5,942 / 6,249 mAh": what a full charge holds today over what it held new.
    func capacityText(locale: Locale) -> String {
        func mAh(_ capacity: Measurement<UnitElectricCharge>) -> String {
            Int(capacity.converted(to: .milliampereHours).value.rounded()).formatted(.number.locale(locale))
        }
        return "\(mAh(capacity.full)) / \(mAh(capacity.design)) mAh"
    }
}
