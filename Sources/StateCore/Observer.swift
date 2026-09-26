/// Watches what a piece of code reads and reports once when any of it changes.
///
///     let observer = Observer { view.setNeedsLayout() }
///     let spec = observer.track { layoutSpec() }   // depends on what layoutSpec() read
///
/// Every `track` replaces the dependencies with what that run read, so a branch no longer
/// taken stops being watched. Changes are not reported one by one: the observer is queued
/// and `onChange` runs at the next `StateUpdates.flush()`, once, and only if a value it read
/// really changed by then. It keeps reporting until the next `track` picks up the new
/// versions.
///
/// Ownership: the caller owns it; states hold it weakly, so releasing it ends the
/// observation. Isolation: MainActor. Errors: none. Cancellation: `cancel()` or release.
@MainActor
public final class Observer: Dependent {
    private let onChange: @MainActor () -> Void
    private var reads = Reads()
    private var isQueued = false
    private var isCancelled = false
    let order: UInt64

    /// An observer that calls `onChange` at a flush after something it tracked changed.
    ///
    /// Ownership: keeps `onChange`; `onChange` must not keep the observer, or it lives until
    /// cancelled. Isolation: MainActor. Errors: none. Cancellation: `cancel()`.
    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        order = StateUpdates.nextOrder()
    }

    /// Runs `body` and makes its reads the observer's dependencies.
    ///
    /// Ownership: returns what `body` returns. Isolation: MainActor. Errors: rethrows
    /// `body`'s error; the dependencies are then those read before it threw. Cancellation:
    /// after `cancel()` the body still runs but nothing is watched.
    public func track<Result>(_ body: () throws -> Result) rethrows -> Result {
        var collected = Reads()
        defer {
            if !isCancelled {
                collected.subscribe(self, replacing: reads)
                reads = collected
                // A value read and then changed during the run itself changed before this
                // observer was subscribed to it.
                if reads.changed() { sourceMayHaveChanged() }
            }
        }
        return try Tracking.collect(into: &collected, body)
    }

    /// Stops watching. Safe to call more than once.
    ///
    /// Ownership: releases the subscriptions. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation.
    public func cancel() {
        isCancelled = true
        reads.unsubscribe(self)
        reads = Reads()
    }

    func sourceMayHaveChanged() {
        guard !isCancelled, !isQueued else { return }

        isQueued = true
        StateUpdates.enqueue(self)
    }

    /// Called by a flush that gave up before running it: a later change queues it again.
    func leaveQueue() {
        isQueued = false
    }

    /// Called by the flush: reports if something read really changed.
    func runIfChanged() {
        isQueued = false
        guard !isCancelled, reads.changed() else { return }

        onChange()
    }
}

/// Runs `body` now and again, at a flush, whenever something it read has changed.
///
///     let effect = Effect { label.text = model.user.value.name }
///
/// Ownership: the caller owns it; states hold it weakly, so releasing it stops it. `body`
/// must not keep the effect. Isolation: MainActor. Errors: none. Cancellation: `cancel()`
/// or release.
@MainActor
public final class Effect {
    private let observer: Observer

    /// Runs `body` at once, tracking what it reads.
    ///
    /// Ownership: keeps `body`. Isolation: MainActor. Errors: none. Cancellation:
    /// `cancel()`.
    public init(_ body: @escaping @MainActor () -> Void) {
        let run = Run(body)
        observer = Observer { run.again() }
        run.observer = observer
        observer.track(body)
    }

    /// Stops the effect. Safe to call more than once.
    ///
    /// Ownership: releases the subscriptions. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation.
    public func cancel() {
        observer.cancel()
    }

    /// The body and a weak way back to its observer, so the observer's `onChange` does not
    /// keep the observer alive.
    @MainActor
    private final class Run {
        let body: @MainActor () -> Void
        weak var observer: Observer?

        init(_ body: @escaping @MainActor () -> Void) {
            self.body = body
        }

        func again() {
            observer?.track(body)
        }
    }
}
