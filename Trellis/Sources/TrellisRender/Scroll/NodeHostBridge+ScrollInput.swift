import TrellisCore

extension NodeHostBridge {
    /// Reveals a directional target without assigning focus. Native adapters must request
    /// system focus and wait for confirmation; keyboard adapters may focus the returned ID.
    /// Hidden targets are considered only when scrolling can make them eligible (ADR 0028).
    /// Ownership: retains no nodes or work. Isolation: MainActor. Errors: nil if unavailable.
    /// Cancellation: synchronous; active user movement, suspend and detach reject the request.
    package func revealFocusTarget(_ direction: FocusDirection) -> NodeID? {
        guard !isSuspendedForBindings, let root, let geometry = hitTestSnapshot,
            !geometry.scrollOffsets.isEmpty,
            let snapshot = semanticSnapshot, let current = focusedID,
            let currentRecord = snapshot.record(for: current),
            let origin = currentRecord.visibleBounds
        else { return nil }
        var states: [NodeID: ScrollState] = [:]
        var axes: [NodeID: ScrollAxis] = [:]
        for id in renderer.scrollBackingIdentities() {
            guard let node = geometry.liveNode(for: id, under: root) as? ScrollNode,
                node.configuration.userInteractionEnabled, let state = currentScrollState(for: node)
            else { continue }
            states[id] = state
            axes[id] = node.configuration.axis
        }
        var candidates: [(id: NodeID, score: Double, plan: [(NodeID, LayoutPoint)])] = []
        for id in snapshot.order where id != current {
            guard let record = snapshot.record(for: id), record.focus.isFocusable,
                record.isEnabled, !record.isArrangementWrapper,
                snapshot.isDescendantOrSelf(id, of: focusScopeID ?? snapshot.root),
                let live = geometry.liveNode(for: id, under: root), live.isEnabledForSemantics,
                live.focus.isFocusable,
                let frame = record.visibleBounds ?? geometry.unclippedBounds(of: id),
                let plan = record.visibleBounds != nil
                    ? []
                    : geometry.revealOffsets(for: id, states: states, axes: axes)
            else { continue }
            guard
                plan.allSatisfy({ id, offset in
                    offset == states[id]?.offset
                        || snapshot.isDescendantOrSelf(id, of: focusScopeID ?? snapshot.root)
                })
            else { continue }
            let dx = frame.origin.x + frame.width / 2 - origin.origin.x - origin.width / 2
            let dy = frame.origin.y + frame.height / 2 - origin.origin.y - origin.height / 2
            let primary: Double
            let secondary: Double
            switch direction {
            case .down: (primary, secondary) = (dy, abs(dx))
            case .up: (primary, secondary) = (-dy, abs(dx))
            case .right: (primary, secondary) = (dx, abs(dy))
            case .left: (primary, secondary) = (-dx, abs(dy))
            case .next:
                (primary, secondary) = (
                    Double(record.traversalIndex - currentRecord.traversalIndex), 0
                )
            case .previous:
                (primary, secondary) = (
                    Double(currentRecord.traversalIndex - record.traversalIndex), 0
                )
            }
            let preferred = currentRecord.focus.preferredNext[direction] == id
            guard preferred || primary > 0 else { continue }
            candidates.append((id, preferred ? -1 : primary + 0.5 * secondary, plan))
        }
        // Stable traversal-order tie break; visible winners remain the native engine's job.
        guard
            let winner = candidates.enumerated().min(by: {
                $0.element.score == $1.element.score
                    ? $0.offset < $1.offset : $0.element.score < $1.element.score
            })?.element, snapshot.record(for: winner.id)?.visibleBounds == nil,
            !winner.plan.isEmpty
        else { return nil }
        var projectedOffsets = geometry.scrollOffsets
        for (id, offset) in winner.plan { projectedOffsets[id] = offset }
        if geometry.withScrollOffsets(projectedOffsets).visibleBounds(of: current) == nil {
            // Do not let offset-only publication assign fallback focus before native confirmation.
            _ = focus(nil, reason: .native)
        }
        for (id, offset) in winner.plan {
            guard hitTestSnapshot?.mountEpoch == geometry.mountEpoch,
                let mounted = self.root,
                let node = hitTestSnapshot?.liveNode(for: id, under: mounted) as? ScrollNode
            else { return nil }
            var completed = false
            scroll(.to(offset, animated: false), on: node) { outcome in
                if case .completed = outcome { completed = true }
            }
            guard completed else { return nil }
        }
        guard hitTestSnapshot?.mountEpoch == geometry.mountEpoch,
            semanticSnapshot?.record(for: winner.id)?.isFocusCandidate == true,
            let mounted = self.root,
            let live = hitTestSnapshot?.liveNode(for: winner.id, under: mounted),
            live.isEnabledForSemantics, live.focus.isFocusable,
            semanticSnapshot?.isDescendantOrSelf(winner.id, of: focusScopeID ?? geometry.root)
                == true
        else { return nil }
        return winner.id
    }

    /// Scrolls the nearest eligible ancestor of an AX endpoint by one viewport. No focus move.
    /// Ownership: values only. Isolation: MainActor. Errors: false at a boundary or stale scope.
    /// Cancellation: synchronous; user-driven motion, suspend and detach reject the action.
    package func scrollAccessibility(_ direction: FocusDirection, from identity: NodeID) -> Bool {
        scrollAccessibility(direction, from: identity, perform: true)
    }

    /// Available AX page directions for the current endpoint and scope.
    /// Ownership: values only. Isolation: MainActor. Errors: empty when unavailable.
    /// Cancellation: not applicable.
    package func accessibilityScrollDirections(from identity: NodeID) -> [FocusDirection] {
        [.up, .down, .left, .right].filter {
            scrollAccessibility($0, from: identity, perform: false)
        }
    }

    private func scrollAccessibility(
        _ direction: FocusDirection,
        from identity: NodeID,
        perform: Bool
    ) -> Bool {
        guard !isSuspendedForBindings, let root, let geometry = hitTestSnapshot,
            !geometry.scrollOffsets.isEmpty,
            let snapshot = semanticSnapshot, snapshot.record(for: identity)?.visibleBounds != nil,
            snapshot.isDescendantOrSelf(identity, of: focusScopeID ?? snapshot.root),
            let endpoint = geometry.liveNode(for: identity, under: root),
            endpoint.isEnabledForSemantics,
            let route = geometry.route(to: identity)
        else { return false }
        for id in route.reversed() {
            guard snapshot.isDescendantOrSelf(id, of: focusScopeID ?? snapshot.root),
                let scrollNode = geometry.liveNode(for: id, under: root) as? ScrollNode,
                scrollNode.configuration.userInteractionEnabled,
                let state = currentScrollState(for: scrollNode), !state.isUserDriven
            else { continue }
            let delta: LayoutPoint
            switch direction {
            case .up, .down:
                guard scrollNode.configuration.axis != .horizontal else { continue }
                delta = LayoutPoint(
                    x: 0,
                    y: direction == .up ? -state.viewportSize.height : state.viewportSize.height
                )
            case .left, .right:
                guard scrollNode.configuration.axis != .vertical else { continue }
                delta = LayoutPoint(
                    x: direction == .left ? -state.viewportSize.width : state.viewportSize.width,
                    y: 0
                )
            default: continue
            }
            let target = ScrollState.clamp(
                LayoutPoint(x: state.offset.x + delta.x, y: state.offset.y + delta.y),
                contentSize: state.contentSize,
                viewportSize: state.viewportSize
            )
            guard target != state.offset else { continue }
            guard perform else { return true }
            var handled = false
            scroll(.to(target, animated: false), on: scrollNode) { outcome in
                if case .completed = outcome { handled = true }
            }
            return handled
        }
        return false
    }
}
