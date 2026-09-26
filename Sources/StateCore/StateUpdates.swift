/// When observers learn about changes. Writes to states only queue the observers that may
/// be affected; `flush()` runs them, in the order they were created, each at most once per
/// round. So any number of writes in one stretch of main-actor work cause one update.
///
/// By default a flush is scheduled as a main-actor task after the first write. A UI layer
/// replaces `scheduler` to flush right before it lays out and draws a frame.
///
/// Ownership: global main-actor state. Isolation: MainActor. Errors: none. Cancellation:
/// not applicable.
@MainActor
public enum StateUpdates {
    /// Queued observers, held weakly: an observer released before the flush does not run.
    private static var queue: [WeakObserver] = []
    private static var isScheduled = false
    private static var lastOrder: UInt64 = 0

    /// How many times one flush lets observers run before it gives up: an observer that
    /// keeps changing what it reads would otherwise never let the flush end.
    ///
    /// Ownership: global value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static var roundLimit = 100

    /// Number of flushes that stopped at `roundLimit` — a sign of observers that keep
    /// changing each other's states.
    ///
    /// Ownership: global value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) static var limitReached = 0

    /// Arranges for `flush` to be called soon. Called once per batch of writes.
    ///
    /// Ownership: global value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static var scheduler: @MainActor (_ flush: @escaping @MainActor () -> Void) -> Void =
        { flush in
            Task { @MainActor in flush() }
        }

    /// Whether observers are waiting for a flush.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public static var hasPendingUpdates: Bool { !queue.isEmpty }

    /// Runs every queued observer whose reads really changed, then those queued by what
    /// they did, until nothing is left or `roundLimit` rounds have run.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func flush() {
        isScheduled = false
        var rounds = 0
        while !queue.isEmpty {
            if rounds == roundLimit {
                limitReached += 1
                for entry in queue {
                    entry.observer?.leaveQueue()
                }
                queue.removeAll()
                return
            }

            rounds += 1
            let batch = queue.compactMap(\.observer).sorted { $0.order < $1.order }
            queue.removeAll()
            for observer in batch {
                observer.runIfChanged()
            }
        }
    }

    static func enqueue(_ observer: Observer) {
        queue.append(WeakObserver(observer: observer))
        guard !isScheduled else { return }

        isScheduled = true
        scheduler { flush() }
    }

    static func nextOrder() -> UInt64 {
        lastOrder &+= 1
        return lastOrder
    }
}

private struct WeakObserver {
    weak var observer: Observer?
}
