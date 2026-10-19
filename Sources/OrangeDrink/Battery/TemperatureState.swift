import Foundation

/// How hot the battery is running, as the panel's Temperature section names it.
///
/// [LAW:one-source-of-truth] The panel's status and the temperature warning both read the state
/// from here, so the alert fires exactly when the panel stops saying "Normal".
enum TemperatureState: Equatable, Sendable {
    case normal, warm, hot

    /// Temperatures from which a battery is called warm and hot, in °C.
    static let warmCelsius = 35.0, hotCelsius = 40.0

    init(_ temperature: Measurement<UnitTemperature>) {
        switch temperature.converted(to: .celsius).value {
        case ..<Self.warmCelsius: self = .normal
        case ..<Self.hotCelsius: self = .warm
        default: self = .hot
        }
    }
}
