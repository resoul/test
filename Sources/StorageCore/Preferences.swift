import Foundation

/// Where a ``Preferences`` actor keeps its values: a property-list store such as UserDefaults,
/// or memory.
///
/// A backend is plain synchronous storage used by exactly one ``Preferences`` actor, which
/// serialises every call; it does not need to be thread-safe and is not `Sendable`.
public protocol PreferenceBackend {
    /// The stored value, or `nil` when nothing is stored under `name`.
    func read(_ name: String) -> PreferenceRepresentation?
    func write(_ value: PreferenceRepresentation, for name: String)
    func remove(_ name: String)

    /// Starts reporting changes that did not come through this backend's own `write` and
    /// `remove`, such as another object or process writing the same store. `onChange` may be
    /// called on any thread, at most once per change, and says nothing about which name
    /// changed. Called at most once per backend, before the first observer is registered.
    func observeExternalChanges(_ onChange: @escaping @Sendable () -> Void)
}

/// Typed access to small settings — a theme, a sort order — with defaults and observation.
///
/// The actor owns its backend, so reads and writes are serialised and never block the main
/// actor. A screen should load the values it needs into `State` when it opens and write
/// changes back with `await`; reading a `State` never touches the store.
///
/// A value that is stored but does not decode as the key's type is an error
/// (``PreferenceError/decodingFailed(key:underlying:)``), not the default: a missing key
/// and a damaged one are different situations. ``remove(_:)`` clears the damaged value.
///
/// Writes are not durable the moment they return, a write of several keys is not atomic, and
/// there is no compare-and-swap across processes. Data with such requirements belongs in
/// the database.
public actor Preferences {
    private let backend: any PreferenceBackend
    private let namespace: String
    private var watchers: [UUID: Watcher] = [:]
    private var isObservingBackend = false

    /// - Parameters:
    ///   - backend: Handed over to the actor, which becomes its only user.
    ///   - namespace: A prefix for every stored name, so that unrelated features cannot clash
    ///     in a shared store. The prefix is joined with a dot and empty means none.
    public init(backend: sending some PreferenceBackend, namespace: String = "") {
        self.backend = backend
        self.namespace = namespace
    }

    /// Preferences held in memory, for tests and previews. Nothing survives the actor.
    public static func inMemory(namespace: String = "") -> Preferences {
        Preferences(backend: InMemoryPreferenceBackend(), namespace: namespace)
    }

    /// The stored value, or the key's default when nothing is stored.
    ///
    /// - Throws: ``PreferenceError/decodingFailed(key:underlying:)`` when the stored value does
    ///   not decode as the key's type.
    public func value<Value>(for key: PreferenceKey<Value>) throws -> Value {
        try Self.outcome(of: backend.read(storedName(key)), for: key).get()
    }

    /// Stores `value`. Observers of the key see it after the call.
    ///
    /// - Throws: ``PreferenceError/encodingFailed(key:underlying:)``; nothing is written then.
    public func set<Value>(_ value: Value, for key: PreferenceKey<Value>) throws {
        let representation: PreferenceRepresentation
        do {
            representation = try key.codec.encode(value)
        } catch {
            throw PreferenceError.encodingFailed(key: key.name, underlying: error)
        }
        backend.write(representation, for: storedName(key))
        refreshWatchers()
    }

    /// Removes the stored value, so reading gives the key's default again. Removing a key
    /// that holds nothing, or a damaged value, is not an error.
    public func remove<Value>(_ key: PreferenceKey<Value>) {
        backend.remove(storedName(key))
        refreshWatchers()
    }

    /// The key's current value, then each change to it.
    ///
    /// A value that is stored again unchanged is not reported, and a change that happens
    /// before the consumer reads the previous one replaces it: the stream describes the
    /// latest state, not a log of writes. A damaged stored value arrives as a failure
    /// element and the stream goes on, so a later write or ``remove(_:)`` is reported as
    /// usual. Changes made by other objects of the same store are picked up when the backend
    /// reports them, with the same rules.
    ///
    /// The stream ends only when the consumer stops iterating or cancels; that releases the
    /// registration. The actor does not hold a reference to the consumer.
    public func values<Value>(for key: PreferenceKey<Value>)
        -> AsyncStream<Result<Value, PreferenceError>>
    {
        startObservingBackendIfNeeded()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Result<Value, PreferenceError>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        let name = storedName(key)
        let current = backend.read(name)
        continuation.yield(Self.outcome(of: current, for: key))
        watchers[id] = Watcher(name: name, last: current) { representation in
            continuation.yield(Self.outcome(of: representation, for: key))
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWatcher(id) }
        }
        return stream
    }

    private struct Watcher {
        let name: String
        /// What the watcher was last told, so that an unchanged value is not reported twice.
        var last: PreferenceRepresentation?
        let publish: (PreferenceRepresentation?) -> Void
    }

    private func storedName<Value>(_ key: PreferenceKey<Value>) -> String {
        namespace.isEmpty ? key.name : "\(namespace).\(key.name)"
    }

    private func removeWatcher(_ id: UUID) {
        watchers[id] = nil
    }

    // The backend's callback arrives on any thread; hopping onto the actor keeps the read of
    // the store serialised with our own writes.
    private func startObservingBackendIfNeeded() {
        guard !isObservingBackend else { return }

        isObservingBackend = true
        backend.observeExternalChanges { [weak self] in
            Task { await self?.refreshWatchers() }
        }
    }

    private func refreshWatchers() {
        for (id, watcher) in watchers {
            let current = backend.read(watcher.name)
            guard current != watcher.last else { continue }

            watchers[id]?.last = current
            watcher.publish(current)
        }
    }

    private static func outcome<Value>(
        of representation: PreferenceRepresentation?,
        for key: PreferenceKey<Value>
    ) -> Result<Value, PreferenceError> {
        guard let representation else { return .success(key.defaultValue) }

        do {
            return .success(try key.codec.decode(representation))
        } catch {
            return .failure(.decodingFailed(key: key.name, underlying: error))
        }
    }
}
