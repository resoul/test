/// A value that can change, and that anything reading it under tracking depends on.
///
///     let isFollowing = State(false)
///     isFollowing.value = true        // observers that read it run at the next flush
///
/// Reading and writing are synchronous: `value` is always the latest value written. Writing
/// an equal value (for an `Equatable` value) changes nothing and notifies no one.
///
/// Ownership: the creator owns it; dependents are held weakly. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public final class State<Value>: Source {
    private var storage: Value
    private let isEqual: ((Value, Value) -> Bool)?
    private var dependents = Dependents()
    private(set) var version: UInt64 = 0

    /// A state whose every write counts as a change.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ initial: Value) {
        storage = initial
        isEqual = nil
    }

    /// A state that ignores writes of an equal value.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ initial: Value) where Value: Equatable {
        storage = initial
        isEqual = { $0 == $1 }
    }

    /// The current value. Reading it under tracking makes the tracker depend on it.
    ///
    /// Ownership: returns a copy. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var value: Value {
        get {
            Tracking.record(self)
            return storage
        }
        set {
            if let isEqual, isEqual(storage, newValue) { return }

            storage = newValue
            version &+= 1
            dependents.notify()
        }
    }

    /// Changes the value in place: one write, however many fields change.
    ///
    /// Ownership: `transform` borrows the value for the call. Isolation: MainActor.
    /// Errors: rethrows `transform`'s error, leaving the value as it was. Cancellation: not
    /// applicable.
    public func update(_ transform: (inout Value) throws -> Void) rethrows {
        var copy = storage
        try transform(&copy)
        value = copy
    }

    func refresh() {}

    func addDependent(_ dependent: any Dependent) {
        dependents.add(dependent)
    }

    func removeDependent(_ dependent: any Dependent) {
        dependents.remove(dependent)
    }
}
