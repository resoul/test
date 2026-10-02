/// A ``PreferenceBackend`` that keeps values in memory, for tests and previews.
public final class InMemoryPreferenceBackend: PreferenceBackend {
    private var storage: [String: PreferenceRepresentation]

    public init(_ initial: [String: PreferenceRepresentation] = [:]) {
        storage = initial
    }

    public func read(_ name: String) -> PreferenceRepresentation? { storage[name] }

    public func write(_ value: PreferenceRepresentation, for name: String) {
        storage[name] = value
    }

    public func remove(_ name: String) { storage[name] = nil }

    // Nothing but the owning actor can change the memory, so there is nothing to report.
    public func observeExternalChanges(_ onChange: @escaping @Sendable () -> Void) {}
}
