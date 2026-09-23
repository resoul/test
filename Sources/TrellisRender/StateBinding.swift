import TrellisCore

/// One live connection from a `StateSubject` to a node-updating closure, owned by the host
/// bridge for as long as it stays registered (C29, D14). Delivery follows the bridge's mount
/// state, not the binding's creation: values flow only while a root is attached and not
/// suspended, one deferred `update` per MainActor turn with the latest value; `detach()` stops
/// delivery and `attach` restores it, handing over the current value if it changed meanwhile.
///
/// Ownership: the bridge retains the binding until `cancel()`; the binding retains the
/// subject and the closure, never the bridge. Isolation: MainActor. Errors: none.
/// Cancellation: `cancel()` — no later value reaches the closure, including one already
/// scheduled.
@MainActor
public final class StateBinding {
    private let record: any StateBindingRecord
    private weak var owner: NodeHostBridge?

    init(record: any StateBindingRecord, owner: NodeHostBridge) {
        self.record = record
        self.owner = owner
    }

    /// Whether this binding still delivers. `false` after `cancel()` or after the owning
    /// bridge disposed its bindings.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var isActive: Bool { record.isActive }

    /// Ends this binding for good: unsubscribes from the subject and drops any pending
    /// delivery. Safe to call twice.
    ///
    /// Ownership: releases the subject observation. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation.
    public func cancel() {
        record.cancel()
        owner?.removeBinding(record)
    }
}

/// Type-erased face of a binding the bridge drives through mount-state transitions.
@MainActor
protocol StateBindingRecord: AnyObject {
    var isActive: Bool { get }
    /// A root is attached: subscribe and hand over the current value (if it changed since
    /// the last delivery — an untouched node still shows what it was last given), unless
    /// the host is suspended, in which case the value waits for `resume()`.
    func start(paused: Bool)
    /// The root was detached: unsubscribe; nothing is delivered until the next `start()`.
    func stop()
    /// The host is suspended: keep only the latest value, deliver it on `resume()`.
    func pause()
    func resume()
    func cancel()
}

/// The generic half: everything that knows `Value`.
@MainActor
final class StateBindingRecordOf<Value: Sendable & Equatable>: StateBindingRecord {
    private let subject: StateSubject<Value>
    private let update: @MainActor (Value) -> Void
    private let hostID: UInt64
    private var observation: StateObservation?
    private var latest: Value?
    private var lastDelivered: Value?
    private var paused = false
    private var deliveryScheduled = false
    private(set) var isActive = true

    init(subject: StateSubject<Value>, hostID: UInt64, update: @escaping @MainActor (Value) -> Void)
    {
        self.subject = subject
        self.hostID = hostID
        self.update = update
    }

    func start(paused: Bool) {
        guard isActive, observation == nil else { return }
        // The mount's own suspend state, not the previous mount's: a pause left behind by an
        // earlier `suspend()` must not hold the current value back (defect #21).
        self.paused = paused
        observation = subject.observe { [weak self] value in self?.receive(value) }
        // The current value is delivered synchronously so it is in place before the flush the
        // attach just scheduled — one commit shows the bound state, not a bare tree first.
        latest = subject.current
        deliverLatestNow()
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    func pause() { paused = true }

    /// Delivers synchronously: the bridge resumes bindings *before* its coordinator, so the
    /// flush that follows already snapshots the caught-up tree — a deferred delivery here
    /// let the first frame after resume commit the stale state and then commit again
    /// (defect #19).
    func resume() {
        guard paused else { return }
        paused = false
        deliverLatestNow()
    }

    func cancel() {
        isActive = false
        stop()
        latest = nil
        Log.on(.host, "state-unbind", host: hostID)
    }

    private func receive(_ value: Value) {
        latest = value
        guard !paused else { return }
        scheduleDelivery()
    }

    /// Coalesces a synchronous burst of sends into one `update` with the last value, on the
    /// next MainActor turn — the same boundary the render flush uses (plan §"обязательные
    /// свойства" 1): no queue of intermediate models, at most one pending delivery.
    private func scheduleDelivery() {
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deliveryScheduled = false
            self.deliverLatestNow()
        }
    }

    private func deliverLatestNow() {
        guard isActive, !paused, let value = latest, value != lastDelivered else { return }
        lastDelivered = value
        Log.on(.host, "state-deliver", host: hostID)
        update(value)
    }
}
