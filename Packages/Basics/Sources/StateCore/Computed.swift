/// A value derived from other states, computed on first read and cached until something it
/// read changes.
///
///     let title = Computed { "\(user.value.name) · \(count.value)" }
///
/// It is lazy: nothing is computed while nobody reads it. An `Equatable` result that comes
/// out equal after a recompute is not a change, so what depends on it does not run.
///
/// Ownership: the creator owns it; it holds its sources strongly through its last reads and
/// its dependents weakly. Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public final class Computed<Value>: Source, Dependent {
    private let compute: @MainActor () -> Value
    private let isEqual: ((Value, Value) -> Bool)?
    private var cached: Value?
    private var stale = true
    private var reads = Reads()
    private var dependents = Dependents()
    private(set) var version: UInt64 = 0

    /// A computed value whose every recompute counts as a change.
    ///
    /// Ownership: keeps `compute`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ compute: @escaping @MainActor () -> Value) {
        self.compute = compute
        isEqual = nil
    }

    /// A computed value that is unchanged when it recomputes to an equal result.
    ///
    /// Ownership: keeps `compute`. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(_ compute: @escaping @MainActor () -> Value) where Value: Equatable {
        self.compute = compute
        isEqual = { $0 == $1 }
    }

    /// The current value, recomputed first if something it read has changed. Reading it
    /// under tracking makes the tracker depend on it.
    ///
    /// Ownership: returns a copy. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var value: Value {
        refresh()
        Tracking.record(self)
        // `refresh` always leaves a value.
        return cached!
    }

    func refresh() {
        guard stale else { return }

        stale = false
        // Only a possible change reached us: if none of our sources really changed, the
        // cached value still holds.
        if cached != nil && !reads.changed() { return }

        var newReads = Reads()
        let result = Tracking.collect(into: &newReads, compute)
        newReads.subscribe(self, replacing: reads)
        reads = newReads
        if let old = cached, let isEqual, isEqual(old, result) { return }

        cached = result
        version &+= 1
    }

    func sourceMayHaveChanged() {
        guard !stale else { return }

        stale = true
        dependents.notify()
    }

    func addDependent(_ dependent: any Dependent) {
        dependents.add(dependent)
    }

    func removeDependent(_ dependent: any Dependent) {
        dependents.remove(dependent)
    }
}
