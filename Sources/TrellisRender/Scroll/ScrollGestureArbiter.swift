import TrellisCore

/// R09's pure ownership rule for one nested-scroll gesture. `delta` is expressed in content
/// coordinates: a positive component advances an offset towards its content end. Candidates
/// must be ordered nearest-to-farthest from the hit node. A dragging gesture may hand off only
/// before an owner is selected; momentum remains with its captured owner, so one delta is never
/// consumed by two native scroll views.
@MainActor
final class ScrollGestureArbiter {
    struct Candidate: Equatable {
        let id: NodeID
        let axis: ScrollAxis
        let state: ScrollState
        var isEligible = true

        func canConsume(_ axis: Axis, delta: Double) -> Bool {
            guard supports(axis), delta != 0 else { return false }
            let offset = axis == .horizontal ? state.offset.x : state.offset.y
            let maximum =
                axis == .horizontal
                ? max(0, state.contentSize.width - state.viewportSize.width)
                : max(0, state.contentSize.height - state.viewportSize.height)
            return delta > 0 ? offset < maximum : offset > 0
        }

        private func supports(_ requested: Axis) -> Bool {
            switch (axis, requested) {
            case (.both, _), (.horizontal, .horizontal), (.vertical, .vertical): true
            default: false
            }
        }
    }

    enum Axis: Equatable { case horizontal, vertical }

    struct Decision: Equatable {
        let owner: NodeID?
        let axis: Axis
        /// The part of the input offered to the captured scroll view. The perpendicular
        /// component is filtered by the direction lock.
        let offeredDelta: LayoutPoint
        /// The part that can be consumed without crossing the owner's boundary.
        let consumedDelta: LayoutPoint
        /// Perpendicular movement and movement beyond the owner's boundary. It is never
        /// redirected to a second scroll view during this gesture.
        let unconsumedDelta: LayoutPoint
    }

    private(set) var owner: NodeID?
    private(set) var lockedAxis: Axis?

    func begin() {
        owner = nil
        lockedAxis = nil
    }

    func end() { begin() }

    func owner(for delta: LayoutPoint, candidates: [Candidate], momentum: Bool) -> NodeID? {
        decision(for: delta, candidates: candidates, momentum: momentum).owner
    }

    func decision(
        for delta: LayoutPoint,
        candidates: [Candidate],
        momentum: Bool
    ) -> Decision {
        let axis = lockedAxis ?? (abs(delta.x) > abs(delta.y) ? .horizontal : .vertical)
        lockedAxis = axis
        let component = axis == .horizontal ? delta.x : delta.y
        let offered =
            axis == .horizontal
            ? LayoutPoint(x: component, y: 0)
            : LayoutPoint(x: 0, y: component)

        let selected: Candidate?
        if let owner {
            selected = candidates.first(where: { $0.id == owner })
        } else if momentum {
            // Momentum is the tail of the captured gesture. It cannot acquire a new owner.
            selected = nil
        } else {
            selected = candidates.first {
                $0.isEligible && $0.canConsume(axis, delta: component)
            }
        }

        guard let selected else {
            return Decision(
                owner: nil,
                axis: axis,
                offeredDelta: LayoutPoint(x: 0, y: 0),
                consumedDelta: LayoutPoint(x: 0, y: 0),
                unconsumedDelta: delta
            )
        }

        owner = selected.id
        let offset = axis == .horizontal ? selected.state.offset.x : selected.state.offset.y
        let maximum =
            axis == .horizontal
            ? max(0, selected.state.contentSize.width - selected.state.viewportSize.width)
            : max(0, selected.state.contentSize.height - selected.state.viewportSize.height)
        let available = component > 0 ? max(0, maximum - offset) : max(0, offset)
        let consumed =
            component > 0
            ? min(component, available)
            : max(component, -available)
        let consumedDelta =
            axis == .horizontal
            ? LayoutPoint(x: consumed, y: 0)
            : LayoutPoint(x: 0, y: consumed)
        return Decision(
            owner: selected.id,
            axis: axis,
            offeredDelta: offered,
            consumedDelta: consumedDelta,
            unconsumedDelta: LayoutPoint(
                x: delta.x - consumedDelta.x,
                y: delta.y - consumedDelta.y
            )
        )
    }
}
