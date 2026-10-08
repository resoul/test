import Testing

@testable import TrellisCore

@Test @MainActor
func test_leaf_lowersToTheSameNode() {
    let node = Node()

    let descriptor = lower(Leaf(node))

    guard case let .leaf(lowered) = descriptor.kind else {
        Issue.record("expected .leaf")
        return
    }
    #expect(lowered === node)
}

@Test @MainActor
func test_row_lowersItsOwnConfigurationAndItems() {
    let first = Node()
    let second = Node()
    let padding = DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

    let descriptor = lower(
        Row(spacing: 12, justify: .center, align: .center, padding: padding) {
            Leaf(first)
            Leaf(second)
        }
    )

    guard case let .row(container) = descriptor.kind else {
        Issue.record("expected .row")
        return
    }
    #expect(container.spacing == 12)
    #expect(container.justify == .center)
    #expect(container.align == .center)
    #expect(container.padding == padding)
    #expect(container.items.count == 2)
    guard case let .leaf(firstLowered) = container.items[0].kind,
        case let .leaf(secondLowered) = container.items[1].kind
    else {
        Issue.record("expected two leaves in order")
        return
    }
    #expect(firstLowered === first)
    #expect(secondLowered === second)
}

@Test @MainActor
func test_column_lowersToColumnKind() {
    let descriptor = lower(Column { Leaf(Node()) })

    guard case .column = descriptor.kind else {
        Issue.record("expected .column")
        return
    }
}

@Test @MainActor
func test_overlay_hasNoPubliclyConfigurableFlexFields() {
    let descriptor = lower(Overlay { Leaf(Node()) })

    guard case let .overlay(container) = descriptor.kind else {
        Issue.record("expected .overlay")
        return
    }
    // Overlay items never join a flex line (C21): these fields are inert defaults, not a
    // configuration surface — Overlay's public init does not expose them.
    #expect(container.spacing == 0)
    #expect(container.justify == .start)
    #expect(container.align == .stretch)
}

@Test @MainActor
func test_emptyContainer_lowersWithNoItems() {
    let descriptor = lower(Row {})

    guard case let .row(container) = descriptor.kind else {
        Issue.record("expected .row")
        return
    }
    #expect(container.items.isEmpty)
}

@Test @MainActor
func test_modifiers_accumulateAcrossDifferentFields() {
    let descriptor = lower(
        Leaf(Node())
            .grow(1)
            .size(width: 48, height: 48)
            .align(.center)
            .margin(DirectionalEdgeInsets(top: 4))
            .offset(DirectionalEdgeOffsets(top: 2, leading: 2))
    )

    #expect(descriptor.modifiers.grow == 1)
    #expect(descriptor.modifiers.width == .points(48))
    #expect(descriptor.modifiers.height == .points(48))
    #expect(descriptor.modifiers.alignSelf == .center)
    #expect(descriptor.modifiers.margin == DirectionalEdgeInsets(top: 4))
    #expect(descriptor.modifiers.offset == DirectionalEdgeOffsets(top: 2, leading: 2))
}

@Test @MainActor
func test_modifiers_laterCallOnSameFieldWins() {
    let descriptor = lower(Leaf(Node()).grow(1).grow(2))

    #expect(descriptor.modifiers.grow == 2)
}

@Test @MainActor
func test_size_leavesUnsetDimensionAlone() {
    let descriptor = lower(Leaf(Node()).size(width: 48).size(height: 24))

    #expect(descriptor.modifiers.width == .points(48))
    #expect(descriptor.modifiers.height == .points(24))
}

@Test @MainActor
func test_builder_supportsSequenceOfItems() {
    let a = Node()
    let b = Node()
    let c = Node()

    let descriptor = lower(
        Row {
            Leaf(a); Leaf(b); Leaf(c)
        }
    )

    guard case let .row(container) = descriptor.kind else {
        Issue.record("expected .row")
        return
    }
    #expect(container.items.count == 3)
}

@Test @MainActor
func test_builder_supportsOptionalWithoutElse() {
    func makeRow(includeSecond: Bool) -> some Arrangement {
        Row {
            Leaf(Node())
            if includeSecond {
                Leaf(Node())
            }
        }
    }

    guard case let .row(withSecond) = lower(makeRow(includeSecond: true)).kind,
        case let .row(withoutSecond) = lower(makeRow(includeSecond: false)).kind
    else {
        Issue.record("expected .row")
        return
    }
    #expect(withSecond.items.count == 2)
    #expect(withoutSecond.items.count == 1)
}

@Test @MainActor
func test_builder_supportsIfElseBranch() {
    func makeRow(hasSubtitle: Bool) -> some Arrangement {
        Row {
            if hasSubtitle {
                Column {
                    Leaf(Node()); Leaf(Node())
                }
            } else {
                Leaf(Node())
            }
        }
    }

    guard case let .row(withColumn) = lower(makeRow(hasSubtitle: true)).kind,
        case let .row(withLeaf) = lower(makeRow(hasSubtitle: false)).kind
    else {
        Issue.record("expected .row")
        return
    }
    guard case .column = withColumn.items[0].kind, case .leaf = withLeaf.items[0].kind else {
        Issue.record("expected branch-specific kind")
        return
    }
}

@Test @MainActor
func test_builder_supportsLoop() {
    let nodes = [Node(), Node(), Node()]

    let descriptor = lower(
        Row {
            for node in nodes {
                Leaf(node)
            }
        }
    )

    guard case let .row(container) = descriptor.kind else {
        Issue.record("expected .row")
        return
    }
    #expect(container.items.count == 3)
}

private struct UnrecognizedArrangement: Arrangement {}

@Test @MainActor
func test_unrecognizedConformance_lowersToEmptyContainerInsteadOfCrashing() {
    let descriptor = lower(UnrecognizedArrangement())

    guard case let .row(container) = descriptor.kind else {
        Issue.record("expected an inert .row fallback")
        return
    }
    #expect(container.items.isEmpty)
}

/// Mirrors the C21 worked example (docs/validation/c21-arrangement-contract.md) to prove a
/// subclass declared with normal access — no `@testable` needed for this part, `Arrangement`
/// and `Node.arrangeSubnodes()` are both public — can describe a nested, modified arrangement.
private final class ProfileCard: Node {
    let avatar = Node()
    let title = Node()
    let subtitle = Node()

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(spacing: 12, align: .center) {
            Leaf(avatar).size(width: 48, height: 48)
            Column(spacing: 4) {
                Leaf(title)
                Leaf(subtitle)
            }
            .grow(1)
        }
    }
}

@Test @MainActor
func test_profileCard_arrangeSubnodesLowersToExpectedShape() {
    let card = ProfileCard()

    guard let arrangement = card.arrangeSubnodes() else {
        Issue.record("expected a non-nil arrangement")
        return
    }
    let descriptor = lower(arrangement)

    guard case let .row(row) = descriptor.kind else {
        Issue.record("expected root .row")
        return
    }
    #expect(row.spacing == 12)
    #expect(row.align == .center)
    #expect(row.items.count == 2)

    guard case let .leaf(avatarNode) = row.items[0].kind else {
        Issue.record("expected avatar leaf")
        return
    }
    #expect(avatarNode === card.avatar)
    #expect(row.items[0].modifiers.width == .points(48))
    #expect(row.items[0].modifiers.height == .points(48))

    guard case let .column(column) = row.items[1].kind else {
        Issue.record("expected column wrapper")
        return
    }
    #expect(row.items[1].modifiers.grow == 1)
    #expect(column.spacing == 4)
    #expect(column.items.count == 2)
    guard case let .leaf(titleNode) = column.items[0].kind,
        case let .leaf(subtitleNode) = column.items[1].kind
    else {
        Issue.record("expected title/subtitle leaves")
        return
    }
    #expect(titleNode === card.title)
    #expect(subtitleNode === card.subtitle)
}

@Test @MainActor
func test_node_defaultArrangeSubnodesReturnsNil() {
    let node = Node()

    #expect(node.arrangeSubnodes() == nil)
}
