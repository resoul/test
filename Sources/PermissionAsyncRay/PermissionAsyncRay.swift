import AsyncRay
import PermissionCore

extension Permissions {
    /// The status of `kind` now and after each change found by a later reading, as a stream, so that
    /// a screen can bind it to its state: `permissions.statusRay(of: .camera).bind(to: model.camera)`.
    ///
    /// The stream is cold: each subscription starts an observation of its own, and ending the
    /// subscription — or letting its `SubscriptionBag` go — ends it. Only the latest status is
    /// kept for a slow consumer, which is right for a screen. Changes are found when
    /// ``refresh()`` or ``follow(_:)`` reads again and after the app's own ``request(_:)``; see
    /// ``statusChanges(of:)`` for what is not seen.
    public nonisolated func statusRay(of kind: PermissionKind) -> AsyncRay<PermissionStatus> {
        AsyncRay { [self] in
            let (stream, continuation) = AsyncStream.makeStream(
                of: PermissionStatus.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let task = Task {
                for await status in await self.statusChanges(of: kind) {
                    continuation.yield(status)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    }
}
