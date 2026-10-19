import AppKit
import os

extension Firing {
    /// Whether the alert that fired asks to be heard.
    var sound: Bool {
        switch self {
        case .threshold(let alert): alert.sound
        case .pluggedIn(let sound), .unplugged(let sound): sound
        case .temperatureWarning: false
        }
    }
}

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

    /// [LAW:no-silent-failure] A chime that cannot play is logged, not skipped.
    static func playSystemChime() {
        guard NSSound(named: "Glass")?.play() == true else {
            log.error("the alert chime could not be played")
            return
        }
    }
}
