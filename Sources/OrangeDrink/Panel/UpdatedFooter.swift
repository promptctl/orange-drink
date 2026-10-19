import Foundation

enum UpdatedFooter {
    static let explanation: Phrase = "We refresh your battery health stats every \(Int(BatteryModel.refreshInterval.components.seconds / 60)) min"
    static let action: Phrase = "Tap to refresh now"

    /// "Updated 3 min ago", by whole minutes; "Updated just now" inside the first.
    static func text(age: TimeInterval) -> Phrase {
        let minutes = Int(max(age, 0) / 60)
        return minutes == 0 ? "Updated just now" : "Updated \(minutes) min ago"
    }
}
