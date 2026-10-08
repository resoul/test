import TrellisCore
import TrellisRender

/// One live connection from a `Flux<Value>` stream to a node-updating closure, mounted on a
/// `NodeHostBridge` (R03, P6.2). Bridges the async, non-replaying Flux world onto the existing,
/// thoroughly exercised `StateSubject`/D14 delivery path instead of re-implementing session
/// ownership, bounded latest delivery, suspend/resume, or re-attach: a private `StateSubject`
/// seeded with `initial` is the only thing the bridge ever sees, and a `Task` pumps distinct
/// values from `flux.stream` into it. `TrellisCore`/`TrellisRender` gain no Flux dependency —
/// this type lives in `TrellisFlux`, the only module that imports both.
///
/// Ownership: the bridge retains this binding until `cancel()` — dropping the returned
/// reference does **not** stop delivery, exactly like `NodeHostBridge.bindState` (P6.2:
/// "владелец UI-доставки — mounted session", not whichever object happens to hold the
/// caller's handle). Its `update` closure must not retain the bridge. Isolation: MainActor.
/// Errors: none. Cancellation: `cancel()` stops both the pump and bridge delivery; no value
/// already in flight when `cancel()` runs is delivered afterward.
@MainActor
public final class FluxStateBinding<Value: Sendable & Equatable> {
    private let subject: StateSubject<Value>
    private var stateBinding: StateBinding?
    private var pump: Task<Void, Never>?

    fileprivate init(
        bridge: NodeHostBridge,
        flux: Flux<Value>,
        initial: Value,
        animation: @escaping @Sendable (Value, Value) -> Animation,
        update: @escaping @MainActor (Value, Animation) -> Void
    ) {
        let subject = StateSubject(initial)
        self.subject = subject
        var previous = initial
        var hasDeliveredOnce = false
        // `[self]` here is the only thing keeping this binding alive once `bindFlux` returns:
        // the bridge already retains the closure below for as long as the underlying
        // `StateSubject` registration is active (D14), so capturing `self` in it makes the
        // bridge transitively retain this binding — and, through the `pump` property, the
        // Flux subscription itself — the same way a caller who never stores `bindState`'s
        // returned handle still keeps receiving delivery. `cancel()` is what breaks this
        // (self ↔ record) cycle, matching `StateBindingRecordOf`'s own "the holder must cancel
        // explicitly" contract; without it, this stays retained until the bridge disposes all
        // its bindings — intentional, not a leak by omission.
        stateBinding = bridge.bindState(subject) { [self] value in
            // `self` is captured only to be retained (see the comment above) — reference it so
            // the compiler does not flag the capture as unused.
            withExtendedLifetime(self) {}
            // P6.2: replay/first attach carries no animation intent — only a genuine change
            // observed after the first delivery does. A coalesced burst only ever reaches here
            // once, with the last accepted value, so this is also "last state's intent wins"
            // without any separate bookkeeping for the values it replaced.
            let intent: Animation = hasDeliveredOnce ? animation(previous, value) : .none
            hasDeliveredOnce = true
            previous = value
            update(value, intent)
        }
        pump = Task { @MainActor in
            for await value in flux.stream {
                // Checked right before acting on a value actually pulled off the stream, not
                // only at the loop's top: a `cancel()` that lands while `flux.stream` is
                // suspended in `next()` is observed here before this value ever reaches the
                // subject (P6.2: "cancel/detach/replaceRoot защищаются... даже когда callback
                // уже ждёт MainActor").
                guard !Task.isCancelled else { break }
                subject.send(value)
            }
        }
    }

    /// Whether this binding still delivers. `false` after `cancel()`, or if the underlying
    /// bridge binding was already inactive when this was constructed.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var isActive: Bool { stateBinding?.isActive ?? false }

    /// Ends this binding for good: stops consuming `flux.stream` and unsubscribes from the
    /// bridge. Safe to call twice.
    ///
    /// Ownership: releases the pump task and the bridge registration. Isolation: MainActor.
    /// Errors: none. Cancellation: this is the cancellation.
    public func cancel() {
        pump?.cancel()
        pump = nil
        stateBinding?.cancel()
        // Breaks the self ↔ record cycle documented at `init`: dropping this was the only
        // thing still keeping `self` (and therefore `pump`) alive once the caller's own
        // reference, if any, is gone.
        stateBinding = nil
    }

    deinit {
        // Reached only if this binding was never registered with a bridge in a way that could
        // retain it (defensive fallback), since `cancel()` is otherwise required to break the
        // cycle `init` documents before ARC ever runs this. `Task.cancel()` is not
        // actor-isolated and safe from any context, unlike `StateBinding.cancel()` (MainActor)
        // — the same limitation `StateObservation` documents: a `deinit` cannot reach MainActor
        // state in Swift 6.
        pump?.cancel()
    }
}

extension NodeHostBridge {
    /// Connects a `Flux<Value>` stream to a node-updating closure for the life of the returned
    /// binding (R03, P6.2): every distinct value `flux.stream` yields reaches `update` on the
    /// MainActor through the same bounded, suspend/resume-aware path `bindState` already gives
    /// a `StateSubject` (D14) — re-attaching this bridge redelivers the current value, suspend
    /// holds only the latest for `resume()`, and no value already in flight when `cancel()`
    /// runs is delivered afterward.
    ///
    /// `Flux` has no synchronous current, so `initial` stands in for the first frame; it is
    /// delivered with `Animation.none`. Every later distinct value's animation intent comes
    /// from `animation(previous, next)`, computed against the last value this binding actually
    /// delivered. `update` is expected to call `someNode.animate(intent) { ... }` around its own
    /// mutations — this binding never touches a `Node` itself.
    ///
    /// **Coalescing a fast producer is the producer's job, not this binding's.** `bindState`'s
    /// existing coalescing (a synchronous burst of `StateSubject.send` collapses to one
    /// delivery, D14) relies on all of a burst's sends happening in one MainActor stretch with
    /// no `await` between them. A pump reading `flux.stream` cannot reproduce that for values
    /// `Flux` itself produced on separate turns: each `for await` iteration is a real
    /// suspension, and — verified empirically, not merely assumed — even values already
    /// sitting in the stream's buffer are each redelivered through a full actor-queue
    /// round-trip, interleaved with this binding's own scheduled delivery, not drained in one
    /// synchronous sweep. So a raw, unthrottled `Flux<Value>` that emits N values in quick
    /// succession can still reach `update` N times, each its own bridge commit — this binding
    /// does not silently reinterpret that as one event. A caller wanting fewer, coalesced
    /// deliveries composes `flux.throttle(_:)`/`.debounce(_:)` (already existing Flux
    /// operators) upstream of `bindFlux`, the same way it would upstream of any other sink;
    /// `bindFlux` does not re-implement rate limiting.
    ///
    /// Ownership: the bridge retains the returned binding until `cancel()` (see
    /// `FluxStateBinding`'s own documentation) — dropping it does not stop delivery. Isolation:
    /// MainActor. Errors: none. Cancellation: `FluxStateBinding.cancel()`.
    @discardableResult
    public func bindFlux<Value: Sendable & Equatable>(
        _ flux: Flux<Value>,
        initial: Value,
        animation: @escaping @Sendable (Value, Value) -> Animation = { _, _ in .smooth },
        update: @escaping @MainActor (Value, Animation) -> Void
    ) -> FluxStateBinding<Value> {
        FluxStateBinding(
            bridge: self,
            flux: flux,
            initial: initial,
            animation: animation,
            update: update
        )
    }
}
