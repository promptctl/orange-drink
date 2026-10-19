import AppKit
import os

/// The sound subscriber of an `AlertCenter`: plays a firing's chime when its alert has Sound on.
///
/// [LAW:effects-at-boundaries] What makes the noise is handed in, so the decision to play is
/// asserted without a speaker.
@MainActor final class AlertSounds {
    private static let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "alerts")

    private let play: @MainActor () -> Void

    init(play: @escaping @MainActor () -> Void = AlertSounds.playSystemChime) { self.play = play }

    func deliver(_ firing: Firing) {
        if firing.sound { play() }
    }

    func deliver(_ firing: DeviceFiring) {
        if firing.alert.sound { play() }
    }

    /// [LAW:no-silent-failure] A chime that cannot play is logged, not skipped. The system hands out
    /// one shared sound, which refuses to play while it is still playing, so a second firing from the
    /// same reading restarts it: two alerts together are one chime, not a dropped one and an error.
    static func playSystemChime() {
        guard let chime = NSSound(named: "Glass") else {
            log.error("the system sound Glass is missing")
            return
        }
        chime.stop()
        if !chime.play() { log.error("the alert chime did not play") }
    }
}
