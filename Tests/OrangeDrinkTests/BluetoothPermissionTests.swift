import CoreBluetooth
import os
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] The wait on the Bluetooth prompt, over stand-in updates: no manager is made, so no prompt shows.
struct BluetoothPermissionTests {
    private static func updates(_ authorizations: CBManagerAuthorization...) -> AsyncStream<CBManagerAuthorization> {
        AsyncStream { continuation in authorizations.forEach { continuation.yield($0) } }
    }

    private static func reports(_ updates: AsyncStream<CBManagerAuthorization>) async throws -> [BluetoothPermission] {
        var reported: [BluetoothPermission] = []
        try await BluetoothPermission.answer(from: updates) { reported.append($0) }
        return reported
    }

    @Test func theWaitReturnsAtTheFirstAnswer() async throws {
        #expect(try await Self.reports(Self.updates(.notDetermined, .allowedAlways, .denied)) == [.notDetermined, .allowed])
        #expect(try await Self.reports(Self.updates(.denied)) == [.denied])
    }

    /// What the delegate calls of a Mac with Bluetooth off may be: updates that are no answer.
    @Test func aRepeatedNotDeterminedIsNoAnswer() async throws {
        #expect(try await Self.reports(Self.updates(.notDetermined, .notDetermined, .allowedAlways)) == [.notDetermined, .notDetermined, .allowed])
    }

    @Test func aCancelledWaitThrowsSoNothingPastItRuns() async {
        let waiting = Task { try await Self.reports(Self.updates(.notDetermined)) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func aProfilesRestrictionIsARefusal() {
        #expect(BluetoothPermission(.restricted) == .denied)
    }

    @Test func aListKeepsTheLastPermission() {
        var list = DeviceList()
        #expect(list.permission == .allowed)
        list.apply(.permission(.notDetermined))
        list.apply(.permission(.denied))
        #expect(list.permission == .denied)
    }

    // The stream with the real setup behind it: `power` is the first thing past the wait, and it throws, so no test reaches IOBluetooth.
    @Test func nothingIsSetUpUntilTheAnswer() async throws {
        let (updates, feed) = AsyncStream<CBManagerAuthorization>.makeStream()
        let reached = Reached()
        let events = BluetoothDevices.events(authorizations: { updates }, power: { () throws(BluetoothDevicesError) in
            reached.mark()
            throw .missingSymbol("stand-in")
        })
        var iterator = events.makeAsyncIterator()
        feed.yield(.notDetermined)
        #expect(try await iterator.next() == .permission(.notDetermined))
        #expect(!reached.isMarked)
        feed.yield(.allowedAlways)
        #expect(try await iterator.next() == .permission(.allowed))
        await #expect(throws: BluetoothDevicesError.missingSymbol("stand-in")) { _ = try await iterator.next() }
        #expect(reached.isMarked)
    }
}

private final class Reached: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func mark() { state.withLock { $0 = true } }
    var isMarked: Bool { state.withLock { $0 } }
}
