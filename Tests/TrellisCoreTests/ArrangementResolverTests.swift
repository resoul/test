import Testing

@testable import TrellisCore

@Test @MainActor
func test_resolve_rootContainer_adoptsLeavesAndSetsEffectiveStyle() {
    final class Owner: Node {
        let avatar = Node()
        let title = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row(spacing: 12, align: .center) {
                Leaf(avatar).size(width: 48, height: 48)
                Leaf(title).grow(1)
            }
        }
    }

    let card = Owner()
    let avatar = card.avatar
    let title = card.title
    #expect(card.resolveArrangement())

    #expect(card.subnodes.map(\.id) == [avatar.id, title.id])
    #expect(card.childrenAreArrangementManaged)
    #expect(card.arrangementEffectiveStyle?.flexDirection == .row)
    #expect(card.arrangementEffectiveStyle?.gap == 12)
    #expect(card.arrangementEffectiveStyle?.alignItems == .center)
    #expect(avatar.arrangementEffectiveStyle?.width == .points(48))
    #expect(avatar.arrangementEffectiveStyle?.height == .points(48))
    #expect(title.arrangementEffectiveStyle?.flexGrow == 1)
    // Base styles are never touched (D04).
    #expect(avatar.style == LayoutStyle())
    #expect(title.style == LayoutStyle())
}

@Test @MainActor
func test_resolve_rootContainer_composesOverOwnerBaseStyleAndAppliesRootModifiers() {
    // C21: the root container *is* self, so its effective style is the owner's base `style`
    // (D04) with the container's own fields and the root descriptor's modifiers laid over it —
    // a subclass's `width`/`alignSelf`/`margin` from its own `init` must survive, and a
    // modifier on the root container must land on self exactly like one on a nested wrapper.
    final class Card: Node {
        let title = Node()
        init() {
            super.init()
            style.width = .points(360)
            style.alignSelf = .center
            style.margin = DirectionalEdgeInsets(top: 8)
            style.padding = DirectionalEdgeInsets(top: 99)
            style.gap = 99
        }
        override func arrangeSubnodes() -> (any Arrangement)? {
            Column(spacing: 16, padding: DirectionalEdgeInsets(top: 24)) {
                Leaf(title)
            }
            .grow(1)
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())

    let effective = card.arrangementEffectiveStyle
    // Item fields the DSL never mentions come from the base untouched.
    #expect(effective?.width == .points(360))
    #expect(effective?.alignSelf == .center)
    #expect(effective?.margin == DirectionalEdgeInsets(top: 8))
    // Container fields are owned by the container, never inherited from the base.
    #expect(effective?.flexDirection == .column)
    #expect(effective?.gap == 16)
    #expect(effective?.padding == DirectionalEdgeInsets(top: 24))
    // Root modifiers apply to self.
    #expect(effective?.flexGrow == 1)
    // The base itself is never written (D04).
    #expect(card.style.gap == 99)
    #expect(card.style.padding == DirectionalEdgeInsets(top: 99))
    #expect(card.style.flexGrow == 0)
}

@Test @MainActor
func test_resolve_rootContainer_paddingIsOwnedByContainerNotBase() {
    // A container that does not mention padding lays out with zero padding, for the root
    // exactly as for a wrapper: "unset" and "zero" are the same thing, and the owner's base
    // padding is not consulted (it belongs to the manual-mode snapshot only).
    final class Card: Node {
        let title = Node()
        init() {
            super.init()
            style.padding = DirectionalEdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
        }
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row { Leaf(title) }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())
    #expect(card.arrangementEffectiveStyle?.padding == DirectionalEdgeInsets())

    // Returning to manual mode restores the base padding raw (D05).
    #expect(card.style.padding.top == 24)
}

@Test @MainActor
func test_resolve_rootLeaf_appliesModifiersToTheLeafNotSelf() {
    final class Owner: Node {
        let content = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Leaf(content).size(width: 48, height: 48).grow(1)
        }
    }

    let owner = Owner()
    #expect(owner.resolveArrangement())

    #expect(owner.subnodes.map(\.id) == [owner.content.id])
    #expect(owner.arrangementEffectiveStyle == nil)
    #expect(owner.content.arrangementEffectiveStyle?.width == .points(48))
    #expect(owner.content.arrangementEffectiveStyle?.height == .points(48))
    #expect(owner.content.arrangementEffectiveStyle?.flexGrow == 1)
    #expect(owner.content.style == LayoutStyle())
}

// MARK: - Two owners on one node (a `Leaf` that arranges its own children)

/// A self-arranging tile placed by a parent owner: the parent decides the tile's placement
/// (`.grow(1)`), the tile decides its own container fields. Both must survive in the tile's
/// effective style whichever of the two resolves last (C21 order: owner, then its children).
@MainActor
private final class TileNode: Node {
    let line = Node()
    var shape: Shape = .column
    enum Shape { case column, rootLeaf, manual }

    override func arrangeSubnodes() -> (any Arrangement)? {
        switch shape {
        case .column: Column(spacing: 4, padding: DirectionalEdgeInsets(top: 10)) { Leaf(line) }
        case .rootLeaf: Leaf(line)
        case .manual: nil
        }
    }
}

@MainActor
private final class TileHost: Node {
    let tile = TileNode()
    var includeTile = true
    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(spacing: 8) {
            if includeTile { Leaf(tile).grow(1).size(height: .points(80)) }
        }
    }
}

@Test @MainActor
func test_resolve_nestedOwner_keepsParentPlacementAndOwnContainerInEitherOrder() {
    let host = TileHost()
    #expect(host.resolveArrangement())
    #expect(host.tile.resolveArrangement())

    var effective = host.tile.arrangementEffectiveStyle
    #expect(effective?.flexGrow == 1)
    #expect(effective?.height == .points(80))
    #expect(effective?.flexDirection == .column)
    #expect(effective?.gap == 4)
    #expect(effective?.padding == DirectionalEdgeInsets(top: 10))

    // Re-resolving the parent after the child must not wipe the child's container fields.
    #expect(host.resolveArrangement())
    effective = host.tile.arrangementEffectiveStyle
    #expect(effective?.flexGrow == 1)
    #expect(effective?.flexDirection == .column)
    #expect(effective?.gap == 4)
    #expect(host.tile.line.arrangementEffectiveStyle != nil)
}

@Test @MainActor
func test_resolve_nestedOwner_rootLeafOrNilArrangementKeepsParentPlacement() {
    let host = TileHost()
    #expect(host.resolveArrangement())

    host.tile.shape = .rootLeaf
    #expect(host.tile.resolveArrangement())
    #expect(host.tile.arrangementEffectiveStyle?.flexGrow == 1)
    #expect(host.tile.arrangementEffectiveStyle?.flexDirection == .row)

    host.tile.shape = .manual
    #expect(host.tile.resolveArrangement())
    #expect(host.tile.arrangementEffectiveStyle?.flexGrow == 1)
    #expect(host.tile.line.arrangementEffectiveStyle == nil)
}

@Test @MainActor
func test_resolve_leafLeavingAnArrangement_dropsItsPlacement() {
    let host = TileHost()
    #expect(host.resolveArrangement())
    #expect(host.tile.resolveArrangement())

    host.includeTile = false
    #expect(host.resolveArrangement())
    #expect(host.tile.supernode == nil)
    // The parent's placement is gone; the tile's own container fields remain.
    #expect(host.tile.arrangementEffectiveStyle?.flexGrow == 0)
    #expect(host.tile.arrangementEffectiveStyle?.height == .auto)
    #expect(host.tile.arrangementEffectiveStyle?.flexDirection == .column)

    host.tile.shape = .manual
    #expect(host.tile.resolveArrangement())
    #expect(host.tile.arrangementEffectiveStyle == nil)
}

@Test @MainActor
func test_resolve_baseStyleChangeWhileManaged_isReflectedInEffectiveStyle() {
    // D04: effective is *derived* from base, so a later base edit shows through without
    // waiting for the next resolve.
    let host = TileHost()
    #expect(host.resolveArrangement())
    host.tile.style.minWidth = .points(30)
    #expect(host.tile.arrangementEffectiveStyle?.minWidth == .points(30))
    #expect(host.tile.arrangementEffectiveStyle?.flexGrow == 1)
}

@Test @MainActor
func test_resolve_nestedContainer_createsWrapperWithOwnStyleAndModifiers() {
    final class Card: Node {
        let title = Node()
        let subtitle = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                Column(spacing: 4) {
                    Leaf(title)
                    Leaf(subtitle)
                }
                .grow(1)
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())

    #expect(card.subnodes.count == 1)
    let wrapper = card.subnodes[0]
    #expect(wrapper !== card)
    #expect(wrapper.subnodes.map(\.id) == [card.title.id, card.subtitle.id])
    #expect(wrapper.arrangementEffectiveStyle?.flexDirection == .column)
    #expect(wrapper.arrangementEffectiveStyle?.gap == 4)
    #expect(wrapper.arrangementEffectiveStyle?.flexGrow == 1)
    #expect(wrapper.childrenAreArrangementManaged)
}

@Test @MainActor
func test_resolve_repeatedResolveOfUnchangedTree_reusesWrapperAndAvoidsChurn() {
    final class Card: Node {
        let title = Node()
        let subtitle = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                Column {
                    Leaf(title); Leaf(subtitle)
                }
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())
    let wrapper = card.subnodes[0]
    let structureBefore = wrapper.structureRevision

    #expect(card.resolveArrangement())

    #expect(card.subnodes[0] === wrapper)
    #expect(wrapper.structureRevision == structureBefore)
}

@Test @MainActor
func test_resolve_removingASlot_detachesLeafWithoutDisposingIt() {
    final class Card: Node {
        let title = Node()
        let subtitle = Node()
        var includeSubtitle = true
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                Leaf(title)
                if includeSubtitle {
                    Leaf(subtitle)
                }
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())
    #expect(card.subnodes.count == 2)

    card.includeSubtitle = false
    #expect(card.resolveArrangement())

    #expect(card.subnodes.map(\.id) == [card.title.id])
    #expect(card.subtitle.isDisposed == false)
    #expect(card.subtitle.supernode == nil)
}

@Test @MainActor
func test_resolve_typeChangeAtSamePath_disposesOldWrapperButNotNestedLeaves() {
    final class Card: Node {
        let title = Node()
        let subtitle = Node()
        var hasSubtitle = true
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                if hasSubtitle {
                    Column {
                        Leaf(title); Leaf(subtitle)
                    }
                } else {
                    Leaf(title).grow(1)
                }
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())
    let oldWrapper = card.subnodes[0]
    #expect(oldWrapper.subnodes.count == 2)

    card.hasSubtitle = false
    #expect(card.resolveArrangement())

    #expect(oldWrapper.isDisposed)
    #expect(card.subnodes.map(\.id) == [card.title.id])
    #expect(card.title.arrangementEffectiveStyle?.flexGrow == 1)
    // The old column's style never leaks onto title (D04).
    #expect(card.title.arrangementEffectiveStyle?.flexDirection == .row)
    #expect(card.subtitle.isDisposed == false)
    #expect(card.subtitle.supernode == nil)

    card.hasSubtitle = true
    #expect(card.resolveArrangement())
    let newWrapper = card.subnodes[0]
    #expect(newWrapper !== oldWrapper)
    #expect(newWrapper.subnodes.map(\.id) == [card.title.id, card.subtitle.id])
}

@Test @MainActor
func test_resolve_reorderPreservesNodeID() {
    final class Card: Node {
        let a = Node()
        let b = Node()
        var reversed = false
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                if reversed {
                    Leaf(b)
                    Leaf(a)
                } else {
                    Leaf(a)
                    Leaf(b)
                }
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())
    let aID = card.a.id
    let bID = card.b.id
    #expect(card.subnodes.map(\.id) == [aID, bID])

    card.reversed = true
    #expect(card.resolveArrangement())

    #expect(card.subnodes.map(\.id) == [bID, aID])
    #expect(card.subnodes[0] === card.b)
    #expect(card.subnodes[1] === card.a)
}

@Test @MainActor
func test_resolve_nilArrangement_returnsToManualModeWithoutDisposingLeaves() {
    final class Card: Node {
        let title = Node()
        var managed = true
        override func arrangeSubnodes() -> (any Arrangement)? {
            managed ? Row { Leaf(title) } : nil
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())
    #expect(card.childrenAreArrangementManaged)

    card.managed = false
    #expect(card.resolveArrangement())

    #expect(!card.childrenAreArrangementManaged)
    #expect(card.subnodes.isEmpty)
    #expect(card.title.isDisposed == false)
    #expect(card.title.supernode == nil)
    #expect(card.arrangementEffectiveStyle == nil)

    // Manual mode is usable again after demanaging.
    card.addSubnode(card.title)
    #expect(card.subnodes.map(\.id) == [card.title.id])
}

@Test @MainActor
func test_resolve_nilArrangementNeverManaged_isANoOp() {
    let node = Node()

    #expect(node.resolveArrangement())
    #expect(!node.childrenAreArrangementManaged)
}

@Test @MainActor
func test_resolve_duplicateLeafInSameProposal_rejectsWithoutMutation() {
    final class Card: Node {
        let title = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                Leaf(title); Leaf(title)
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement() == false)
    #expect(card.subnodes.isEmpty)
    #expect(!card.childrenAreArrangementManaged)
}

@Test @MainActor
func test_resolve_selfLeaf_rejectsWithoutMutation() {
    final class Card: Node {
        override func arrangeSubnodes() -> (any Arrangement)? {
            Leaf(self)
        }
    }

    let card = Card()
    #expect(card.resolveArrangement() == false)
    #expect(!card.childrenAreArrangementManaged)
}

@Test @MainActor
func test_resolve_ancestorLeaf_rejectsAsCycle() {
    final class Child: Node {
        weak var ancestor: Node?
        override func arrangeSubnodes() -> (any Arrangement)? {
            ancestor.map { Leaf($0) }
        }
    }

    let root = Node()
    let child = Child()
    root.addSubnode(child)
    child.ancestor = root

    #expect(child.resolveArrangement() == false)
    #expect(child.subnodes.isEmpty)
}

@Test @MainActor
func test_resolve_foreignMountedLeaf_rejectsWithoutMutation() {
    let other = Node()
    let leaf = Node()
    other.addSubnode(leaf)

    final class Card: Node {
        let leaf: Node
        init(leaf: Node) {
            self.leaf = leaf
            super.init()
        }
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row { Leaf(leaf) }
        }
    }

    let card = Card(leaf: leaf)
    #expect(card.resolveArrangement() == false)
    #expect(leaf.supernode === other)
    #expect(card.subnodes.isEmpty)
}

@Test @MainActor
func test_resolve_manualMutationOfManagedList_isRejected() {
    final class Card: Node {
        let title = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row { Leaf(title) }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())

    let intruder = Node()
    card.addSubnode(intruder)
    #expect(card.subnodes.map(\.id) == [card.title.id])

    card.title.removeFromSupernode()
    #expect(card.subnodes.map(\.id) == [card.title.id])

    card.moveSubnode(from: 0, to: 0)
    #expect(card.subnodes.map(\.id) == [card.title.id])
}

@Test @MainActor
func test_resolve_overlayChildren_getAbsolutePositionTypeAndOffset() {
    final class Card: Node {
        let back = Node()
        let badge = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Overlay {
                Leaf(back)
                Leaf(badge).offset(DirectionalEdgeOffsets(top: 2, leading: 2))
            }
        }
    }

    let card = Card()
    #expect(card.resolveArrangement())

    #expect(card.back.arrangementEffectiveStyle?.positionType == .absolute)
    #expect(card.badge.arrangementEffectiveStyle?.positionType == .absolute)
    #expect(
        card.badge.arrangementEffectiveStyle?.offsets == DirectionalEdgeOffsets(top: 2, leading: 2)
    )
}

@Test @MainActor
func test_resolve_appliedInsideOneTransaction_pingsOnlyOnce() {
    final class Card: Node {
        let title = Node()
        let subtitle = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row {
                Leaf(title); Leaf(subtitle)
            }
        }
    }

    let card = Card()
    var pingCount = 0
    card.onInvalidate = { _, _ in pingCount += 1 }

    #expect(card.resolveArrangement())

    #expect(pingCount == 1)
}

@Test @MainActor
func test_resolve_snapshotUsesEffectiveStyleNotBaseStyle() {
    final class Card: Node {
        let title = Node()
        override func arrangeSubnodes() -> (any Arrangement)? {
            Row(spacing: 7) { Leaf(title).grow(2) }
        }
    }

    let card = Card()
    card.style.gap = 99
    #expect(card.resolveArrangement())

    let snapshot = card.makeLayoutInputSnapshot()
    #expect(snapshot.style.gap == 7)
    #expect(snapshot.children[0].style.flexGrow == 2)
    // The user's own base style is untouched (D04).
    #expect(card.style.gap == 99)
}
