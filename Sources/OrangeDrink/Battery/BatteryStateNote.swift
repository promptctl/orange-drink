import Foundation

/// What the app says in place of a battery reading, one sentence for each `BatteryModel.State` that has none.
///
/// [LAW:one-source-of-truth] The panel, the Battery screen and the status item's accessibility label all
/// say these, so a reworded sentence reaches the three together.
enum BatteryStateNote {
    static let unknown: Phrase = "Reading the battery…"
    static let noBattery: Phrase = "This Mac has no battery."
    static let ended: Phrase = "Battery readings stopped. Quit and reopen the app."
}
