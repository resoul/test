import Foundation

/// Why a pointer session ended without a `pointerUp` (H04, D21/D31). Diagnostic and the input
/// to recognizer/control reset; user activation never follows any of these.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: every case is one.
public enum PointerCancelReason: Sendable, Hashable {
    /// The host reported the pointer as cancelled (`touchesCancelled`, window lost the mouse).
    case pointerCancelled
    /// A node on the session's route was disposed, detached or reparented (D21/D28).
    case routeBroken
    /// The host detached its root or replaced it.
    case hostDetached
    /// The host was suspended.
    case hostSuspended
    /// The committed snapshot belongs to a different mount than the session started on.
    case mountChanged
    /// A second `pointerDown` arrived for a pointer that already has a session.
    case pointerRestarted
}

/// What `PointerSessions.send` did with one event.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PointerOutcome: Sendable, Hashable {
    /// The event went through three-phase dispatch along the session's route. A result with
    /// `routeBroken` means the session was cancelled right after (D21).
    case delivered(EventResult)
    /// `pointerDown` with no committed snapshot or nothing under the point.
    case noTarget
    /// `pointerMove`/`pointerUp`/`pointerCancel` for a pointer with no active session — after a
    /// cancellation, or a host that never sent the down.
    case noSession
    /// Single-touch (D30): another pointer owns the only session; this one is refused
    /// deterministically and starts nothing.
    case secondaryPointer
    /// The host is not taking input: nothing attached, suspended, or hit-testing unavailable.
    case hostInactive
}

/// The pointer sessions of one host: which pointer is down, on which route, on which mount
/// (H04, D21/D27/D30/D34). Owned by the host bridge, which feeds it normalized `PointerData`
/// and tells it about `detach`/`suspend`.
///
/// Contract: a session starts at `pointerDown` on the hit under the point and keeps that
/// route — the committed root → target chain — for every later `move`/`up`/`cancel` of the
/// same `pointerID` (implicit capture, D27); where the pointer is now does not change who
/// receives the events. The session survives commits (resize, unrelated mutation) as long as
/// the snapshot is from the same mount (D34). It ends exactly once: at `up`, at `cancel`, or
/// by cancellation — a broken route, a changed mount, `cancelAll`. Cancellation forgets the
/// session, then delivers one `pointerCancel` along the route through the ordinary dispatch —
/// which delivers nothing when the route no longer resolves (the target is gone); the
/// recognizers a session holds are reset directly in that case (H05), not through the tree.
///
/// One session at a time in this stage: a second pointer's `down` is refused (D30).
///
/// Ownership: retains identities and epochs, never a `Node`. Isolation: MainActor. Errors:
/// events that fit no session are reported in the outcome, not thrown. Cancellation: see
/// `cancelAll(reason:root:)`.
@MainActor
public final class PointerSessions {
    private struct Session {
        let pointerID: UInt64
        let route: [NodeID]
        let mountEpoch: UInt64
        let rootID: NodeID
        /// Last point delivered — what a cancel reports as its position.
        var lastPoint: LayoutPoint
        /// The route's recognizers, target first (D29); fed after bubble unless the default
        /// was prevented, reset directly when the session is cancelled (D21).
        let arena: GestureArena
        var target: NodeID { route[route.count - 1] }
    }

    private var sessions: [UInt64: Session] = [:]
    private let dispatcher = EventDispatcher()

    /// Creates an empty store.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init() {}

    /// Number of live sessions — 0 or 1 in this stage; 0 after every `up`, `cancel` and
    /// `cancelAll` (H10 checks it after teardown).
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var activeCount: Int { sessions.count }

    /// The number of live per-session arenas. There is deliberately no separate arena
    /// registry: this test hook makes that ownership invariant observable to H10.
    package var activeArenaCount: Int { sessions.values.filter { !$0.arena.isClosed }.count }

    /// The committed route of the session owned by `pointerID`, root first, or `nil`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func route(for pointerID: UInt64) -> [NodeID]? { sessions[pointerID]?.route }

    /// Routes one normalized pointer event. `snapshot` is the host's last commit (`nil` before
    /// the first one or after detach); `root` is the live mounted root the route is checked
    /// against.
    ///
    /// Ownership: `snapshot` is read, `root` borrowed for the synchronous call. Isolation:
    /// MainActor. Errors: reported as `PointerOutcome`. Cancellation: an `up` or `cancel`
    /// releases the session exactly once; a `routeBroken` delivery or a mount mismatch
    /// cancels it.
    @discardableResult
    public func send(
        _ type: EventType,
        _ data: PointerData,
        snapshot: HitTestSnapshot?,
        root: Node
    ) -> PointerOutcome {
        switch type {
        case .pointerDown:
            return begin(data, snapshot: snapshot, root: root)
        case .pointerMove, .pointerUp, .pointerCancel:
            return continueSession(type, data, snapshot: snapshot, root: root)
        case .focusIn, .focusOut, .keyDown, .keyUp:
            // Not a pointer event: the focus engine and the key path own those (A04/A07).
            Log.on(.event, "not-pointer", node: root.id, "type=\(type)")
            return .noSession
        }
    }

    /// Cancels every session: one `pointerCancel` each along whatever of its route still
    /// stands under `root`, then the store is empty. Called by the bridge on `detach`,
    /// `suspend` and root replacement — before the tree goes away, so handlers still see it.
    ///
    /// Ownership: `root` is borrowed. Isolation: MainActor. Errors: none. Cancellation: this
    /// is it; idempotent.
    public func cancelAll(reason: PointerCancelReason, root: Node?) {
        for session in sessions.values.sorted(by: { $0.pointerID < $1.pointerID }) {
            cancel(session, reason: reason, root: root)
        }
    }

    private func begin(_ data: PointerData, snapshot: HitTestSnapshot?, root: Node)
        -> PointerOutcome
    {
        if let existing = sessions[data.pointerID] {
            // A down without the previous up: the host lost track. Close the old session
            // deterministically, then start over — never two routes for one pointer.
            cancel(existing, reason: .pointerRestarted, root: root)
        }
        guard sessions.isEmpty else {
            Log.on(.event, "secondary-pointer", node: root.id, "pointer=\(data.pointerID)")
            return .secondaryPointer
        }
        guard let snapshot, snapshot.root == root.id, let target = snapshot.hitTest(data.point),
            let route = snapshot.route(to: target)
        else {
            Log.on(.event, "no-target", node: root.id, "pointer=\(data.pointerID)")
            return .noTarget
        }

        let session = Session(
            pointerID: data.pointerID,
            route: route,
            mountEpoch: snapshot.mountEpoch,
            rootID: root.id,
            lastPoint: data.point,
            arena: GestureArena(recognizers: Self.recognizers(along: route, under: root))
        )
        sessions[data.pointerID] = session
        Log.on(
            .event,
            "session-begin",
            node: target,
            "pointer=\(data.pointerID) depth=\(route.count)"
        )

        return deliver(
            .pointerDown,
            data,
            session: session,
            snapshot: snapshot,
            root: root,
            releases: false
        )
    }

    private func continueSession(
        _ type: EventType,
        _ data: PointerData,
        snapshot: HitTestSnapshot?,
        root: Node
    ) -> PointerOutcome {
        guard let session = sessions[data.pointerID] else { return .noSession }

        // Same mount only (D21/D34): a new attach — even of the same root — starts a new
        // epoch, and a session from the old one must not reach the new tree.
        guard let snapshot, snapshot.mountEpoch == session.mountEpoch, session.rootID == root.id
        else {
            cancel(session, reason: .mountChanged, root: root)
            return .noSession
        }

        return deliver(
            type,
            data,
            session: session,
            snapshot: snapshot,
            root: root,
            releases: type != .pointerMove
        )
    }

    private func deliver(
        _ type: EventType,
        _ data: PointerData,
        session: Session,
        snapshot: HitTestSnapshot,
        root: Node,
        releases: Bool
    ) -> PointerOutcome {
        sessions[session.pointerID]?.lastPoint = data.point
        let event = Event(
            type: type,
            targetID: session.target,
            payload: .pointer(data),
            snapshot: snapshot
        )
        let result = dispatcher.dispatch(event, route: session.route, root: root)

        if result.routeBroken {
            // Whoever is still on the intact part of the route learns the session is over.
            cancel(session, reason: .routeBroken, root: root)
        } else if result.defaultPrevented {
            // D29 (2): the default action — recognition and what it activates — is off for
            // this event. The recognizers simply never see it.
            Log.on(.event, "default-prevented", node: session.target, "type=\(type)")
        } else {
            // D29 (1)–(2): the arena runs after bubble.
            session.arena.handle(event)
        }
        if releases, !result.routeBroken {
            // The session is over whether or not the arena saw the up (it did not when the
            // default was prevented): recognizers must be clean for the next session.
            session.arena.cancel()
            sessions[session.pointerID] = nil
            Log.on(
                .event,
                "session-end",
                node: session.target,
                "pointer=\(session.pointerID) type=\(type)"
            )
        }

        return .delivered(result)
    }

    /// The route's recognizers in arbitration order (D29 (3)): target's first, then each
    /// ancestor's up to the root, each node's in registration order. Read from the live tree
    /// at `pointerDown` — the route has just been resolved by the down dispatch, so every node
    /// is there.
    private static func recognizers(along route: [NodeID], under root: Node)
        -> [any GestureRecognizer]
    {
        var live: [Node] = [root]
        for identity in route.dropFirst() {
            guard let next = live[live.count - 1].subnodes.first(where: { $0.id == identity })
            else { break }

            live.append(next)
        }

        return live.reversed().flatMap(\.gestureRecognizers)
    }

    /// Forgets the session first, then delivers the cancel — a handler reacting to the cancel
    /// by starting a new gesture must not find the old session still registered. The cancel
    /// goes through the same dispatch as any event: a route that no longer resolves (the
    /// target is gone) delivers nothing through the tree — recognizers held by the session are
    /// reset directly instead (H05).
    private func cancel(_ session: Session, reason: PointerCancelReason, root: Node?) {
        guard let current = sessions.removeValue(forKey: session.pointerID) else { return }

        Log.on(
            .event,
            "session-cancel",
            node: current.target,
            "pointer=\(current.pointerID) reason=\(reason)"
        )
        // Directly, not through the tree (D21): the route may no longer resolve, and the
        // recognizers must still learn the session is over — an active pan gets its one
        // `.cancelled`, a waiting tap goes quiet, nothing activates.
        current.arena.cancel()
        guard let root else { return }

        let event = Event(
            type: .pointerCancel,
            targetID: current.target,
            payload: .pointer(PointerData(point: current.lastPoint, pointerID: current.pointerID))
        )
        dispatcher.dispatch(event, route: current.route, root: root)
    }
}
