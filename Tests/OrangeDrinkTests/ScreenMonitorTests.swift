import AppKit
import Foundation
import Testing
@testable import OrangeDrink

// [LAW:behavior-not-structure] The contract is the set of hiders in force after each start and end
// the system posts, and that the distributed ones reach a menu-bar app that is not active.
@Suite struct ScreenMonitorTests {
    @Test func theWorkspaceStartsAndEndsFoldIntoTheHidersInForce() async throws {
        let workspace = NotificationCenter()
        let rows = ScreenMonitor.signals.filter { $0.center == .workspace }
        var hidden = ScreenMonitor.hidden(rows, workspace: workspace).makeAsyncIterator()
        func post(_ name: Notification.Name) { workspace.post(name: name, object: nil) }

        post(NSWorkspace.screensDidSleepNotification)
        #expect(await hidden.next() == [.displayAsleep])
        // A second sleep changes nothing, so the next set is the system's.
        post(NSWorkspace.screensDidSleepNotification)
        post(NSWorkspace.willSleepNotification)
        #expect(await hidden.next() == [.displayAsleep, .systemAsleep])
        post(NSWorkspace.didWakeNotification)
        #expect(await hidden.next() == [.displayAsleep])
        post(NSWorkspace.screensDidWakeNotification)
        #expect(await hidden.next() == [])
        post(NSWorkspace.sessionDidResignActiveNotification)
        #expect(await hidden.next() == [.switchedOut])
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        #expect(await hidden.next() == [])
    }

    @Test func theDisplaysAreOnUnlessDisplayAsleepIsInForce() async {
        let (hidden, feed) = AsyncStream<Set<ScreenHider>>.makeStream()
        var on = ScreenMonitor.changes(hidden).makeAsyncIterator()
        feed.yield([.locked])
        feed.yield([.locked, .displayAsleep])
        #expect(await on.next() == false)
        feed.yield([.displayAsleep])
        feed.yield([])
        #expect(await on.next() == true)
        feed.yield([.screenSaver])
        feed.finish()
        #expect(await on.next() == nil)
    }

    /// On the system's own distributed center, under a name only this test posts: NSApplication
    /// suspends that center while the app is inactive, and a lock must still arrive.
    @MainActor @Test(.timeLimit(.minutes(1))) func aDistributedHiderArrivesWhileTheCenterIsSuspended() async throws {
        let center = DistributedNotificationCenter.default()
        let id = UUID().uuidString
        let row = ScreenMonitor.Signal(hider: .locked, center: .distributed,
                                       starts: Notification.Name("OrangeDrinkTests.locked.\(id)"), ends: Notification.Name("OrangeDrinkTests.unlocked.\(id)"))
        let hidden = ScreenMonitor.hidden([row], workspace: NotificationCenter(), distributed: center)
        let was = center.suspended
        center.suspended = true
        defer { center.suspended = was }
        // Posted without deliverImmediately, so only the observer's own suspension behavior lets it through.
        center.postNotificationName(row.starts, object: nil, userInfo: nil, deliverImmediately: false)
        let arrived = await withTaskGroup(of: Set<ScreenHider>?.self) { group in
            group.addTask { await hidden.first { _ in true } }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        #expect(arrived == [.locked])
    }
}
