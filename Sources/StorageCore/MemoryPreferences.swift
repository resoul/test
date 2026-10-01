/// A preference store that keeps its values in memory only.
///
/// For tests and previews, and for code that needs the same store type with nothing persisted.
/// Nothing survives the store. It holds the observers' continuations, which end when their
/// streams are cancelled.
public actor MemoryPreferences: PreferenceStore {
    private var values: [String: PreferenceValue]
    private var observers:
        [Int: (name: String, continuation: AsyncStream<PreferenceValue?>.Continuation)] = [:]
    private var nextObserver = 0

    /// Creates a store with the given values already in it.
    public init(_ values: [String: PreferenceValue] = [:]) {
        self.values = values
    }

    /// The number of streams currently watching the store.
    var observerCount: Int { observers.count }

    public func rawValue(forName name: String) -> PreferenceValue? {
        values[name]
    }

    public func setRawValue(_ value: PreferenceValue?, forName name: String) {
        if case .unsupported = value { return }

        values[name] = value
        for observer in observers.values where observer.name == name {
            observer.continuation.yield(value)
        }
    }

    public func observeRawValue(forName name: String) -> AsyncStream<PreferenceValue?> {
        let (stream, continuation) = AsyncStream<PreferenceValue?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = nextObserver
        nextObserver += 1
        observers[id] = (name, continuation)
        continuation.yield(values[name])
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: Int) {
        observers[id] = nil
    }
}
