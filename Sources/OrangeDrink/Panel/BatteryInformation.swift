import Foundation

/// The words the expanded Battery Information card shows for one reading.
///
/// [LAW:one-source-of-truth] The view draws these and nothing else, so what the tests assert
/// about them is what the panel shows.
struct BatteryInformation: Equatable {
    /// How the reading is doing: drives both the label and the colour of the section it heads.
    enum Condition: Equatable { case good, warning, bad }

    struct Health: Equatable {
        let percent: String
        let fraction: Double
        let label: String
        let condition: Condition
        let cycles: String
    }

    struct Temperature: Equatable {
        let celsius: String
        let fahrenheit: String
        let status: String
        let caption: String
        let condition: Condition
    }

    struct Electrical: Equatable {
        let power: String
        let current: String
        /// The direction current is flowing; nil at rest.
        let flow: Flow?
        let voltage: String
        let voltageStatus: String
        let voltageNote: String
        let voltageCondition: Condition
        let charging: Bool
    }

    enum Flow: Equatable { case intoBattery, outOfBattery }

    struct Capacity: Equatable {
        let remaining: String, full: String, design: String
    }

    let health: Health
    let temperature: Temperature
    let electrical: Electrical
    let capacity: Capacity

    /// A health fraction under this is a battery Apple would call service-worthy.
    static let serviceHealth = 0.8
    /// Temperatures from which a battery is called warm and hot, in °C.
    static let warmCelsius = 35.0, hotCelsius = 40.0
    /// What a MacBook's cell stack sits inside, in volts. Outside it is worth saying so.
    static let normalVolts = 9.0...13.5

    init(_ reading: BatteryReading) {
        let fraction = reading.capacity.full.value / reading.capacity.design.value
        let healthy = fraction >= Self.serviceHealth
        health = Health(
            percent: "\(Int((fraction * 100).rounded()))%", fraction: fraction,
            label: healthy ? "Good" : "Service Recommended", condition: healthy ? .good : .warning,
            cycles: "\(reading.cycles.count)/\(reading.cycles.rated)")

        let celsius = reading.temperature.converted(to: .celsius).value
        let (status, caption, condition): (String, String, Condition) = switch celsius {
        case ..<Self.warmCelsius: ("Normal", "Optimal performance", .good)
        case ..<Self.hotCelsius: ("Warm", "Charging may slow down", .warning)
        default: ("Hot", "Let the Mac cool down", .bad)
        }
        temperature = Temperature(
            celsius: Self.one(celsius, "°C"), fahrenheit: Self.one(reading.temperature.converted(to: .fahrenheit).value, "°F"),
            status: status, caption: caption, condition: condition)

        let milliamps = reading.current.converted(to: .milliamperes).value
        let volts = reading.voltage.converted(to: .volts).value
        let watts = abs(reading.batteryPower.value)
        let normal = Self.normalVolts.contains(volts)
        let charging: Bool
        if case .adapter(_, .charging) = reading.power { charging = true } else { charging = false }
        electrical = Electrical(
            power: Self.one(watts, "W"), current: "\(Int(abs(milliamps).rounded())) mA",
            flow: milliamps > 0 ? .intoBattery : milliamps < 0 ? .outOfBattery : nil,
            voltage: String(format: "%.2f V", volts),
            voltageStatus: ChargeCard(reading).status.title,
            voltageNote: normal ? "Normal voltage" : "Unusual voltage",
            voltageCondition: normal ? .good : .warning, charging: charging)

        func mAh(_ capacity: Measurement<UnitElectricCharge>) -> String { "\(Int(capacity.converted(to: .milliampereHours).value.rounded())) mAh" }
        capacity = Capacity(
            remaining: mAh(reading.capacity.current), full: mAh(reading.capacity.full), design: mAh(reading.capacity.design))
    }

    private static func one(_ value: Double, _ unit: String) -> String { String(format: "%.1f %@", value, unit).replacingOccurrences(of: " °", with: "°") }
}
