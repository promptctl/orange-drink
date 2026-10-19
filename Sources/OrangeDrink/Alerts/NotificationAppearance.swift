import Foundation

/// How the app's alerts look, for every alert: the General screen's Notification Appearance.
struct NotificationAppearance: Stored {
    static let storageKey = "notification.appearance"

    enum BubbleSize: String, Codable, CaseIterable, Sendable {
        case small = "Small", `default` = "Default", large = "Large"

        /// The pill's width and height, as a multiple of the 280 × 64 pt standard.
        var scale: Double {
            switch self {
            case .small: 0.8
            case .default: 1
            case .large: 1.3
            }
        }
    }

    enum GlowStrength: String, Codable, CaseIterable, Sendable {
        case subtle = "Subtle", `default` = "Default", strong = "Strong"

        /// How far in from the screen edge the glow reaches, in points.
        var reach: Double {
            switch self {
            case .subtle: 22
            case .default: 36
            case .strong: 60
            }
        }

        var opacity: Double {
            switch self {
            case .subtle: 0.6
            case .default: 0.9
            case .strong: 1
            }
        }
    }

    var bubbleSize = BubbleSize.default
    var glowStrength = GlowStrength.default
}

typealias NotificationAppearanceModel = StoredModel<NotificationAppearance>
