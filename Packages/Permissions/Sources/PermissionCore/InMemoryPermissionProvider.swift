import Foundation

/// A stand-in for the system, for tests and previews: statuses are what it was told, and a request
/// ends the way it was told the person would answer.
///
/// It shows what a real provider is asked: every read and every request is counted, and a request can be
/// held, as the system's window is held while the person thinks.
public actor InMemoryPermissionProvider: PermissionProvider {
    private var statuses: [PermissionKind: PermissionStatus]
    private var answers: [PermissionKind: PermissionStatus] = [:]
    private var errors: [PermissionError] = []
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var active = 0

    /// Every kind asked for, in the order the requests began.
    public private(set) var requests: [PermissionKind] = []
    /// How many statuses were read.
    public private(set) var statusReads = 0
    /// The most requests that were open at once. A system shows one window at a time, so a test
    /// of ordering expects one.
    public private(set) var mostOpenRequests = 0

    /// - Parameter statuses: What the system says to begin with. A kind not named is
    ///   ``PermissionStatus/notDetermined``.
    public init(statuses: [PermissionKind: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    /// Sets what the system says, as the person does in Settings.
    public func setStatus(_ status: PermissionStatus, for kind: PermissionKind) {
        statuses[kind] = status
    }

    /// Sets how the person will answer when asked about `kind`. Without it the answer is
    /// ``PermissionStatus/Grant/full`` for kinds that grant it.
    public func willAnswer(_ status: PermissionStatus, for kind: PermissionKind) {
        answers[kind] = status
    }

    /// Makes the next request throw `error` instead of asking.
    public func failNextRequest(with error: PermissionError) {
        errors.append(error)
    }

    /// While held, a request that has begun waits, as the system's window waits for the person.
    public func holdRequests(_ hold: Bool) {
        isHolding = hold
        if !hold {
            for waiting in held { waiting.resume() }
            held.removeAll()
        }
    }

    public func status(of kind: PermissionKind) -> PermissionStatus {
        statusReads += 1
        return statuses[kind] ?? .notDetermined
    }

    public func request(_ kind: PermissionKind) async throws(PermissionError) -> PermissionStatus {
        requests.append(kind)
        active += 1
        mostOpenRequests = max(mostOpenRequests, active)
        defer { active -= 1 }

        if isHolding { await withCheckedContinuation { held.append($0) } }
        if !errors.isEmpty { throw errors.removeFirst() }

        let answer = answers[kind] ?? .granted(.full)
        statuses[kind] = answer
        return answer
    }
}
