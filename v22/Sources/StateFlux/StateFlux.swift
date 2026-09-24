import Flux
import StateCore

// The boundary between `StateCore` and Flux. Flux streams are asynchronous; states are
// synchronous and live on the main actor. Values cross in both directions on the main
// actor, and a state seen as a stream behaves as a state: the latest value, not events.

extension Flux {
    /// Writes every value of the stream into `state`, on the main actor. What reads the state
    /// sees the values at the next flush; values that arrive before it collapse into the
    /// last one.
    ///
    /// Ownership: the returned subscription owns the delivery; the state is held weakly, so a
    /// released state receives nothing. Isolation: MainActor. Errors: none. Cancellation:
    /// cancel the subscription, or let its `SubscriptionBag` go. A subscription that is
    /// dropped without being cancelled keeps delivering until the stream ends.
    @MainActor
    @discardableResult
    public func bind(to state: State<T>) -> Subscription {
        sinkOnMain { [weak state] value in
            state?.value = value
        }
    }
}

extension State where Value: Sendable {
    /// The state as a stream: its current value first, then the value it has after each
    /// change, at the flush that follows it. Changes between two flushes arrive as one value,
    /// and a slow subscriber gets only the latest one.
    ///
    /// Ownership: each subscription holds the state until it ends. Isolation: values are read
    /// on the main actor; the stream is consumed anywhere. Errors: none. Cancellation: ending
    /// the subscription stops watching the state.
    public nonisolated var flux: Flux<Value> {
        Flux { [self] in
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let watch = Watch()
                continuation.onTermination = { _ in
                    Task { @MainActor in watch.stop() }
                }
                Task { @MainActor in
                    watch.start { continuation.yield(self.value) }
                }
            }
        }
    }
}

/// One subscription's effect. Starting and stopping arrive as separate main-actor tasks, so
/// a stop that comes first still wins.
@MainActor
private final class Watch {
    private var effect: Effect?
    private var isStopped = false

    func start(_ body: @escaping @MainActor () -> Void) {
        guard !isStopped else { return }

        effect = Effect(body)
    }

    func stop() {
        isStopped = true
        effect?.cancel()
        effect = nil
    }
}
