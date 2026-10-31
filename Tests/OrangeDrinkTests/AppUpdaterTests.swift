import Foundation
import Sparkle
import Testing
import ViewInspector
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is what a press of the row asks of the updater, and what an update cycle
// says in the log however it ended.
@MainActor @Suite struct AppUpdaterTests {
    private func card(_ updates: AppUpdater) -> ActionsCard {
        let lowPowerMode = LowPowerMode(read: { false }, center: NotificationCenter(), write: { _ throws(HelperUseFailure) in })
        return ActionsCard(lowPowerMode: lowPowerMode, updates: updates)
    }

    @Test func pressingCheckForUpdatesAsksTheUpdaterToCheckOnce() throws {
        var checks = 0
        let view = card(AppUpdater(canCheck: true) { checks += 1 })
        try view.inspect().find(button: "Check for Updates…").tap()
        #expect(checks == 1)
    }

    @Test func theRowCannotBePressedWhileTheUpdaterCannotCheck() throws {
        let view = card(AppUpdater(canCheck: false) { Issue.record("the updater was asked to check") })
        #expect(try view.inspect().find(button: "Check for Updates…").isDisabled())
    }

    @Test func aCycleEndsAsItsErrorSays() {
        func sparkleError(_ code: SUError) -> NSError { NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue)) }
        #expect(AppUpdater.Outcome(error: nil) == .finished)
        #expect(AppUpdater.Outcome(error: sparkleError(.noUpdateError)) == .upToDate)
        #expect(AppUpdater.Outcome(error: sparkleError(.installationCanceledError)) == .canceled)
        let failure = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue), userInfo: [NSLocalizedDescriptionKey: "no download"])
        #expect(AppUpdater.Outcome(error: failure) == .failed("no download"))
    }

    /// The same code in another domain is not Sparkle's no-update result.
    @Test func anotherDomainsCodeIsAFailure() {
        let error = NSError(domain: NSCocoaErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [NSLocalizedDescriptionKey: "elsewhere"])
        #expect(AppUpdater.Outcome(error: error) == .failed("elsewhere"))
    }

    /// The log says which feed answered and how the cycle ended: scripts/update-check prints these lines when it fails.
    @Test func theLogNamesTheVersionsAndTheFeed() {
        #expect(AppUpdater.Event.found(version: "1.2.0").line == "update 1.2.0 found")
        #expect(AppUpdater.Event.installing(version: "1.2.0").line == "installing update 1.2.0")
        let feed = URL(string: "http://127.0.0.1:8000/appcast.xml")
        #expect(AppUpdater.Event.cycleEnded(feed: feed, .upToDate).line == "update cycle ended, feed http://127.0.0.1:8000/appcast.xml: up to date")
        #expect(AppUpdater.Event.cycleEnded(feed: nil, .failed("no feed")).line == "update cycle ended, feed none: failed: no feed")
    }
}
