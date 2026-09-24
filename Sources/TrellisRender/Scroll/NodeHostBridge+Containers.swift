import Foundation
import TrellisCore

/// Weak reference to a hosted container.
struct WeakHostedContainer {
    weak var container: (any HostedContainer)?
}

/// An offset shift requested by a container, applied in the next geometry commit.
struct PendingOffsetAdjustment {
    let delta: LayoutPoint
    let applied: @MainActor () -> Void
}

extension StateBinding: ContainerBinding {}

// R12a (ADR 0032): the bridge serves `HostedContainer` nodes found in its committed tree —
// lifecycle, state binding through the mounted session (D14), the shared preparation budget,
// and offset shifts applied inside the geometry commit they belong to.
extension NodeHostBridge: ContainerHost {
    /// The host's shared collection preparation budget.
    ///
    /// Ownership: owned by the bridge. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var materializationBudget: MaterializationBudget {
        if let containerBudget { return containerBudget }

        let budget = MaterializationBudget(host: hostID)
        containerBudget = budget
        return budget
    }

    /// Binds `subject` for a container through `bindState` (D14).
    ///
    /// Ownership: the bridge owns the delivery until the returned handle is cancelled.
    /// Isolation: MainActor. Errors: none. Cancellation: the handle's `cancel()`.
    public func bindContainerState<Value: Sendable & Equatable>(
        _ subject: StateSubject<Value>,
        update: @escaping @MainActor (Value) -> Void
    ) -> any ContainerBinding {
        bindState(subject, update: update)
    }

    /// Queues `delta` for `node`; applied in the next geometry commit relative to the native
    /// offset at that moment, even while the user drags or the view decelerates.
    ///
    /// Ownership: retains `applied` until it runs once. Isolation: MainActor. Errors: none.
    /// Cancellation: `detach()` runs every pending `applied`.
    public func adjustScrollOffset(
        of node: ScrollNode,
        by delta: LayoutPoint,
        applied: @escaping @MainActor () -> Void
    ) {
        guard root != nil else {
            applied()
            return
        }

        pendingOffsetAdjustments[node.id, default: []].append(
            PendingOffsetAdjustment(delta: delta, applied: applied)
        )
        Log.on(.event, "scroll-adjust-queued", host: hostID, node: node.id, "dy=\(delta.y)")
    }

    /// Issues `command` for a container's scroll node through `scroll(_:on:completion:)`.
    ///
    /// Ownership: retains `completion` until it runs once. Isolation: MainActor. Errors: none.
    /// Cancellation: as `scroll(_:on:completion:)`.
    public func scrollContainer(
        _ node: ScrollNode,
        _ command: ScrollCommand,
        completion: @escaping @MainActor (ScrollCommandOutcome) -> Void
    ) {
        scroll(command, on: node, completion: completion)
    }

    /// The presented native offset of `node`'s scroll view.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func presentedScrollOffset(of node: ScrollNode) -> LayoutPoint? {
        renderer.scrollBacking(for: node.id)?.presentedContentOffset
    }

    /// Pushes `node.configuration` to its native backing without waiting for a commit (ADR
    /// 0037 §3); the next commit applies the same value again.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func applyScrollConfiguration(of node: ScrollNode) {
        guard let backing = renderer.scrollBacking(for: node.id) else { return }

        backing.apply(configuration: node.configuration)
        Log.on(
            .event,
            "scroll-configuration-applied",
            host: hostID,
            node: node.id,
            "interaction=\(node.configuration.userInteractionEnabled)"
        )
    }

    /// Applies queued shifts to native backings. Called right after the renderer committed
    /// geometry and content sizes, before hit-test and scroll-state publication read offsets.
    func applyPendingOffsetAdjustments(root: Node) {
        guard !pendingOffsetAdjustments.isEmpty else { return }

        let pending = pendingOffsetAdjustments
        pendingOffsetAdjustments.removeAll()
        for (nodeID, adjustments) in pending {
            let delta = adjustments.reduce(LayoutPoint(x: 0, y: 0)) {
                LayoutPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y)
            }
            // Containers drop their pending delta first: the native offset change below may
            // publish a scroll state synchronously, which must not count the delta twice.
            for adjustment in adjustments {
                adjustment.applied()
            }
            guard let backing = renderer.scrollBacking(for: nodeID) else {
                Log.on(
                    .event,
                    "scroll-adjust-dropped",
                    host: hostID,
                    node: nodeID,
                    "reason=no-backing"
                )
                continue
            }

            let current = backing.contentOffset
            let contentSize = renderer.scrollContentSize(for: nodeID) ?? backing.viewportSize
            let target = ScrollState.clamp(
                LayoutPoint(x: current.x + delta.x, y: current.y + delta.y),
                contentSize: contentSize,
                viewportSize: backing.viewportSize
            )
            if target != current {
                backing.contentOffset = target
            }
            Log.on(
                .event,
                "scroll-adjust-applied",
                host: hostID,
                node: nodeID,
                "dy=\(delta.y) from=\(current.y) to=\(target.y) phase=\(scrollPhases[nodeID] ?? .idle)"
            )
        }
    }

    /// Notifies containers of attach/commit/detach against the committed tree, then starts a
    /// budget pass.
    func serveHostedContainers(root: Node, generation: UInt64) {
        var present: [ObjectIdentifier: any HostedContainer] = [:]
        func visit(_ node: Node) {
            if let container = node as? any HostedContainer {
                present[ObjectIdentifier(container)] = container
            }
            for child in node.subnodes { visit(child) }
        }
        visit(root)

        for (key, entry) in hostedContainers where present[key] == nil {
            hostedContainers.removeValue(forKey: key)
            entry.container?.hostDidDetach()
        }
        let commit = ContainerCommit(generation: generation)
        for (key, container) in present {
            if hostedContainers[key] == nil {
                hostedContainers[key] = WeakHostedContainer(container: container)
                Log.on(.host, "container-attach", host: hostID, generation: generation)
                container.hostDidAttach(self)
            }
            container.hostDidCommit(commit)
        }
        containerBudget?.beginPass()
    }

    /// Detaches every served container and resolves queued shifts; called on host detach.
    func detachHostedContainers() {
        let containers = hostedContainers.values.compactMap(\.container)
        hostedContainers.removeAll()
        for container in containers {
            container.hostDidDetach()
        }
        let pending = pendingOffsetAdjustments
        pendingOffsetAdjustments.removeAll()
        for adjustment in pending.values.joined() {
            adjustment.applied()
        }
    }
}
