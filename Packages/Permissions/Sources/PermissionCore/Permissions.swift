import Foundation

/// The one place an app asks about permissions: reads statuses, asks in the right order, and
/// tells what changes.
///
/// **Asking.** ``request(_:)`` shows the system's window only for a kind that has not been asked about
/// (and for location "always" after "when in use": see ``PermissionKind/canBeAsked(whenStatusIs:)``).
/// For any other status it returns the status as it is, without asking again: the system would not
/// show a window, and the caller needs the answer, not a second attempt. Callers that ask for the same
/// kind while it is being asked share one request and all get its result. Requests for different
/// kinds go one at a time, in the order they came, because the system shows one window at a time.
///
/// **Cancelling.** Cancelling a caller's task makes that call throw ``PermissionError/cancelled`` and
/// leaves the request running: the system's window cannot be closed from here, the person will still
/// answer it, and the answer is kept — ``status(of:)`` shows it afterwards and observers are told.
///
/// **Observing.** ``statusChanges(of:)`` follows a kind. The system does not announce a change made in
/// Settings, so a status is read again when ``refresh()`` is called — the platform module calls it when the app
/// returns to the foreground — and after the app's own request. A status that changed and changed back
/// between two readings is not seen.
///
/// The app owns the instance and hands it to what needs it; there is no shared one.
public actor Permissions {
    private let provider: any PermissionProvider

    private struct Job {
        let id: UUID
        var waiters: [UUID: CheckedContinuation<PermissionStatus, any Error>] = [:]
    }

    private struct Observer {
        let kind: PermissionKind
        var last: PermissionStatus?
        let continuation: AsyncStream<PermissionStatus>.Continuation
    }

    private var jobs: [PermissionKind: Job] = [:]
    private var observers: [UUID: Observer] = [:]
    /// The one window the system shows at a time: whoever holds it asks, the rest wait their turn.
    private var isAsking = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    public init(provider: any PermissionProvider) {
        self.provider = provider
    }

    // MARK: Reading

    /// What the system says about `kind`, read without asking.
    public func status(of kind: PermissionKind) async -> PermissionStatus {
        let status = await provider.status(of: kind)
        publish(status, for: kind)
        return status
    }

    // MARK: Asking

    /// Asks for `kind` if it has not been asked about, and returns the status that results.
    ///
    /// - Returns: The status after the person answered, or the status as it already was.
    /// - Throws: ``PermissionError`` from the provider — a missing usage description, an app that is
    ///   not in front — and ``PermissionError/cancelled`` when the calling task is cancelled.
    ///   An error is not remembered: asking again asks again.
    public func request(_ kind: PermissionKind) async throws(PermissionError) -> PermissionStatus {
        if Task.isCancelled { throw .cancelled }

        if jobs[kind] == nil { start(kind) }
        let waiter = UUID()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    jobs[kind]?.waiters[waiter] = continuation
                    // A task cancelled before it got here has already run its handler.
                    if Task.isCancelled { drop(waiter, of: kind) }
                }
            } onCancel: {
                Task { await self.drop(waiter, of: kind) }
            }
        } catch let error as PermissionError {
            throw error
        } catch {
            throw .cancelled
        }
    }

    private func start(_ kind: PermissionKind) {
        let id = UUID()
        jobs[kind] = Job(id: id)
        Task {
            await self.takeTurn()
            let outcome = await self.ask(kind)
            self.endTurn()
            self.finish(kind, job: id, outcome: outcome)
        }
    }

    private func ask(_ kind: PermissionKind) async -> Result<PermissionStatus, PermissionError> {
        let current = await provider.status(of: kind)
        guard kind.canBeAsked(whenStatusIs: current) else { return .success(current) }

        do {
            return .success(try await provider.request(kind))
        } catch {
            return .failure(error)
        }
    }

    private func finish(
        _ kind: PermissionKind,
        job id: UUID,
        outcome: Result<PermissionStatus, PermissionError>
    ) {
        if case .success(let status) = outcome { publish(status, for: kind) }
        guard let job = jobs[kind], job.id == id else { return }

        jobs[kind] = nil
        for waiter in job.waiters.values { waiter.resume(with: outcome) }
    }

    /// Takes the cancelled caller out. The request goes on without it.
    private func drop(_ waiter: UUID, of kind: PermissionKind) {
        guard let continuation = jobs[kind]?.waiters.removeValue(forKey: waiter) else { return }

        continuation.resume(throwing: PermissionError.cancelled)
    }

    private func takeTurn() async {
        guard isAsking else {
            isAsking = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func endTurn() {
        if queue.isEmpty {
            isAsking = false
        } else {
            queue.removeFirst().resume()
        }
    }

    // MARK: Observing

    /// The status of `kind` now, then each different status found afterwards.
    ///
    /// The stream is registered when this returns. It holds only the latest value, as a setting does:
    /// a consumer that is slow sees the newest status, not every one. It ends when the consumer
    /// stops iterating or is cancelled; the registration is released then.
    public func statusChanges(of kind: PermissionKind) async -> AsyncStream<PermissionStatus> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PermissionStatus.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        observers[id] = Observer(kind: kind, last: nil, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        // The first reading goes through the same path as every later one, so that a change that
        // happens while it is being read is not reported twice or lost.
        publish(await provider.status(of: kind), for: kind)
        return stream
    }

    /// Reads every observed kind again and tells the observers of what changed. Call it when the
    /// app comes back to the foreground, where a change made in Settings becomes visible.
    public func refresh() async {
        for kind in Set(observers.values.map(\.kind)) {
            publish(await provider.status(of: kind), for: kind)
        }
    }

    /// Reads the observed kinds again each time `isForeground` says the app came to the front, for as
    /// long as the sequence goes on. This is how a change made in Settings reaches the screens:
    /// the person leaves the app, changes the permission, and comes back.
    ///
    /// Returns when the sequence ends, when it throws, or when the calling task is cancelled; run it
    /// in a task of its own and cancel that task when the app no longer follows. A `false` value, the
    /// app leaving the front, does nothing: nothing can change meanwhile that the app would see.
    ///
    /// - Parameter isForeground: Whether the app is in front, each time that changes. The platform
    ///   modules give one (`UIKitPermissions.foregroundChanges()`, `AppKitPermissions.foregroundChanges()`);
    ///   an app on the app shell can use `shell.activations().map { $0 == .active }`.
    public nonisolated func follow<Foreground: AsyncSequence & Sendable>(
        _ isForeground: Foreground
    ) async where Foreground.Element == Bool {
        do {
            for try await inFront in isForeground {
                if Task.isCancelled { return }

                if inFront { await refresh() }
            }
        } catch {
            return
        }
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }

    private func publish(_ status: PermissionStatus, for kind: PermissionKind) {
        for (id, observer) in observers where observer.kind == kind && observer.last != status {
            observers[id]?.last = status
            observer.continuation.yield(status)
        }
    }
}
