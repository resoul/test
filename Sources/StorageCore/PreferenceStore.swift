/// A place that keeps preferences by name and tells about their changes.
///
/// Conforming types provide the three raw operations; the typed API on ``PreferenceKey`` is
/// supplied here and works the same on every store. Use a store for small settings such as a
/// theme or a sort order. It is not a transactional database: writing several keys is not one
/// atomic step, and a write is visible to later reads of the same store but is not promised to
/// be on disk when the call returns.
///
/// A store is `Sendable`. It serializes its own state, so calls may come from any isolation.
/// Typed reads and writes suspend; a view-model should read a snapshot into a `State` once and
/// not touch the store from code that has to answer synchronously.
public protocol PreferenceStore: Sendable {
    /// The stored value of `name`, or nil while nothing is stored.
    func rawValue(forName name: String) async -> PreferenceValue?

    /// Stores `value` under `name`, or removes the name when `value` is nil.
    func setRawValue(_ value: PreferenceValue?, forName name: String) async

    /// A stream of what is stored under `name`: the current value first, then the value after
    /// changes. The stream may repeat a value; the typed API removes repeats.
    ///
    /// The stream is registered when this call returns, so a change made after that is not
    /// missed. Ending the iteration, or cancelling the task that iterates, stops the watching.
    func observeRawValue(forName name: String) async -> AsyncStream<PreferenceValue?>
}

extension PreferenceStore {
    /// Reads the value of `key`.
    ///
    /// - Returns: The stored value, or the key's default while nothing is stored.
    /// - Throws: ``PreferenceError/undecodable(key:reason:)`` when a value is stored that does not
    ///   fit the key. The default is not substituted.
    public func value<Value>(for key: PreferenceKey<Value>) async throws(PreferenceError) -> Value {
        try key.read(await rawValue(forName: key.name)).get()
    }

    /// Stores `value` under `key`.
    ///
    /// - Throws: ``PreferenceError/unencodable(key:reason:)``, before anything is written.
    public func set<Value>(_ value: Value, for key: PreferenceKey<Value>)
        async
        throws(PreferenceError)
    {
        await setRawValue(try key.write(value), forName: key.name)
    }

    /// Removes the stored value of `key`, so reading it gives the default again. Removing a key
    /// that holds a damaged value is how to recover from ``PreferenceError/undecodable(key:reason:)``.
    public func remove<Value>(_ key: PreferenceKey<Value>) async {
        await setRawValue(nil, forName: key.name)
    }

    /// Follows the value of `key`: the current value first, then each different value after a
    /// change. Writing the value that is already stored produces nothing, and neither does storing
    /// the key's default over an absent value.
    ///
    /// A stored value that does not fit the key arrives as a failure and the stream goes on, so
    /// a later repair is seen. A slow consumer gets only the latest value, which is right for a
    /// setting and wrong for a log of events.
    ///
    /// Ending the iteration or cancelling its task stops the watching. Changes made through other
    /// code to the same underlying storage are seen by rereading, not by an exact log, so a value
    /// that changed and returned between two readings produces nothing.
    public func values<Value>(for key: PreferenceKey<Value>) async
        -> AsyncStream<Result<Value, PreferenceError>>
    {
        let raw = await observeRawValue(forName: key.name)
        let (stream, continuation) = AsyncStream<Result<Value, PreferenceError>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // A stored value equal to the default reads the same as no stored value, so the two are
        // one state for an observer.
        let storedDefault = try? key.write(key.defaultValue)
        let task = Task {
            var last: PreferenceValue?
            var hasLast = false
            for await rawStored in raw {
                let stored = rawStored == storedDefault ? nil : rawStored
                if hasLast && stored == last { continue }

                last = stored
                hasLast = true
                continuation.yield(key.read(stored))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
