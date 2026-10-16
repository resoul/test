import Foundation

/// One node as assistive technology sees it (A06, D42): a leaf element (`isElement`) or a
/// group container of elements, with the resolved role, state, actions and the host-space
/// frame of its visible area. Values, never nodes.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityElement: Sendable, Hashable {
    /// The committed node this element stands for.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: NodeID

    /// Host-space box of the visible area (D46); for a group whose own node has none, the
    /// union of its children's frames.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let frame: LayoutFrame

    /// `true` for a leaf assistive technology lands on; `false` for a group that only holds
    /// `children` (with an optional label of its own, A01 §3.2).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isElement: Bool

    /// Spoken name — the node's own, or for `.combine` the joined descendant labels.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let label: String?

    /// Spoken value.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let value: String?

    /// Spoken hint.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let hint: String?

    /// Automation identifier.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let identifier: String?

    /// The resolved role: the authored one, else `.button` for a control, else `nil` (a plain
    /// leaf reads as text, a group as a group — A01 §3.1).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let role: AccessibilityRole?

    /// Enabled state (D41) — a disabled control is still read, never activated.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isEnabled: Bool

    /// Selected state.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isSelected: Bool

    /// Standard actions: the authored ones plus `.activate` for a control (D43). Listed
    /// regardless of `isEnabled`; performing one on a disabled node returns `false`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let actions: [AccessibilityAction]

    /// Custom actions, in order.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let customActions: [AccessibilityCustomAction]

    /// Child elements in reading order — empty for a leaf.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let children: [AccessibilityElement]
}

/// The semantic tree of one committed snapshot (A06, D42): independent of focus and
/// hit-testing, built from `SemanticSnapshot` by the four children policies, with a stable
/// reading order — `sortPriority` descending among siblings, ties in committed order — and
/// confined to the modal scope when one is set (D40). Ported in spirit from Weave's
/// `AccessibilityTree`; the policies are defined on visible children this time (defect #35):
///
/// - `.contain`: a node with element descendants is a group of them — labelled when it is
///   itself an element (A01 §3.2), transparent when it is neither an element nor labelled nor
///   a `.group`; an element without element descendants is a leaf;
/// - `.combine`: one leaf, no children; label — own, else non-empty descendant labels joined
///   by `", "` in reading order; value/hint/role/state/actions — the node's own only;
/// - `.ignoreSelf`: an unlabelled group of the descendants, never an endpoint itself;
/// - `.hide`: the subtree is absent.
///
/// An `Arrangement` wrapper and a node with no visible area are transparent — their visible
/// descendants still appear, so a zero-sized container never hides its children (no premature
/// parent-AABB rejection). Built iteratively over the committed pre-order: no recursion over
/// tree depth, no repeated copying of descendant lists (A12).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityTree: Sendable, Hashable {
    /// Identity of the committed root.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let root: NodeID

    /// The modal scope the tree was built from, or `nil` for the whole tree.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scope: NodeID?

    /// The bridge mount this tree belongs to (D47: native elements are keyed by it).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let mountEpoch: UInt64

    /// The `SemanticSnapshot.revision` this tree was built from.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let revision: UInt64

    /// Top-level elements in reading order.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let elements: [AccessibilityElement]

    /// Every leaf element, depth-first in reading order — what a linear cursor walks.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let readingOrder: [NodeID]

    private let index: [NodeID: AccessibilityElement]

    /// Number of elements and groups.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var count: Int { index.count }

    /// The element or group for a node, or `nil` if it has no semantic presence.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func element(for identity: NodeID) -> AccessibilityElement? { index[identity] }

    /// Builds the tree of `snapshot`, confined to `scope` when given (an unknown scope yields
    /// an empty tree).
    ///
    /// Ownership: returns a value; reads only the snapshot. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public static func build(from snapshot: SemanticSnapshot, scope: NodeID?) -> AccessibilityTree {
        let base = scope ?? snapshot.root
        var inScope: Set<NodeID> = []
        var stack: [NodeID] = snapshot.record(for: base).map { [$0.id] } ?? []
        while let next = stack.popLast() {
            inScope.insert(next)
            if let record = snapshot.record(for: next) { stack.append(contentsOf: record.children) }
        }

        // Children before parents: the committed pre-order reversed.
        var contributions: [NodeID: [Contribution]] = [:]
        for id in snapshot.order.reversed() where inScope.contains(id) {
            guard let record = snapshot.record(for: id) else { continue }

            var fromChildren: [Contribution] = []
            for child in record.children {
                fromChildren.append(contentsOf: contributions.removeValue(forKey: child) ?? [])
            }
            contributions[id] = Self.contribute(record, children: Self.ordered(fromChildren))
        }

        let top = Self.ordered(contributions[base] ?? []).map(\.element)
        var readingOrder: [NodeID] = []
        var index: [NodeID: AccessibilityElement] = [:]
        var walk: [AccessibilityElement] = top.reversed()
        while let element = walk.popLast() {
            index[element.id] = element
            if element.isElement { readingOrder.append(element.id) }
            walk.append(contentsOf: element.children.reversed())
        }
        return AccessibilityTree(
            root: snapshot.root,
            scope: scope,
            mountEpoch: snapshot.mountEpoch,
            revision: snapshot.revision,
            elements: top,
            readingOrder: readingOrder,
            index: index
        )
    }

    /// One element a node hands to its parent, tagged with the priority that orders it among
    /// its siblings — its own for a node that becomes an element, inherited when a transparent
    /// node passes descendants through.
    private struct Contribution {
        let element: AccessibilityElement
        let priority: Double
        let order: Int
    }

    private static func contribute(_ record: SemanticSnapshot.Record, children: [Contribution])
        -> [Contribution]
    {
        let properties = record.accessibility
        let transparent = record.isArrangementWrapper || record.visibleBounds == nil
        guard properties.childrenPolicy != .hide else { return [] }

        if transparent { return children }

        let childElements = children.map(\.element)
        let own = Contribution(
            element: makeElement(record, isElement: true, label: properties.label, children: []),
            priority: properties.sortPriority,
            order: record.traversalIndex
        )
        switch properties.childrenPolicy {
        case .contain:
            if childElements.isEmpty {
                return properties.isElement ? [own] : []
            }
            let isNamedGroup =
                properties.isElement || properties.role == .group
                || (properties.label.map { !$0.isEmpty } ?? false)
            guard isNamedGroup else { return children }

            return [
                Contribution(
                    element: makeElement(
                        record,
                        isElement: false,
                        label: properties.label,
                        children: childElements
                    ),
                    priority: properties.sortPriority,
                    order: record.traversalIndex
                )
            ]
        case .combine:
            let descendantLabels = childElements.flatMap(Self.leafLabels)
            let label: String?
            if let ownLabel = properties.label, !ownLabel.isEmpty {
                label = ownLabel
            } else {
                label = descendantLabels.isEmpty ? nil : descendantLabels.joined(separator: ", ")
            }
            guard properties.isElement || !childElements.isEmpty else { return [] }

            return [
                Contribution(
                    element: makeElement(record, isElement: true, label: label, children: []),
                    priority: properties.sortPriority,
                    order: record.traversalIndex
                )
            ]
        case .ignoreSelf:
            guard !childElements.isEmpty else { return [] }

            return [
                Contribution(
                    element: makeElement(
                        record,
                        isElement: false,
                        label: nil,
                        children: childElements
                    ),
                    priority: properties.sortPriority,
                    order: record.traversalIndex
                )
            ]
        case .hide:
            return []
        }
    }

    private static func makeElement(
        _ record: SemanticSnapshot.Record,
        isElement: Bool,
        label: String?,
        children: [AccessibilityElement]
    ) -> AccessibilityElement {
        let properties = record.accessibility
        var actions = properties.actions
        if record.isActivatable, !actions.contains(.activate) { actions.insert(.activate, at: 0) }
        let role = properties.role ?? (record.isActivatable ? .button : nil)
        let frame = record.visibleBounds ?? Self.union(children.map(\.frame)) ?? record.frame
        return AccessibilityElement(
            id: record.id,
            frame: frame,
            isElement: isElement,
            label: label,
            value: isElement ? properties.value : nil,
            hint: isElement ? properties.hint : nil,
            identifier: properties.identifier,
            role: isElement ? role : (properties.role == .group ? .group : nil),
            isEnabled: record.isEnabled,
            isSelected: isElement && properties.isSelected,
            actions: isElement ? actions : [],
            customActions: isElement ? properties.customActions : [],
            children: children
        )
    }

    /// Siblings by `sortPriority` descending, ties in committed order (stable).
    private static func ordered(_ contributions: [Contribution]) -> [Contribution] {
        contributions.sorted { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.order < rhs.order
        }
    }

    private static func leafLabels(_ element: AccessibilityElement) -> [String] {
        var labels: [String] = []
        var stack: [AccessibilityElement] = [element]
        while let next = stack.popLast() {
            if next.isElement, let label = next.label, !label.isEmpty { labels.append(label) }
            stack.append(contentsOf: next.children.reversed())
        }
        return labels
    }

    private static func union(_ frames: [LayoutFrame]) -> LayoutFrame? {
        guard var result = frames.first else { return nil }

        for frame in frames.dropFirst() {
            let minX = min(result.origin.x, frame.origin.x)
            let minY = min(result.origin.y, frame.origin.y)
            let maxX = max(result.origin.x + result.width, frame.origin.x + frame.width)
            let maxY = max(result.origin.y + result.height, frame.origin.y + frame.height)
            result = LayoutFrame(
                origin: LayoutPoint(x: minX, y: minY),
                width: maxX - minX,
                height: maxY - minY
            )
        }
        return result
    }
}
