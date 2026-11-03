import CoreBluetooth
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] What macOS's answers do, over stand-in asks and a stand-in watcher: no manager is made, so no prompt shows.
struct BluetoothPermissionTests {
    private typealias Ask = BluetoothPermission.Ask

    @Test func aProfilesRestrictionIsARefusal() {
        #expect(BluetoothPermission(.restricted) == .denied)
    }

    /// A running app's property goes on saying allowed after the permission is taken away.
    @Test func anUnauthorizedManagerIsARefusalWhateverThePropertySays() {
        #expect(CBManagerAuthorization(state: .unauthorized, authorization: .allowedAlways) == .denied)
        for state in [CBManagerState.unsupported, .poweredOff, .poweredOn] {
            #expect(CBManagerAuthorization(state: state, authorization: .allowedAlways) == .allowedAlways)
            #expect(CBManagerAuthorization(state: state, authorization: .notDetermined) == .notDetermined)
            #expect(CBManagerAuthorization(state: state, authorization: .denied) == .denied)
        }
    }

    /// A stale allowed in a refused app must not end an ask on a state that has not settled.
    @Test(arguments: [CBManagerState.unknown, .resetting]) func anUnsettledManagerHasNoAnswerYet(state: CBManagerState) {
        #expect(CBManagerAuthorization(state: state, authorization: .allowedAlways) == nil)
    }

    @Test func aListIsUnreadUntilASweepAndSaysWhy() {
        var list = DeviceList(sources: [.bluetooth])
        #expect(list.unreadSources == [.bluetooth(.waiting)])
        list.apply(.permission(.notDetermined), from: .bluetooth)
        #expect(list.unreadSources == [.bluetooth(.unanswered)])
        list.apply(.permission(.denied), from: .bluetooth)
        #expect(list.unreadSources == [.bluetooth(.denied)])
        list.apply(.permission(.allowed), from: .bluetooth)
        #expect(list.unreadSources == [.bluetooth(.waiting)])
        list.apply(.reported(DeviceListTests.mouse.source), from: .bluetooth)
        #expect(list.unreadSources == [.bluetooth(.waiting)])
        list.apply(.swept([]), from: .bluetooth)
        #expect(list.unreadSources.isEmpty)
        list.apply(.swept([DeviceListTests.mouse.source]), from: .bluetooth)
        list.end(.bluetooth)
        #expect(list.unreadSources == [.bluetooth(.ended)])
        #expect(list.devices.isEmpty)
    }

    @Test func aRefusalHeardAfterASweepKeepsNoneOfItsRows() {
        var list = DeviceList(sources: [.bluetooth])
        list.apply(.swept([DeviceListTests.mouse.source]), from: .bluetooth)
        list.apply(.permission(.denied), from: .bluetooth)
        #expect(list.unreadSources == [.bluetooth(.denied)])
        #expect(list.devices.isEmpty)
    }

    // The loop of answers, over a stand-in watcher whose every sweep and stop is an event, so the stream's order is theirs.

    @Test func nothingIsSetUpUntilTheAnswer() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        let reached = Reached()
        let events = BluetoothDevices.events(asks: { _ in asks }, watcher: { _, _ in
            reached.mark()
            throw BluetoothDevicesError.missingSymbol("stand-in")
        })
        var iterator = events.makeAsyncIterator()
        ask.yield(.heard(.notDetermined))
        #expect(try await iterator.next() == .permission(.notDetermined))
        #expect(!reached.isMarked)
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == .permission(.allowed))
        await #expect(throws: BluetoothDevicesError.missingSymbol("stand-in")) { _ = try await iterator.next() }
        #expect(reached.isMarked)
    }

    @Test func aRefusalSetsNothingUpAndStaysSubscribed() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        var iterator = BluetoothDevices.events(asks: { _ in asks }, watcher: StandInWatcher.init).makeAsyncIterator()
        ask.yield(.heard(.denied))
        #expect(try await iterator.next() == .permission(.denied))
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == .permission(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
    }

    @Test func aMinutesAnswerSweepsAndTellsTheListNothing() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        var iterator = BluetoothDevices.events(asks: { _ in asks }, watcher: StandInWatcher.init).makeAsyncIterator()
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == .permission(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
    }

    @Test func anUnansweredAskLeavesTheLastAnswerStanding() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        var iterator = BluetoothDevices.events(asks: { _ in asks }, watcher: StandInWatcher.init).makeAsyncIterator()
        ask.yield(.stalled)
        ask.yield(.heard(.allowed))
        // A stall held nothing up and swept nothing: the first event is the answer's.
        #expect(try await iterator.next() == .permission(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
        ask.yield(.stalled)
        #expect(try await iterator.next() == StandInWatcher.sweep)
    }

    @Test func permissionTakenAwayStopsTheWatcherBeforeTheListHearsAndNothingSweepsAfter() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        var iterator = BluetoothDevices.events(asks: { _ in asks }, watcher: StandInWatcher.init).makeAsyncIterator()
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == .permission(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
        ask.yield(.heard(.denied))
        #expect(try await iterator.next() == StandInWatcher.stop)
        #expect(try await iterator.next() == .permission(.denied))
        // Further minutes make no event: the next one of any kind is this allowance's.
        ask.yield(.heard(.denied))
        ask.yield(.stalled)
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == .permission(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
    }

    @Test func aPromptAfterAnAnswerIsARefusalOfReading() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        var iterator = BluetoothDevices.events(asks: { _ in asks }, watcher: StandInWatcher.init).makeAsyncIterator()
        ask.yield(.heard(.allowed))
        #expect(try await iterator.next() == .permission(.allowed))
        #expect(try await iterator.next() == StandInWatcher.sweep)
        ask.yield(.heard(.notDetermined))
        #expect(try await iterator.next() == StandInWatcher.stop)
        #expect(try await iterator.next() == .permission(.notDetermined))
    }

    @MainActor @Test func aCancelledSubscriptionStopsItsWatcher() async throws {
        let (asks, ask) = AsyncStream.makeStream(of: Ask.self)
        let (swept, stopped) = (Reached(), Reached())
        let events = BluetoothDevices.events(asks: { _ in asks }, watcher: { continuation, _ in
            StandInWatcher(continuation, stopped: stopped)
        })
        let reader = Task { for try await event in events where event == StandInWatcher.sweep { swept.mark() } }
        ask.yield(.heard(.allowed))
        #expect(await eventually { swept.isMarked })
        reader.cancel()
        #expect(await eventually { stopped.isMarked })
    }

    // The asks themselves, over stand-in asks and a clock the test moves. The sleep a test waits for is how it knows the ask
    // before it was made.

    @Test func anAnsweredAskIsDroppedAndTheNextWaitsForTheMinute() async throws {
        let (timekeeper, made) = (ManualTimekeeper(), Made())
        var asks = BluetoothPermission.asks(first: made.ask, then: made.ask, timekeeper: timekeeper).makeAsyncIterator()
        await timekeeper.asleep()
        made.answer(.allowedAlways)
        #expect(await asks.next() == .heard(.allowed))
        #expect(made.count == 1)
        await made.dropped(1)
        await timekeeper.asleep()
        timekeeper.advance(by: BluetoothDevices.pollInterval)
        await made.reached(2)
        await timekeeper.asleep()
        made.answer(.denied)
        #expect(await asks.next() == .heard(.denied))
        await made.dropped(2)
    }

    @Test func aPromptHasNoBoundAndItsOneAskHearsTheAnswer() async throws {
        let (timekeeper, made) = (ManualTimekeeper(), Made())
        var asks = BluetoothPermission.asks(first: made.ask, then: made.ask, timekeeper: timekeeper).makeAsyncIterator()
        await timekeeper.asleep()
        made.answer(.notDetermined)
        #expect(await asks.next() == .heard(.notDetermined))
        #expect(timekeeper.sleeping == 0)
        // What the delegate calls of a Mac with Bluetooth off may be: updates that are no answer.
        made.answer(.notDetermined)
        made.answer(.allowedAlways)
        #expect(await asks.next() == .heard(.allowed))
        #expect(made.count == 1)
    }

    @Test(arguments: [1, 2]) func anAskWithNoAnswerByTheMinuteIsDroppedAndTheNextMadeAtOnce(silent: Int) async throws {
        let (timekeeper, made) = (ManualTimekeeper(), Made())
        var asks = BluetoothPermission.asks(first: made.ask, then: made.ask, timekeeper: timekeeper).makeAsyncIterator()
        for _ in 1..<silent {
            await timekeeper.asleep()
            made.answer(.allowedAlways)
            #expect(await asks.next() == .heard(.allowed))
            await timekeeper.asleep()
            timekeeper.advance(by: BluetoothDevices.pollInterval)
            await made.reached(silent)
        }
        await timekeeper.asleep()
        timekeeper.advance(by: BluetoothDevices.pollInterval)
        #expect(await asks.next() == .stalled)
        await made.dropped(silent)
        await made.reached(silent + 1)
    }

    @MainActor @Test func aCancelDuringAnAskMakesNoOther() async throws {
        let (timekeeper, made) = (ManualTimekeeper(), Made())
        let asks = BluetoothPermission.asks(first: made.ask, then: made.ask, timekeeper: timekeeper)
        let reader = Task { for await _ in asks {} }
        await timekeeper.asleep()
        reader.cancel()
        await reader.value
        await made.dropped(1)
        #expect(await eventually { timekeeper.sleeping == 0 })
        #expect(made.count == 1)
    }

    @MainActor @Test func aCancelDuringTheMinuteMakesNoAsk() async throws {
        let (timekeeper, made) = (ManualTimekeeper(), Made())
        let asks = BluetoothPermission.asks(first: made.ask, then: made.ask, timekeeper: timekeeper)
        let reader = Task { for await _ in asks {} }
        await timekeeper.asleep()
        made.answer(.allowedAlways)
        await made.dropped(1)
        await timekeeper.asleep()
        reader.cancel()
        await reader.value
        #expect(await eventually { timekeeper.sleeping == 0 })
        #expect(made.count == 1)
    }
}

/// A watcher with no IOBluetooth: each sweep is the list it is given, and its stop an event of its own, so a test reads the order.
final class StandInWatcher: DeviceWatcher {
    static let sweep = DeviceEvent.swept([DeviceListTests.mouse.source])
    static let stop = DeviceEvent.gone(DeviceID.bluetooth("stand-in watcher stopped"))

    private let continuation: BluetoothDevices.Events
    private let swept: DeviceEvent
    private let stopped: Reached?

    init(_ continuation: BluetoothDevices.Events, timekeeper: any Timekeeper) {
        self.continuation = continuation
        swept = Self.sweep
        stopped = nil
    }

    init(_ continuation: BluetoothDevices.Events, swept: DeviceEvent = sweep, stopped: Reached? = nil) {
        self.continuation = continuation
        self.swept = swept
        self.stopped = stopped
    }

    func start() { sweep() }
    func sweep() { continuation.yield(swept) }
    func stop() {
        stopped?.mark()
        continuation.yield(Self.stop)
    }
}

/// The asks a test's loop made, each of which it answers by hand, the latest first.
private final class Made: Sendable {
    private struct State {
        var asks: [BluetoothPermission.Updates.Continuation] = []
        var dropped = 0
        var waiting: [(reached: @Sendable (State) -> Bool, resume: CheckedContinuation<Void, Never>)] = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    @Sendable func ask() -> BluetoothPermission.Updates {
        let (updates, continuation) = BluetoothPermission.Updates.makeStream()
        continuation.onTermination = { [state] _ in
            state.withLockUnchecked { $0.dropped += 1; return Self.wake(&$0) }.forEach { $0.resume() }
        }
        state.withLockUnchecked { $0.asks.append(continuation); return Self.wake(&$0) }.forEach { $0.resume() }
        return updates
    }

    func answer(_ authorization: CBManagerAuthorization) {
        state.withLockUnchecked { $0.asks.last }?.yield(authorization)
    }

    var count: Int { state.withLockUnchecked { $0.asks.count } }

    func reached(_ count: Int) async { await wait { $0.asks.count >= count } }
    func dropped(_ count: Int) async { await wait { $0.dropped >= count } }

    private func wait(for reached: @escaping @Sendable (State) -> Bool) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLockUnchecked { state in
                if reached(state) { return true }
                state.waiting.append((reached, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private static func wake(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        let now = state
        state.waiting = now.waiting.filter { !$0.reached(now) }
        return now.waiting.filter { $0.reached(now) }.map(\.resume)
    }
}

final class Reached: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func mark() { state.withLock { $0 = true } }
    var isMarked: Bool { state.withLock { $0 } }
}
