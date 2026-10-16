import AsyncRay
import Foundation
import GRDB
import NetworkCore
import StorageCore
import StorageGRDB

// Bridges from the observations of the storage and network layers to AsyncRay. Each of them is a
// cold stream: every subscription starts an observation of its own, and cancelling the
// subscription — or letting its `SubscriptionBag` go — ends that observation and releases what it
// held. Nothing is shared between subscriptions, so each has to be ended on its own.
//
// An error is never an empty value. A stream that can fail carries `Result`, so that a failed
// observation reaches the screen as a failure and not as an empty list; and a stream that ends
// normally has really ended.

/// Starts `source` on a task of its own and forwards what it gives; ending the consumer ends the
/// task, and with it whatever `source` held.
private func forward<Element: Sendable>(
    from source: @escaping @Sendable () async -> AsyncStream<Element>
) -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(
        of: Element.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    let task = Task {
        for await element in await source() { continuation.yield(element) }
        continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}

extension DatabaseStore {
    /// The query's snapshot now and after each commit that changed what it read, as a stream.
    ///
    /// A failing query arrives as `.failure` and ends the stream; see ``observe(_:)``. Only the
    /// latest snapshot is kept for a consumer that is slow, which is right for a screen.
    public nonisolated func observeRay<Value: Sendable>(
        _ query: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncRay<Result<Value, DatabaseStoreError>> {
        AsyncRay { [self] in
            forward { await self.observe(query) }
        }
    }
}

extension PreferenceStore {
    /// The key's value now and after each change, as a stream; a stored value that does not decode
    /// arrives as `.failure` and the stream goes on. See ``values(for:)``.
    public func valuesRay<Value: Sendable>(for key: PreferenceKey<Value>)
        -> AsyncRay<Result<Value, PreferenceError>>
    {
        AsyncRay {
            forward { await self.values(for: key) }
        }
    }
}

extension WebSocketClient {
    /// The client's state now and after each change, as a stream. Changes between two reads
    /// collapse into the latest, which is right for a status line.
    ///
    /// The events of the client are not offered as a stream: they must be taken one at a time, in
    /// order, by exactly one consumer, and none may be merged or dropped.
    public nonisolated var statesRay: AsyncRay<WebSocketState> {
        AsyncRay { [self] in
            forward { await self.states() }
        }
    }
}
