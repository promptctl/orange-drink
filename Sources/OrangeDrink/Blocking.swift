import Dispatch

/// [LAW:single-enforcer] Where a blocking call waits: on a dispatch thread, never one of the concurrency pool's, which a few
/// stuck calls would use up. Returns the call's value once it has one.
func blocking<Value: Sendable>(qos: DispatchQoS.QoSClass = .default, _ call: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { done in
        DispatchQueue.global(qos: qos).async { done.resume(returning: call()) }
    }
}
