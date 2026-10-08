import Foundation

/// Three-phase dispatch — capture down the ancestors, the target, bubble back up — over a
/// route of committed identities (H03, D20/D28). Ported in spirit from Weave's
/// `EventDispatcher` with one difference that matters: the route is `[NodeID]` from the
/// snapshot, not live `Node` references, and it is re-checked against the live tree before
/// every callback. A handler may dispose, detach or reparent anything; the first callback
/// whose node no longer sits where the route says ends user delivery, and the result says so
/// through `routeBroken` so the pointer session can be cancelled (D21). Nothing is delivered
/// to a node the screen no longer shows in that place.
///
/// Re-entrant: a handler may dispatch another event; each dispatch owns its own route.
///
/// Ownership: retains no node beyond the synchronous call. Isolation: MainActor. Errors: a
/// route that does not start at `root` or whose target is not mounted delivers nothing and
/// reports `routeBroken`. Cancellation: `stopPropagation()` ends later callbacks.
@MainActor
public struct EventDispatcher {
    /// Creates a dispatcher; it has no state of its own.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init() {}

    /// Delivers `event` along `route` — root first, target last, as `HitTestSnapshot.route(to:)`
    /// produces it — resolved against the live tree under `root`.
    ///
    /// Ownership: `event` and `root` are borrowed for the call. Isolation: MainActor. Errors:
    /// an empty route, a route not rooted at `root`, or a target missing from the live tree
    /// delivers nothing (`routeBroken == true`, `reachedTarget == false`). Cancellation: see
    /// `Event.stopPropagation()`; a broken route stops delivery the same way.
    @discardableResult
    public func dispatch(_ event: Event, route: [NodeID], root: Node) -> EventResult {
        guard let live = Self.resolve(route, under: root) else {
            Log.on(.event, "unresolved", node: event.targetID, "route=\(route.count)")
            return EventResult(
                propagationStopped: event.isPropagationStopped,
                defaultPrevented: event.isDefaultPrevented,
                routeBroken: true,
                reachedTarget: false
            )
        }

        var routeBroken = false
        var reachedTarget = false
        let last = live.count - 1

        // Capture: root … parent of target.
        for index in 0..<last where !event.isPropagationStopped {
            guard Self.isIntact(live, upTo: index, root: root) else {
                routeBroken = true
                break
            }
            event.setPhase(.capturing)
            live[index].handleCapture(event)
        }

        if !routeBroken, !event.isPropagationStopped {
            if Self.isIntact(live, upTo: last, root: root) {
                event.setPhase(.atTarget)
                live[last].handleEvent(event)
                reachedTarget = true
            } else {
                routeBroken = true
            }
        }

        // Bubble: parent of target … root. Bubbling happens on the target's behalf, so the
        // whole route down to the target must still hold — a target that moved elsewhere (8)
        // has no old ancestors to bubble through.
        if !routeBroken {
            for index in stride(from: last - 1, through: 0, by: -1)
            where !event.isPropagationStopped {
                guard Self.isIntact(live, upTo: last, root: root) else {
                    routeBroken = true
                    break
                }
                event.setPhase(.bubbling)
                live[index].handleBubble(event)
            }
        }

        if routeBroken {
            Log.on(.event, "route-broken", node: event.targetID, "phase=\(event.phase)")
        }

        return EventResult(
            propagationStopped: event.isPropagationStopped,
            defaultPrevented: event.isDefaultPrevented,
            routeBroken: routeBroken,
            reachedTarget: reachedTarget
        )
    }

    /// Walks `route` down from `root` through live `subnodes`; `nil` if any link is missing.
    /// Shared with the focus engine's live guard (A04, D36): the same "is this committed
    /// route still the live tree" question, asked before an action instead of a callback.
    static func resolve(_ route: [NodeID], under root: Node) -> [Node]? {
        guard let first = route.first, first == root.id, !root.isDisposed else { return nil }

        var live = [root]
        for identity in route.dropFirst() {
            guard let next = live[live.count - 1].subnodes.first(where: { $0.id == identity })
            else { return nil }

            live.append(next)
        }

        return live
    }

    /// Whether `live[0...index]` still is a chain of live parent → child links starting at
    /// `root` — the check that runs before every callback. Cheap: identity comparisons only.
    private static func isIntact(_ live: [Node], upTo index: Int, root: Node) -> Bool {
        guard live[0] === root, !root.isDisposed else { return false }

        for position in stride(from: index, to: 0, by: -1) {
            let node = live[position]
            guard !node.isDisposed, node.supernode === live[position - 1] else { return false }
        }

        return true
    }
}

extension HitTestSnapshot {
    /// The committed route from the root down to `identity`, or `nil` if the node was not part
    /// of this commit — the ancestry a dispatch runs over (D28).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func route(to identity: NodeID) -> [NodeID]? {
        guard var record = record(for: identity) else { return nil }

        var route = [identity]
        while let parent = record.parent, let parentRecord = self.record(for: parent) {
            route.append(parent)
            record = parentRecord
        }

        return route.reversed()
    }
}
