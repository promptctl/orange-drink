import Foundation

/// How hot the battery is running, as the panel's Temperature section names it.
///
/// [LAW:one-source-of-truth] The panel's status and the temperature warning both read the state
/// from here, so the warning names the state the panel shows. When it fires is `isRearmed`'s and
/// the engine's: not on every reading where the panel stops saying "Normal".
enum TemperatureState: Equatable, Sendable {
    case normal, warm, hot

    /// Temperatures from which a battery is called warm and hot, in °C.
    static let warmCelsius = 35.0, hotCelsius = 40.0

    /// A battery that has warned is warned about again only once it has cooled to under this, in °C:
    /// a dead band, as `Alert.hysteresis` is for the threshold alerts but a width of its own, so a
    /// battery hovering at `warmCelsius` is one warning, not one per upward crossing.
    static let rearmCelsius = warmCelsius - 2

    /// The battery has cooled far enough back from `warmCelsius` that heating up again is news.
    static func isRearmed(by temperature: Measurement<UnitTemperature>) -> Bool {
        temperature.converted(to: .celsius).value < rearmCelsius
    }

    init(_ temperature: Measurement<UnitTemperature>) {
        switch temperature.converted(to: .celsius).value {
        case ..<Self.warmCelsius: self = .normal
        case ..<Self.hotCelsius: self = .warm
        default: self = .hot
        }
    }

    /// A state a battery is warned about: every one but Normal.
    enum Heat: Equatable, Sendable {
        case warm, hot

        /// nil for Normal, which has nothing to warn of.
        init?(_ state: TemperatureState) {
            switch state {
            case .normal: return nil
            case .warm: self = .warm
            case .hot: self = .hot
            }
        }
    }
}
