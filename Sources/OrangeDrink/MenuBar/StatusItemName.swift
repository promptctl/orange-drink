import Foundation

/// What VoiceOver reads for the status item: the app's name and the battery's state.
///
/// The item's AXTitle is the only channel a menu bar item has (`.accessibilityValue` reaches nothing on
/// the AXMenuBarItem), so the state rides in the title. It is the same whatever icon style the bar shows:
/// a person who cannot see the glyph hears the level and whether it is charging, or why there is none.
struct StatusItemName: Equatable {
    let phrase: Phrase

    init(_ state: BatteryModel.State, appName: String) {
        phrase = switch state {
        case .known(let reading?):
            "\(appName), \(BatteryLevel.text(BatteryLevel(percent: reading.chargePercent, approximate: false))), \(ChargeCard.Status(reading.power).title)"
        case .unknown: "\(appName), \(BatteryStateNote.unknown)"
        case .known(nil): "\(appName), \(BatteryStateNote.noBattery)"
        case .ended: "\(appName), \(BatteryStateNote.ended)"
        }
    }
}
