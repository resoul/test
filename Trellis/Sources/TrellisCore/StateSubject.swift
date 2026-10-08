/// A latest-value source of displayed state (C29): the smallest thing a model can be
/// published through so that a mounted host can drive a node's `update(model)` from it.
///
/// Semantics are *latest value*, never events: `send` replaces `current`, an equal value is a
/// no-op, and an observer that could not be served in between two sends sees only the last
/// one. Nothing is queued — the subject holds exactly one value. Delivery to observers is
/// synchronous on the MainActor; a producer on another executor hops here to `send`, which
/// keeps every `Node` mutation on the MainActor without a lock or an unchecked `Sendable`.
///
/// This is deliberately not a store, dependency tracker, or property wrapper: those are
/// designed later against a real consumer (plan §7, N04). Adapters for other state
/// mechanisms feed this type.
///
/// Ownership: the creator owns the subject; observers are owned by whoever holds their
/// `StateObservation`. Isolation: MainActor. Errors: none. Cancellation: an observation ends
/// when its token is cancelled or released.
@MainActor
public final class StateSubject<Value: Sendable & Equatable> {
    /// The latest value sent, or the initial one.
    ///
    /// Ownership: returns a copy. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var current: Value

    private var observers: [UInt64: @MainActor (Value) -> Void] = [:]
    private var nextObserverID: UInt64 = 0

    /// Creates a subject holding `initial`.
    ///
    /// Ownership: the caller owns the subject. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(_ initial: Value) {
        current = initial
    }

    /// Replaces the current value and notifies observers. Returns `false`, doing nothing,
    /// when `value` equals `current` — equal state never starts work downstream.
    ///
    /// Ownership: takes ownership of `value`. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func send(_ value: Value) -> Bool {
        guard value != current else { return false }
        current = value
        for observer in observers.values {
            observer(value)
        }
        return true
    }

    /// Number of live observers — a test hook for ownership assertions.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var observerCount: Int { observers.count }

    /// Registers `handler` for every value sent from now on (not for `current` — the caller
    /// reads that directly if it wants a starting point). The host's binding is the intended
    /// caller; it is `package` so the subscription owner stays the mounted session (D14).
    package func observe(_ handler: @escaping @MainActor (Value) -> Void) -> StateObservation {
        nextObserverID &+= 1
        let id = nextObserverID
        observers[id] = handler
        return StateObservation { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }
}

/// Cancellation token for one `StateSubject.observe` registration. Cancelling twice is safe;
/// the holder must cancel explicitly — a `deinit` cannot touch MainActor state in Swift 6,
/// so a token merely released leaves its (harmless, `weak`-captured) entry registered until
/// the subject dies. The only holder is the host's `StateBinding`, which always cancels.
///
/// Ownership: the holder owns the observation. Isolation: MainActor. Errors: none.
/// Cancellation: `cancel()`.
@MainActor
package final class StateObservation {
    private var onCancel: (@MainActor () -> Void)?

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    package func cancel() {
        onCancel?()
        onCancel = nil
    }
}
