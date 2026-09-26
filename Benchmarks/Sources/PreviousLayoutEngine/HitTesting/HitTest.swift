import Foundation

extension HitTestSnapshot {
    /// The front-most committed node under `point`, or `nil` when nothing is there (H02b, D17).
    ///
    /// `point` is a host point: the coordinate space of `bounds` and of every record's `frame`,
    /// origin top-left, in points. The walk goes from the root towards the front-most
    /// descendant, carrying the point through each node's transform (pivot — frame center,
    /// ADR 0010), so a transformed ancestor moves its whole subtree:
    ///
    /// - `opacity == 0` hides the node and its subtree; any other opacity does not (T04);
    /// - `overflow == .hidden`/`.scroll` clips its subtree to the node's own local bounds;
    ///   a `.visible` node's children are tested even outside its bounds (T03);
    /// - siblings are tested by `zIndex` descending, equal `zIndex` last-painted first
    ///   (`children` reversed — D32); `zIndex` orders siblings only, never across parents;
    /// - an `Arrangement` wrapper is never the result, its children are (D19);
    /// - bounds are half-open — `min` inside, `max` outside — so a shared edge belongs to one
    ///   sibling only, and a zero-sized frame is never hit (D33);
    /// - the root is the fallback hit when no child is, as long as the point is inside it.
    ///
    /// A subtree is skipped when the point is outside its `hittableBounds` — a box computed at
    /// capture from the transformed frames of the whole subtree, never from the parent's own
    /// untransformed frame (T03). Measured on a 1111-node tree in
    /// `docs/validation/h02b-hit-test.md`.
    ///
    /// Ownership: returns a value; reads only the snapshot. Isolation: none. Errors: none —
    /// `LayoutPoint` is finite by construction. Cancellation: not applicable.
    public func hitTest(_ point: LayoutPoint) -> NodeID? {
        guard let rootRecord = record(for: root) else { return nil }

        return hit(rootRecord, at: point)
    }

    /// `point` is in the parent's local space — the space `record.frame` is expressed in.
    private func hit(_ record: Record, at point: LayoutPoint) -> NodeID? {
        // Inclusive on purpose: the box only prunes, the half-open test below decides.
        guard record.visual.opacity > 0, Self.encloses(record.hittableBounds, point) else {
            return nil
        }

        let transform = record.visual.transform
        let local =
            transform == .identity ? point : transform.inverseApplying(point, in: record.frame)
        let insideSelf = Self.contains(record.frame, local)

        switch record.visual.overflow {
        case .hidden, .scroll:
            guard insideSelf else { return nil }
        case .visible:
            break
        }

        // D18/R07: a `.scroll` node's children sit in content space (unchanged by scrolling,
        // `r06-scroll-api-sketch.md` §1), while `local` is a viewport-space point relative to
        // this node's own frame origin — `contentPoint = viewportPoint + offset` is the one
        // conversion §1 asks every subsystem to share. A node with no published offset yet
        // (`scrollOffsets[record.id] == nil`, e.g. before its first native commit) behaves as
        // offset zero, i.e. unchanged from before R07.
        let childPoint: LayoutPoint
        if record.visual.overflow == .scroll, let offset = scrollOffsets[record.id] {
            childPoint = LayoutPoint(x: local.x + offset.x, y: local.y + offset.y)
        } else {
            childPoint = local
        }

        for childID in frontToBack(record.children) {
            guard let child = self.record(for: childID) else { continue }

            if let hit = hit(child, at: childPoint) { return hit }
        }

        return insideSelf && !record.isArrangementWrapper ? record.id : nil
    }

    /// Children in hit order: `zIndex` descending, then the later sibling first. The common
    /// case — every sibling at `zIndex` 0 — is a plain reversal without a sort.
    private func frontToBack(_ children: [NodeID]) -> [NodeID] {
        guard children.count > 1,
            children.contains(where: { (record(for: $0)?.visual.zIndex ?? 0) != 0 })
        else { return children.reversed() }

        return
            children
            .enumerated()
            .map { (id: $1, zIndex: record(for: $1)?.visual.zIndex ?? 0, index: $0) }
            .sorted { lhs, rhs in
                lhs.zIndex != rhs.zIndex ? lhs.zIndex > rhs.zIndex : lhs.index > rhs.index
            }
            .map(\.id)
    }

    /// Half-open containment (D33): `origin` inside, `origin + size` outside.
    private static func contains(_ frame: LayoutFrame, _ point: LayoutPoint) -> Bool {
        point.x >= frame.origin.x && point.x < frame.origin.x + frame.width
            && point.y >= frame.origin.y && point.y < frame.origin.y + frame.height
    }

    /// Closed containment for pruning: a point on the far edge of a box may still be inside a
    /// transformed frame the box was rounded from.
    private static func encloses(_ box: LayoutFrame, _ point: LayoutPoint) -> Bool {
        point.x >= box.origin.x && point.x <= box.origin.x + box.width
            && point.y >= box.origin.y && point.y <= box.origin.y + box.height
    }

    /// Whether `point` — in host coordinates — falls inside `identity`'s own committed bounds,
    /// carried through every ancestor's transform and clip from the root down (H06, D22/D34).
    /// Independent of `hitTest(_:)`: a decorative descendant may be the topmost hit at the same
    /// point while `identity` — an ancestor of it, e.g. a `ControlNode` behind a decorative
    /// child — still asks about its own geometry, not about who paints frontmost. Always
    /// against this snapshot, the one it is called on: a caller that wants "the latest commit"
    /// for a pointer session passes the snapshot it read at the moment of the event, not the
    /// one from `pointerDown` (D34) — `Event.snapshot` already carries that one.
    ///
    /// `false` when `identity` was not part of this commit, or any ancestor from the root down
    /// to it (`identity` included) has `opacity == 0`, or a clipping ancestor's own bounds
    /// exclude the point before the walk reaches `identity`.
    ///
    /// Ownership: returns a value; reads only the snapshot. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func contains(_ point: LayoutPoint, node identity: NodeID) -> Bool {
        guard let route = route(to: identity) else { return false }

        var local = point
        for step in route {
            guard let record = record(for: step), record.visual.opacity > 0 else { return false }

            let transform = record.visual.transform
            local =
                transform == .identity ? local : transform.inverseApplying(local, in: record.frame)
            let insideSelf = Self.contains(record.frame, local)
            if step == identity { return insideSelf }

            switch record.visual.overflow {
            case .hidden, .scroll:
                guard insideSelf else { return false }
            case .visible:
                break
            }

            // D18/R07: same content-space conversion as `hit(_:at:)` above, for the rest of the
            // route past a `.scroll` ancestor.
            if record.visual.overflow == .scroll, let offset = scrollOffsets[step] {
                local = LayoutPoint(x: local.x + offset.x, y: local.y + offset.y)
            }
        }

        return false
    }
}

extension HitTestSnapshot {
    /// The axis-aligned box, in host space, of the part of `identity` that is actually on
    /// screen (A03, D46): the node's own frame carried through its transform and every
    /// ancestor's (pivot — frame center, ADR 0010), cut by each clipping ancestor
    /// (`overflow != .visible`) in that ancestor's local space, and finally by the host
    /// bounds. `nil` when nothing is visible: the node was not committed, has a zero-sized
    /// frame, it or an ancestor has `opacity == 0`, or a clip leaves an empty area. A box
    /// around a rotated polygon is conservative — partial occlusion by siblings is not
    /// modelled (D46).
    ///
    /// Ownership: returns a value; reads only the snapshot. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func visibleBounds(of identity: NodeID) -> LayoutFrame? {
        guard let route = route(to: identity), let own = record(for: identity),
            own.frame.width > 0, own.frame.height > 0, own.visual.opacity > 0
        else { return nil }

        var box = Self.boundingBox(
            of: own.frame,
            transformedBy: own.visual.transform,
            in: own.frame
        )
        for step in route.dropLast().reversed() {
            guard let ancestor = record(for: step), ancestor.visual.opacity > 0 else { return nil }

            // Children of a scroll container retain their committed content-space frames. For
            // a visible/focus/AX box, carry that child box back into the viewport before the
            // container clips it — the inverse of hit-testing's `viewport + offset` conversion.
            // This executes once per scroll ancestor, so nested scroll views compose without a
            // separate coordinate system or a tree re-walk on native offset ticks.
            if ancestor.visual.overflow == .scroll, let offset = scrollOffsets[step] {
                box = Self.translated(box, x: -offset.x, y: -offset.y)
            }
            if ancestor.visual.overflow != .visible {
                guard let clipped = Self.intersection(box, ancestor.frame) else { return nil }

                box = clipped
            }
            box = Self.boundingBox(
                of: box,
                transformedBy: ancestor.visual.transform,
                in: ancestor.frame
            )
        }

        return Self.intersection(box, bounds)
    }

    /// Plans nearest-edge reveal from inner to outer scroll containers, without mutating UI.
    /// Ordinary clips and opacity still exclude a target; only scroll offsets may change.
    /// Ownership: values only. Isolation: none. Errors: nil for an unrevealable target.
    /// Cancellation: not applicable.
    package func revealOffsets(
        for identity: NodeID,
        states: [NodeID: ScrollState],
        axes: [NodeID: ScrollAxis]
    ) -> [(NodeID, LayoutPoint)]? {
        guard let route = route(to: identity), let own = record(for: identity),
            own.frame.width > 0, own.frame.height > 0, own.visual.opacity > 0
        else { return nil }
        var box = Self.boundingBox(
            of: own.frame,
            transformedBy: own.visual.transform,
            in: own.frame
        )
        var result: [(NodeID, LayoutPoint)] = []
        for step in route.dropLast().reversed() {
            guard let ancestor = record(for: step), ancestor.visual.opacity > 0 else { return nil }

            if ancestor.visual.overflow == .scroll {
                guard let state = states[step], !state.isUserDriven else { return nil }
                let local = Self.translated(
                    box,
                    x: -ancestor.frame.origin.x,
                    y: -ancestor.frame.origin.y
                )
                let proposed = state.revealOffset(for: local, alignment: .nearest)
                let offset = LayoutPoint(
                    x: axes[step] == .vertical ? state.offset.x : proposed.x,
                    y: axes[step] == .horizontal ? state.offset.y : proposed.y
                )
                result.append((step, offset))
                box = Self.translated(box, x: -offset.x, y: -offset.y)
            }
            if ancestor.visual.overflow != .visible {
                guard let clipped = Self.intersection(box, ancestor.frame) else { return nil }
                box = clipped
            }
            box = Self.boundingBox(
                of: box,
                transformedBy: ancestor.visual.transform,
                in: ancestor.frame
            )
        }
        guard Self.intersection(box, bounds) != nil else { return nil }
        return result
    }

    /// Host-space geometry before clipping, used only to rank reveal targets, never eligibility.
    /// Ownership: values only. Isolation: none. Errors: nil for missing geometry.
    /// Cancellation: not applicable.
    package func unclippedBounds(of identity: NodeID) -> LayoutFrame? {
        guard let route = route(to: identity), let own = record(for: identity) else { return nil }
        var box = Self.boundingBox(
            of: own.frame,
            transformedBy: own.visual.transform,
            in: own.frame
        )
        for step in route.dropLast().reversed() {
            guard let ancestor = record(for: step) else { return nil }

            if ancestor.visual.overflow == .scroll, let offset = scrollOffsets[step] {
                box = Self.translated(box, x: -offset.x, y: -offset.y)
            }
            box = Self.boundingBox(
                of: box,
                transformedBy: ancestor.visual.transform,
                in: ancestor.frame
            )
        }
        return box
    }

    /// The overlap of two boxes, or `nil` when they share no positive area.
    static func intersection(_ lhs: LayoutFrame, _ rhs: LayoutFrame) -> LayoutFrame? {
        let minX = max(lhs.origin.x, rhs.origin.x)
        let minY = max(lhs.origin.y, rhs.origin.y)
        let maxX = min(lhs.origin.x + lhs.width, rhs.origin.x + rhs.width)
        let maxY = min(lhs.origin.y + lhs.height, rhs.origin.y + rhs.height)
        guard maxX > minX, maxY > minY else { return nil }

        return LayoutFrame(
            origin: LayoutPoint(x: minX, y: minY),
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func translated(_ frame: LayoutFrame, x: Double, y: Double) -> LayoutFrame {
        LayoutFrame(
            origin: LayoutPoint(x: frame.origin.x + x, y: frame.origin.y + y),
            width: frame.width,
            height: frame.height
        )
    }
}
