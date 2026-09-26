/// Identifies an implicit wrapper node within one owner's `Arrangement` subtree (D06): the
/// `structuralPath` — sibling indices from the owner down to this container — plus its
/// `containerKind`. `ownerID` is implicit: this key is only ever looked up in the wrapper
/// cache that already lives on that specific owner (`Node.arrangementWrapperCache`).
///
/// Stability is promised only while both fields stay the same across two resolves of the same
/// owner (C21): a container that changes kind at the same path is a different key, so it never
/// silently inherits the previous wrapper's identity or leftover style.
package struct ArrangementWrapperKey: Hashable {
    package enum ContainerKind: Hashable {
        case row
        case column
        case overlay
    }

    package var path: [Int]
    package var containerKind: ContainerKind
}

extension Node {
    /// Resolves this node's `arrangeSubnodes()` against its current live child list (C23).
    ///
    /// Builds and validates a complete proposal before touching the tree — any duplicate
    /// `Leaf`, self/ancestor cycle, or reference to a node mounted outside this node's own
    /// `Arrangement` subtree aborts the whole resolve with a single diagnostic and leaves the
    /// tree exactly as it was (C21). A valid proposal is then applied atomically inside an
    /// `InvalidationTransaction`: reused `Leaf`/wrapper nodes keep their `NodeID`, stale
    /// wrappers are disposed (their own nested user `Leaf`s only detached, never disposed,
    /// D05), and every managed node's effective style is recomputed from its own base style
    /// (D04) — never accumulated from a prior resolve.
    ///
    /// The synchronous entry point. A mounted host calls it for you (C32, D13): every node is
    /// resolved once by the first flush after attach and again after `markArrangementDirty()`,
    /// owner before the nodes it placed. Call this directly only when the result is needed
    /// immediately — tests, or code that reads the managed children right away. Never valid
    /// on an implicit wrapper (`isArrangementWrapper`): its children belong to its owner's
    /// resolve, and the call is rejected rather than read as "return them to manual mode".
    ///
    /// Ownership: mutates only this node's own `Arrangement`-managed subtree. Isolation:
    /// MainActor. Errors: an invalid proposal is diagnosed via `Log.on` and rejected; this
    /// method never throws. Cancellation: not applicable — resolution is synchronous.
    @discardableResult
    public func resolveArrangement() -> Bool {
        guard !isDisposed else { return false }
        guard !isArrangementWrapper else {
            Log.on(.arrange, "rejected", node: id, "reason=implicit-wrapper")
            return false
        }
        needsArrangementResolve = false

        guard let arrangement = arrangeSubnodes() else {
            InvalidationTransaction.perform { demanageArrangement() }
            return true
        }

        let descriptor = lower(arrangement)
        var seenLeaves: Set<ObjectIdentifier> = []
        let managedAncestors = arrangementManagedAncestorCandidates()
        let plan: ArrangementPlan?

        // A root container describes `self` (C21), so the plan's container style becomes
        // this node's own `arrangementContainerStyle`; a root `Leaf` says nothing about self.
        // Either way, whatever placement this node's *parent* owner gave it stays untouched.
        switch descriptor.kind {
        case let .leaf(node):
            if ArrangementPlan.validateLeaf(
                node,
                owner: self,
                seenLeaves: &seenLeaves,
                managedAncestors: managedAncestors
            ) {
                plan = ArrangementPlan(
                    containerStyle: nil,
                    items: [
                        .leaf(
                            node,
                            ArrangementPlacement(
                                modifiers: descriptor.modifiers,
                                isAbsolute: false
                            )
                        )
                    ]
                )
            } else {
                plan = nil
            }
        case let .row(container):
            plan = ArrangementPlan.buildContainer(
                container,
                kind: .row,
                modifiers: descriptor.modifiers,
                owner: self,
                path: [],
                seenLeaves: &seenLeaves,
                managedAncestors: managedAncestors
            )
        case let .column(container):
            plan = ArrangementPlan.buildContainer(
                container,
                kind: .column,
                modifiers: descriptor.modifiers,
                owner: self,
                path: [],
                seenLeaves: &seenLeaves,
                managedAncestors: managedAncestors
            )
        case let .overlay(container):
            plan = ArrangementPlan.buildContainer(
                container,
                kind: .overlay,
                modifiers: descriptor.modifiers,
                owner: self,
                path: [],
                seenLeaves: &seenLeaves,
                managedAncestors: managedAncestors
            )
        }

        guard let plan else {
            Log.on(.arrange, "rejected", node: id, "reason=invalid-proposal")
            return false
        }

        InvalidationTransaction.perform {
            Node.isResolving = true
            applyChildren(of: plan, retainedLeaves: seenLeaves)
            Node.isResolving = false
            setArrangementContainerStyle(plan.containerStyle)
            childrenAreArrangementManaged = true
        }
        Log.on(.arrange, "resolved", node: id)
        return true
    }

    /// Tears down a previously resolved `Arrangement`, returning this node to manual mode
    /// (D05): every cached wrapper is disposed (its own children only detached first, never
    /// disposed with it), every adopted `Leaf` is detached without disposing it and loses the
    /// placement this owner gave it, and this node's own `arrangementContainerStyle` is
    /// cleared so `style` (the untouched base, D04) is used raw again — unless a *parent*
    /// owner still places this node, in which case that placement alone remains in effect.
    /// A no-op if this node was never managed.
    fileprivate func demanageArrangement() {
        guard childrenAreArrangementManaged || !arrangementWrapperCache.isEmpty else { return }
        Node.isResolving = true
        for child in subnodes {
            teardownManagedSubtree(child, retainedLeaves: [])
        }
        Node.isResolving = false
        arrangementWrapperCache = [:]
        childrenAreArrangementManaged = false
        setArrangementContainerStyle(nil)
    }

    /// Recursively detaches every node in a subtree being removed from management, disposing
    /// only the wrapper nodes it finds (D05) — never a user-owned `Leaf`. A `Leaf` that this
    /// same resolve places elsewhere (`retainedLeaves`) keeps the placement it was just given;
    /// any other detached node has its placement cleared, so a `Leaf` handed back to manual
    /// code carries no leftover `Arrangement` style.
    fileprivate func teardownManagedSubtree(_ node: Node, retainedLeaves: Set<ObjectIdentifier>) {
        let isWrapper = arrangementWrapperCache.values.contains { $0 === node }
        for child in node.subnodes {
            teardownManagedSubtree(child, retainedLeaves: retainedLeaves)
        }
        node.removeFromSupernode()
        if isWrapper {
            node.childrenAreArrangementManaged = false
            node.dispose()
        } else if !retainedLeaves.contains(ObjectIdentifier(node)) {
            node.setArrangementPlacement(nil)
        }
    }

    /// The current parents a `Leaf` in this node's own proposal is allowed to already have —
    /// itself, or any wrapper already cached from this node's *previous* resolve (D05/D06: a
    /// `Leaf` moving from one of this owner's own wrappers to another, or to/from being a
    /// direct child, is a reuse, not a foreign mount).
    fileprivate func arrangementManagedAncestorCandidates() -> Set<ObjectIdentifier> {
        var candidates = Set(arrangementWrapperCache.values.map(ObjectIdentifier.init))
        candidates.insert(ObjectIdentifier(self))
        return candidates
    }

    /// Reconciles this node's own child list against a validated plan's items, recursing into
    /// nested wrapper plans, then disposes whatever wrapper this resolve no longer references.
    /// Does not touch this node's *own* `arrangementContainerStyle` — a wrapper's is set by
    /// its parent just before this is called on it, and the root owner's is set once by
    /// `resolveArrangement()` after this returns.
    ///
    /// Only ever called with `Node.isResolving == true` already set by the caller, for the
    /// full duration of the recursion — the reused `Node.removeFromSupernode()`/
    /// `insertSubnode(_:at:)` calls this performs (here and in `teardownManagedSubtree(_:)`)
    /// would otherwise be rejected as manual mutation of a managed list (D05).
    fileprivate func applyChildren(of plan: ArrangementPlan, retainedLeaves: Set<ObjectIdentifier>)
    {
        var nextCache: [ArrangementWrapperKey: Node] = [:]
        let desired = plan.items.map { item -> Node in
            switch item {
            case let .leaf(node, placement):
                node.setArrangementPlacement(placement)
                return node
            case let .container(key, placement, childPlan):
                let wrapper = arrangementWrapperCache[key] ?? Node()
                wrapper.isArrangementWrapper = true
                wrapper.childrenAreArrangementManaged = true
                wrapper.setArrangementContainerStyle(childPlan.containerStyle)
                wrapper.setArrangementPlacement(placement)
                wrapper.applyChildren(of: childPlan, retainedLeaves: retainedLeaves)
                nextCache[key] = wrapper
                return wrapper
            }
        }

        reconcileManagedChildren(desired: desired, retainedLeaves: retainedLeaves)

        for (key, wrapper) in arrangementWrapperCache where nextCache[key] !== wrapper {
            teardownManagedSubtree(wrapper, retainedLeaves: retainedLeaves)
        }
        arrangementWrapperCache = nextCache
    }

    /// Reorders/reparents this node's current children to exactly match `desired`, detaching
    /// (never disposing) whatever is no longer referenced — and clearing its placement unless
    /// this same resolve places it elsewhere. Only ever called with `Node.isResolving == true`.
    fileprivate func reconcileManagedChildren(
        desired: [Node],
        retainedLeaves: Set<ObjectIdentifier>
    ) {
        let desiredIdentities = Set(desired.map(ObjectIdentifier.init))
        for child in subnodes where !desiredIdentities.contains(ObjectIdentifier(child)) {
            child.removeFromSupernode()
            if !retainedLeaves.contains(ObjectIdentifier(child)) {
                child.setArrangementPlacement(nil)
            }
        }
        for (index, node) in desired.enumerated() {
            if index >= subnodes.count || subnodes[index] !== node {
                insertSubnode(node, at: index)
            }
        }
    }
}

/// A validated, not-yet-applied description of one container's resolved children (C23) — the
/// result of successfully walking an `ArrangementDescriptor` against the live tree. Also used,
/// with an empty `items` sentinel, as the trivial plan for a root `Leaf` (`Node.
/// resolveArrangement()` builds that case directly rather than through `buildContainer`, since
/// a root `Leaf` is not itself a container with items — see D03/C21: it never sets style on
/// `self`).
private struct ArrangementPlan {
    enum Item {
        case leaf(Node, ArrangementPlacement)
        case container(ArrangementWrapperKey, ArrangementPlacement, ArrangementPlan)
    }

    /// What this plan's container decides about the node it describes (the owner for a root
    /// plan, an implicit wrapper for a nested one) — `nil` when this plan describes a root
    /// `Leaf` (D03/C21: a root `Leaf` never sets style on `self`). The node's effective style
    /// is derived from this, its own base `style`, and its parent's placement by
    /// `LayoutStyle.arrangementEffective(base:container:placement:)` — never computed here.
    var containerStyle: ArrangementContainerStyle?
    var items: [Item]

    /// Builds and fully validates a plan for one container's items, or returns `nil` on the
    /// first violation anywhere in the subtree — duplicate `Leaf`, self/ancestor cycle, or a
    /// `Leaf` currently mounted outside `owner`'s own `Arrangement` subtree (C21). No live
    /// `Node` is mutated while building a plan. `modifiers` are the ones written on this
    /// container itself (the root descriptor's for the owner, the item's for a wrapper).
    @MainActor
    fileprivate static func buildContainer(
        _ container: ArrangementContainer,
        kind: ArrangementWrapperKey.ContainerKind,
        modifiers: ArrangementModifiers,
        owner: Node,
        path: [Int],
        seenLeaves: inout Set<ObjectIdentifier>,
        managedAncestors: Set<ObjectIdentifier>
    ) -> ArrangementPlan? {
        var items: [Item] = []
        for (index, itemDescriptor) in container.items.enumerated() {
            let itemPath = path + [index]
            let placement = ArrangementPlacement(
                modifiers: itemDescriptor.modifiers,
                isAbsolute: kind == .overlay
            )
            switch itemDescriptor.kind {
            case let .leaf(node):
                guard
                    validateLeaf(
                        node,
                        owner: owner,
                        seenLeaves: &seenLeaves,
                        managedAncestors: managedAncestors
                    )
                else { return nil }
                items.append(.leaf(node, placement))
            case let .row(nested):
                guard
                    let childPlan = buildContainer(
                        nested,
                        kind: .row,
                        modifiers: itemDescriptor.modifiers,
                        owner: owner,
                        path: itemPath,
                        seenLeaves: &seenLeaves,
                        managedAncestors: managedAncestors
                    )
                else { return nil }
                let key = ArrangementWrapperKey(path: itemPath, containerKind: .row)
                items.append(.container(key, placement, childPlan))
            case let .column(nested):
                guard
                    let childPlan = buildContainer(
                        nested,
                        kind: .column,
                        modifiers: itemDescriptor.modifiers,
                        owner: owner,
                        path: itemPath,
                        seenLeaves: &seenLeaves,
                        managedAncestors: managedAncestors
                    )
                else { return nil }
                let key = ArrangementWrapperKey(path: itemPath, containerKind: .column)
                items.append(.container(key, placement, childPlan))
            case let .overlay(nested):
                guard
                    let childPlan = buildContainer(
                        nested,
                        kind: .overlay,
                        modifiers: itemDescriptor.modifiers,
                        owner: owner,
                        path: itemPath,
                        seenLeaves: &seenLeaves,
                        managedAncestors: managedAncestors
                    )
                else { return nil }
                let key = ArrangementWrapperKey(path: itemPath, containerKind: .overlay)
                items.append(.container(key, placement, childPlan))
            }
        }

        let flexDirection: FlexDirection
        switch kind {
        case .row: flexDirection = .row
        case .column: flexDirection = .column
        case .overlay: flexDirection = .row
        }
        return ArrangementPlan(
            containerStyle: ArrangementContainerStyle(
                flexDirection: flexDirection,
                gap: container.spacing,
                justifyContent: container.justify,
                alignItems: container.align,
                padding: container.padding,
                modifiers: modifiers
            ),
            items: items
        )
    }

    @MainActor
    fileprivate static func validateLeaf(
        _ node: Node,
        owner: Node,
        seenLeaves: inout Set<ObjectIdentifier>,
        managedAncestors: Set<ObjectIdentifier>
    ) -> Bool {
        let identity = ObjectIdentifier(node)
        guard !seenLeaves.contains(identity) else {
            Log.on(.arrange, "rejected", node: node.id, "reason=duplicate-leaf")
            return false
        }
        guard node !== owner else {
            Log.on(.arrange, "rejected", node: node.id, "reason=self-leaf")
            return false
        }
        guard !isAncestor(node, of: owner) else {
            Log.on(.arrange, "rejected", node: node.id, "reason=ancestor-leaf")
            return false
        }

        if let currentParent = node.supernode,
            !managedAncestors.contains(ObjectIdentifier(currentParent))
        {
            Log.on(.arrange, "rejected", node: node.id, "reason=foreign-mounted-leaf")
            return false
        }
        seenLeaves.insert(identity)
        return true
    }

}

/// Whether `candidate` is `node`'s parent, grandparent, or further ancestor.
@MainActor
private func isAncestor(_ candidate: Node, of node: Node) -> Bool {
    var current = node.supernode
    while let next = current {
        if next === candidate { return true }
        current = next.supernode
    }
    return false
}
