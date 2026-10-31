import Foundation
import Observation
import OSLog
import Sparkle

/// The app's updater, as the panel's Check for Updates… row uses it. Sparkle's standard user driver draws every
/// window of an update, from the check to the relaunch.
///
/// [LAW:one-source-of-truth] Sparkle holds whether a check may be invoked. `canCheck` is its live copy, and only the
/// observation of `canCheckForUpdates` writes it. It says nothing of a session in progress: a press while an update
/// is shown brings that window forward, and Sparkle's own guard is what stops a second session.
@Observable @MainActor final class AppUpdater {
    /// How an update cycle ended.
    enum Outcome: Equatable {
        /// No error: an update was installed, skipped, or dismissed.
        case finished
        case upToDate
        /// The user canceled when asked to authorize the install.
        case canceled
        case failed(String)

        /// [LAW:effects-at-boundaries] A pure function of the error Sparkle ended the cycle with.
        init(error: (any Error)?) {
            guard let error = error as NSError? else {
                self = .finished
                return
            }
            switch (error.domain, error.code) {
            case (SUSparkleErrorDomain, Int(SUError.noUpdateError.rawValue)): self = .upToDate
            case (SUSparkleErrorDomain, Int(SUError.installationCanceledError.rawValue)): self = .canceled
            default: self = .failed(error.localizedDescription)
            }
        }

        var description: String {
            switch self {
            case .finished: "finished"
            case .upToDate: "up to date"
            case .canceled: "canceled"
            case .failed(let reason): "failed: \(reason)"
            }
        }
    }

    /// What happened, as the log and the tests read it.
    enum Event {
        case found(version: String)
        case installing(version: String)
        /// One per cycle, naming the feed that answered, since a launch's defaults can replace the built-in one.
        case cycleEnded(feed: URL?, Outcome)

        /// [LAW:effects-at-boundaries] The log line, a pure function of the event.
        var line: String {
            switch self {
            case .found(let version): "update \(version) found"
            case .installing(let version): "installing update \(version)"
            case .cycleEnded(let feed, let outcome): "update cycle ended, feed \(feed?.absoluteString ?? "none"): \(outcome.description)"
            }
        }
    }

    private(set) var canCheck: Bool
    let check: () -> Void

    /// Sparkle's controller, the delegate it holds weakly, and the observation: each ends with its last reference.
    @ObservationIgnored private var sparkle: [AnyObject] = []

    /// [LAW:composability] `canCheck` is whether a check may start now, and `check` starts one. `live()` passes Sparkle's.
    init(canCheck: Bool, check: @escaping () -> Void) {
        self.canCheck = canCheck
        self.check = check
    }

    /// The updater the app runs: Sparkle, started, with no check until the row asks for one
    /// (project.yml's SUEnableAutomaticChecks).
    static func live() -> AppUpdater {
        let delegate = UpdaterEvents()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        let updates = AppUpdater(canCheck: controller.updater.canCheckForUpdates) { controller.checkForUpdates(nil) }
        let observation = controller.updater.observe(\.canCheckForUpdates) { [weak updates] updater, _ in
            // Sparkle changes the property on the main thread.
            MainActor.assumeIsolated { updates?.canCheck = updater.canCheckForUpdates }
        }
        updates.sparkle = [controller, delegate, observation]
        return updates
    }
}

/// Sparkle's callbacks as the app's events.
///
/// [LAW:nothing-unseen] `updater:didFinishUpdateCycleForUpdateCheck:error:` is the one callback per cycle, however it
/// ended; `updater:didAbortWithError:` also fires for no update and for a cancel, so it is no sign of a failure.
private final class UpdaterEvents: NSObject, SPUUpdaterDelegate {
    private let log = Logger(subsystem: IOKitBattery.logSubsystem, category: "updates")

    private func record(_ event: AppUpdater.Event) { log.notice("\(event.line, privacy: .public)") }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record(.found(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        record(.installing(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        record(.cycleEnded(feed: updater.feedURL, AppUpdater.Outcome(error: error)))
    }
}
