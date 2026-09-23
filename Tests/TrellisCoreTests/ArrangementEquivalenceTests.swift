import Testing

@testable import TrellisCore

@MainActor
private func layoutTree(_ root: Node, width: Double = 320, height: Double = 640) throws {
    let frame = LayoutFrame(width: width, height: height)
    let snapshot = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(width), height: .exact(height))
    )
    let result = try FlexboxEngine.layoutContainer(input: snapshot, frame: frame)
    #expect(root.applyLayoutResult(result))
}

@MainActor
private func makeRoot(width: Double = 320, height: Double = 640) -> Node {
    let root = Node()
    root.style.flexDirection = .column
    root.style.padding = DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    root.style.width = .points(width)
    root.style.height = .points(height)
    return root
}

@MainActor
private func makeFixedNode(width: Double, height: Double) -> Node {
    let node = Node()
    node.style.width = .points(width)
    node.style.height = .points(height)
    return node
}

/// The imperative twin of a `Column(padding:)` wrapper — so `flexDirection` is `.column`, not
/// the `.row` default: the two forms are only equivalent if they say the same thing.
@MainActor
private func makePaddedNode(padding: Double = 12) -> Node {
    let node = Node()
    node.style.flexDirection = .column
    node.style.padding = DirectionalEdgeInsets(
        top: padding,
        leading: padding,
        bottom: padding,
        trailing: padding
    )
    node.style.minHeight = 24
    return node
}

// MARK: - S10 Equivalence

private final class S10ArrangedNode: Node {
    let leaf: Node

    init(leaf: Node) {
        self.leaf = leaf
        super.init()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            Column(padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
                Column(
                    padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
                ) {
                    Leaf(leaf)
                }
            }
        }
    }
}

@Test @MainActor
func test_s10_equivalence_subclassMatchesImperativeGeometryBySemanticPaths() throws {
    // 1. Imperative tree
    let rootImp = makeRoot()
    let level1Imp = makePaddedNode(padding: 12)
    let level2Imp = makePaddedNode(padding: 12)
    let level3Imp = makePaddedNode(padding: 12)
    let leafImp = makeFixedNode(width: 100, height: 64)
    level3Imp.addSubnode(leafImp)
    level2Imp.addSubnode(level3Imp)
    level1Imp.addSubnode(level2Imp)
    rootImp.addSubnode(level1Imp)

    try layoutTree(rootImp)

    // 2. Subclass tree with Arrangement
    let rootSub = makeRoot()
    let leafSub = makeFixedNode(width: 100, height: 64)
    let level1Sub = S10ArrangedNode(leaf: leafSub)
    rootSub.addSubnode(level1Sub)

    #expect(level1Sub.resolveArrangement())
    try layoutTree(rootSub)

    // Locate the nested wrappers in the arranged tree
    #expect(level1Sub.subnodes.count == 1)
    let level2Sub = level1Sub.subnodes[0]
    #expect(level2Sub.subnodes.count == 1)
    let level3Sub = level2Sub.subnodes[0]
    #expect(level3Sub.subnodes.count == 1)
    #expect(level3Sub.subnodes[0] === leafSub)

    // Compare geometry by semantic paths:
    // root
    #expect(rootSub.calculatedFrame == rootImp.calculatedFrame)
    // root/level1
    #expect(level1Sub.calculatedFrame == level1Imp.calculatedFrame)
    // root/level1/level2
    #expect(level2Sub.calculatedFrame == level2Imp.calculatedFrame)
    // root/level1/level2/level3
    #expect(level3Sub.calculatedFrame == level3Imp.calculatedFrame)
    // root/level1/level2/level3/leaf
    #expect(leafSub.calculatedFrame == leafImp.calculatedFrame)

    #expect(leafSub.calculatedFrame?.width == 100)
    #expect(leafSub.calculatedFrame?.height == 64)
}

// MARK: - S15 Equivalence & Dynamic Mutation

private final class S15ArrangedNode: Node {
    let stable: Node
    let transient: Node
    var showTransient = false

    init(stable: Node, transient: Node) {
        self.stable = stable
        self.transient = transient
        super.init()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(spacing: 8) {
            Leaf(stable)
            if showTransient {
                Leaf(transient)
            }
        }
    }
}

@Test @MainActor
func test_s15_equivalence_subclassMatchesImperativeGeometryAcrossStateTransitions() throws {
    // Imperative setup
    let rootImp = makeRoot()
    rootImp.style.gap = 8
    let stableImp = makeFixedNode(width: 180, height: 56)
    let transientImp = makeFixedNode(width: 180, height: 56)
    rootImp.addSubnode(stableImp)

    // Subclass setup
    let rootSub = makeRoot()
    let stableSub = makeFixedNode(width: 180, height: 56)
    let transientSub = makeFixedNode(width: 180, height: 56)
    let arranged = S15ArrangedNode(stable: stableSub, transient: transientSub)
    rootSub.addSubnode(arranged)

    let transientID = transientSub.id

    // --- State 1: transient is absent ---
    try layoutTree(rootImp)
    #expect(arranged.resolveArrangement())
    try layoutTree(rootSub)

    #expect(stableSub.calculatedFrame?.width == stableImp.calculatedFrame?.width)
    #expect(stableSub.calculatedFrame?.height == stableImp.calculatedFrame?.height)
    #expect(arranged.subnodes.count == 1)
    #expect(transientSub.supernode == nil)

    // --- State 2: transient is added ---
    rootImp.addSubnode(transientImp)
    try layoutTree(rootImp)

    arranged.showTransient = true
    #expect(arranged.resolveArrangement())
    try layoutTree(rootSub)

    #expect(stableSub.calculatedFrame?.origin == stableImp.calculatedFrame?.origin)
    #expect(stableSub.calculatedFrame?.width == stableImp.calculatedFrame?.width)
    #expect(stableSub.calculatedFrame?.height == stableImp.calculatedFrame?.height)
    #expect(transientSub.calculatedFrame?.origin == transientImp.calculatedFrame?.origin)
    #expect(transientSub.calculatedFrame?.width == transientImp.calculatedFrame?.width)
    #expect(transientSub.calculatedFrame?.height == transientImp.calculatedFrame?.height)
    #expect(transientSub.id == transientID)

    // --- State 3: transient is removed again ---
    transientImp.removeFromSupernode()
    try layoutTree(rootImp)

    arranged.showTransient = false
    #expect(arranged.resolveArrangement())
    try layoutTree(rootSub)

    #expect(stableSub.calculatedFrame?.origin == stableImp.calculatedFrame?.origin)
    #expect(stableSub.calculatedFrame?.width == stableImp.calculatedFrame?.width)
    #expect(stableSub.calculatedFrame?.height == stableImp.calculatedFrame?.height)
    #expect(transientSub.supernode == nil)
    #expect(transientSub.isDisposed == false)
    #expect(transientSub.id == transientID)
}

// MARK: - Removal Modifier

private final class ModifierTogglingNode: Node {
    let child = Node()
    var hasMargin = true
    var hasGrow = true

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row {
            if hasMargin && hasGrow {
                Leaf(child)
                    .margin(DirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    .grow(1)
            } else if hasGrow {
                Leaf(child).grow(1)
            } else if hasMargin {
                Leaf(child).margin(
                    DirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
                )
            } else {
                Leaf(child)
            }
        }
    }
}

@Test @MainActor
func test_removalModifier_cleanlyResetsEffectiveStyleToBase() throws {
    let container = ModifierTogglingNode()
    container.style.width = .points(200)
    container.style.height = .points(100)

    container.child.style.width = .points(40)
    container.child.style.height = .points(40)

    // 1. Both margin and grow
    #expect(container.resolveArrangement())
    #expect(
        container.child.arrangementEffectiveStyle?.margin
            == DirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    )
    #expect(container.child.arrangementEffectiveStyle?.flexGrow == 1)
    try layoutTree(container, width: 200, height: 100)
    #expect(container.child.calculatedFrame?.width == 180)  // 200 - 20 margin

    // 2. Remove margin (only grow remains)
    container.hasMargin = false
    #expect(container.resolveArrangement())
    #expect(container.child.arrangementEffectiveStyle?.margin == DirectionalEdgeInsets())
    #expect(container.child.arrangementEffectiveStyle?.flexGrow == 1)
    try layoutTree(container, width: 200, height: 100)
    #expect(container.child.calculatedFrame?.width == 200)

    // 3. Remove grow (no modifiers remain)
    container.hasGrow = false
    #expect(container.resolveArrangement())
    #expect(container.child.arrangementEffectiveStyle?.margin == DirectionalEdgeInsets())
    #expect(container.child.arrangementEffectiveStyle?.flexGrow == 0)
    try layoutTree(container, width: 200, height: 100)
    #expect(container.child.calculatedFrame?.width == 40)  // returns to base width

    // Base style was never mutated
    #expect(container.child.style.width == .points(40))
    #expect(container.child.style.height == .points(40))
    #expect(container.child.style.margin == DirectionalEdgeInsets())
    #expect(container.child.style.flexGrow == 0)
}

// MARK: - Conditional Wrapper & Leaf Reordering

private final class DynamicStructureNode: Node {
    let a: Node
    let b: Node
    var wrapInContainer = false
    var isReversed = false

    init(a: Node, b: Node) {
        self.a = a
        self.b = b
        super.init()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(spacing: 8) {
            if wrapInContainer {
                Row(spacing: 12) {
                    if isReversed {
                        Leaf(b)
                        Leaf(a)
                    } else {
                        Leaf(a)
                        Leaf(b)
                    }
                }
            } else {
                if isReversed {
                    Leaf(b)
                    Leaf(a)
                } else {
                    Leaf(a)
                    Leaf(b)
                }
            }
        }
    }
}

@Test @MainActor
func test_conditionalWrapper_createsAndDisposesWrapperWithoutAffectingLeaves() throws {
    let a = makeFixedNode(width: 50, height: 30)
    let b = makeFixedNode(width: 60, height: 40)
    let owner = DynamicStructureNode(a: a, b: b)

    let idA = a.id
    let idB = b.id

    // 1. Direct children (wrapInContainer = false)
    #expect(owner.resolveArrangement())
    #expect(owner.subnodes.map { $0.id } == [idA, idB])
    #expect(a.supernode === owner)
    #expect(b.supernode === owner)

    // 2. Wrapped in subcontainer (wrapInContainer = true)
    owner.wrapInContainer = true
    #expect(owner.resolveArrangement())
    #expect(owner.subnodes.count == 1)
    let wrapper = owner.subnodes[0]
    #expect(wrapper !== owner)
    #expect(wrapper.subnodes.map { $0.id } == [idA, idB])
    #expect(a.supernode === wrapper)
    #expect(b.supernode === wrapper)
    #expect(a.id == idA)
    #expect(b.id == idB)

    // 3. Remove container again (wrapInContainer = false)
    owner.wrapInContainer = false
    #expect(owner.resolveArrangement())
    #expect(owner.subnodes.map { $0.id } == [idA, idB])
    #expect(a.supernode === owner)
    #expect(b.supernode === owner)
    #expect(wrapper.isDisposed == true)
    #expect(a.isDisposed == false)
    #expect(b.isDisposed == false)
    #expect(a.id == idA)
    #expect(b.id == idB)
}

@Test @MainActor
func test_leafReordering_preservesNodeIdentityAndUpdatesGeometry() throws {
    let a = makeFixedNode(width: 50, height: 30)
    let b = makeFixedNode(width: 60, height: 40)
    let owner = DynamicStructureNode(a: a, b: b)
    owner.style.width = .points(300)
    owner.style.height = .points(300)

    let idA = a.id
    let idB = b.id

    // 1. Normal order [a, b]
    #expect(owner.resolveArrangement())
    try layoutTree(owner, width: 300, height: 300)
    let yA1 = a.calculatedFrame?.origin.y ?? 0
    let yB1 = b.calculatedFrame?.origin.y ?? 0
    #expect(yA1 < yB1)  // a is placed above b in column

    // 2. Reversed order [b, a]
    owner.isReversed = true
    #expect(owner.resolveArrangement())
    try layoutTree(owner, width: 300, height: 300)

    #expect(a.id == idA)
    #expect(b.id == idB)
    let yA2 = a.calculatedFrame?.origin.y ?? 0
    let yB2 = b.calculatedFrame?.origin.y ?? 0
    #expect(yB2 < yA2)  // b is placed above a in column
    #expect(yB2 == yA1)  // b took a's top position
}
