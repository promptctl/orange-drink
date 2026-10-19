import Foundation
import IOKit.ps
import notify

/// Pushes battery state to subscribers as powerd publishes it. Nothing here runs on a timer:
/// a subscription costs one read at subscribe time and one per powerd publish, which is what
/// keeps the app under PROJECT.md's 0.1% CPU budget.
enum BatteryMonitor {
    /// Every reading powerd publishes, starting with the state at subscribe time. nil is a Mac
    /// with no battery. A read that fails ends the stream with its error.
    ///
    /// [LAW:effects-at-boundaries] The one edge that listens to powerd. It registers for
    /// kIOPSNotifyAnyPowerSource, the one public key IOPowerSources.h documents for a change to
    /// any attribute, percent included; kIOPSNotifyTimeRemaining promises only estimate and
    /// power-source changes. The price is powerd's periodic republish, measured at one post a
    /// minute while held steady at 80% on AC, so one read a minute against the 60 ms a minute
    /// the CPU budget allows.
    ///
    /// [LAW:types-are-the-program] A reading is state, not history: a subscriber that falls
    /// behind gets the newest one, never a replay, so the buffer holds exactly one.
    static func readings() -> AsyncThrowingStream<BatteryReading?, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // [LAW:no-ambient-temporal-coupling] One serial queue owns every read for this
            // subscription, so the initial read and the notification reads cannot interleave.
            let queue = DispatchQueue(label: "\(IOKitBattery.logSubsystem).battery-monitor")
            var token: Int32 = 0
            let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, queue) { _ in
                publish(into: continuation)
            }
            guard status == NOTIFY_STATUS_OK else {
                IOKitBattery.log.error("battery notifications: notify_register_dispatch failed with \(status, privacy: .public)")
                continuation.finish(throwing: BatteryMonitorError.notifyRegistration(status: status))
                return
            }
            let registered = token
            IOKitBattery.log.info("battery notifications: registered token \(registered, privacy: .public)")
            continuation.onTermination = { _ in notify_cancel(registered) }
            queue.async { publish(into: continuation) }
        }
    }

    private static func publish(into continuation: AsyncThrowingStream<BatteryReading?, any Error>.Continuation) {
        do { continuation.yield(try IOKitBattery.read()) } catch { continuation.finish(throwing: error) }
    }

    /// Plug, unplug, and level changes, each within a second of powerd publishing it. A
    /// subscriber that subscribes while the state is steady gets nothing until it changes;
    /// the state itself, battery or none, is `readings()`' first element.
    static func events() -> AsyncThrowingStream<BatteryEvent, any Error> {
        events(from: readings())
    }

    /// [LAW:composability] The deltas between consecutive readings of any stream, so the
    /// loop is checked from recorded readings with no powerd in the room. Events are never
    /// dropped: a delta a subscriber has not pulled yet is still owed to it.
    static func events<Readings: AsyncSequence & Sendable>(from readings: Readings) -> AsyncThrowingStream<BatteryEvent, any Error>
    where Readings.Element == BatteryReading? {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // A battery that is absent takes part in no plug, unplug, or level change,
                    // so those readings are not consecutive states to compare.
                    var previous: BatteryReading?
                    for try await reading in readings.compactMap({ $0 }) {
                        for event in previous.map({ BatteryEvent.changes(from: $0, to: reading) }) ?? [] {
                            IOKitBattery.log.info("battery event: \(String(describing: event), privacy: .public)")
                            continuation.yield(event)
                        }
                        previous = reading
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum BatteryMonitorError: Error, Equatable {
    /// notifyd refused the registration; the status is notify(3)'s NOTIFY_STATUS_* code.
    case notifyRegistration(status: UInt32)
}
