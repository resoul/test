import Foundation
import Testing

@testable import TrellisCore

// A06 — the semantic tree: four children policies on one fixture with visible children
// (defect #35), reading order, modal boundary, transparency of wrappers and clipped parents.

private func frame(_ x: Double, _ y: Double, _ w: Double = 80, _ h: Double = 40) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: w, height: h)
}

/// `R > card > [title, subtitle, button]` — a card with two text leaves and a control.
@MainActor
private final class Fixture {
    let root = Node()
    let card = Node()
    let title = Node()
    let subtitle = Node()
    let button = ControlNode()
    var frames: [NodeID: LayoutFrame] = [:]
    var epoch: UInt64 = 1

    init() {
        root.addSubnode(card)
        card.addSubnode(title)
        card.addSubnode(subtitle)
        card.addSubnode(button)
        title.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Title",
            role: .header
        )
        subtitle.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Subtitle",
            role: .text
        )
        button.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Buy",
            hint: "Adds to cart"
        )
        frames = [
            root.id: frame(0, 0, 400, 400), card.id: frame(10, 10, 300, 200),
            title.id: frame(20, 20), subtitle.id: frame(20, 70), button.id: frame(20, 120),
        ]
    }

    func snapshot() -> SemanticSnapshot? {
        var placements: [LayoutPlacement] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if let frame = frames[node.id] {
                placements.append(LayoutPlacement(identity: node.id, frame: frame))
            }
            stack.append(contentsOf: node.subnodes)
        }
        #expect(root.applyLayoutResult(LayoutResult(placements: placements, treeIdentity: root.id)))
        guard
            let geometry = HitTestSnapshot(
                root: root,
                mountEpoch: epoch,
                bounds: frame(0, 0, 400, 400)
            )
        else { return nil }
        return SemanticSnapshot(geometry: geometry, root: root, geometryGeneration: 1, revision: 1)
    }

    func tree(scope: NodeID? = nil) -> AccessibilityTree? {
        snapshot().map { AccessibilityTree.build(from: $0, scope: scope) }
    }
}

@Test @MainActor
func a06_containOnANonElementCardIsTransparent() throws {
    let f = Fixture()
    let tree = try #require(f.tree())
    // Root and card are neither elements nor labelled: three top-level leaves.
    #expect(tree.elements.map(\.id) == [f.title.id, f.subtitle.id, f.button.id])
    #expect(tree.readingOrder == [f.title.id, f.subtitle.id, f.button.id])
    #expect(tree.element(for: f.card.id) == nil)
    #expect(tree.element(for: f.root.id) == nil)
    let button = try #require(tree.element(for: f.button.id))
    #expect(button.isElement)
    #expect(button.role == .button)  // control without an authored role
    #expect(button.actions == [.activate])
    #expect(button.hint == "Adds to cart")
    #expect(button.frame == frame(20, 120))
    #expect(tree.element(for: f.title.id)?.role == .header)
    #expect(tree.count == 3)
}

@Test @MainActor
func a06_containOnAnElementCardWithChildrenIsALabelledGroup() throws {
    let f = Fixture()
    f.card.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Product card",
        value: "unused"
    )
    let tree = try #require(f.tree())
    #expect(tree.elements.count == 1)
    let card = try #require(tree.element(for: f.card.id))
    #expect(!card.isElement)  // A01 §3.2: a group with a label, not a second leaf
    #expect(card.label == "Product card")
    #expect(card.value == nil)
    #expect(card.children.map(\.id) == [f.title.id, f.subtitle.id, f.button.id])
    #expect(tree.readingOrder == [f.title.id, f.subtitle.id, f.button.id])
    #expect(card.frame == frame(10, 10, 300, 200))

    // Without element descendants the same card is a leaf.
    f.title.accessibility.childrenPolicy = .hide
    f.subtitle.accessibility.childrenPolicy = .hide
    f.button.accessibility.childrenPolicy = .hide
    let leafTree = try #require(f.tree())
    #expect(leafTree.element(for: f.card.id)?.isElement == true)
    #expect(leafTree.readingOrder == [f.card.id])
}

@Test @MainActor
func a06_combineIsOneLeafWithJoinedLabelsAndNoChildActions() throws {
    let f = Fixture()
    f.card.accessibility = AccessibilityProperties(childrenPolicy: .combine)
    let tree = try #require(f.tree())
    let card = try #require(tree.element(for: f.card.id))
    #expect(card.isElement)
    #expect(card.label == "Title, Subtitle, Buy")
    #expect(card.children.isEmpty)
    #expect(card.actions.isEmpty)  // the button's activate is not merged (D42)
    #expect(card.role == nil)
    #expect(tree.readingOrder == [f.card.id])
    #expect(tree.element(for: f.button.id) == nil)

    // An explicit label wins; the node's own hint/role/actions come through.
    f.card.accessibility = AccessibilityProperties(
        label: "Card",
        hint: "Opens",
        role: .link,
        childrenPolicy: .combine,
        customActions: [AccessibilityCustomAction(id: "share", name: "Share")]
    )
    let named = try #require(f.tree()?.element(for: f.card.id))
    #expect(named.label == "Card")
    #expect(named.hint == "Opens")
    #expect(named.role == .link)
    #expect(named.customActions.map(\.id) == ["share"])
}

@Test @MainActor
func a06_ignoreSelfKeepsTheContainerWithoutAnEndpoint() throws {
    let f = Fixture()
    f.card.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Ignored",
        childrenPolicy: .ignoreSelf
    )
    let tree = try #require(f.tree())
    let card = try #require(tree.element(for: f.card.id))
    #expect(!card.isElement)
    #expect(card.label == nil)
    #expect(card.children.map(\.id) == [f.title.id, f.subtitle.id, f.button.id])
    #expect(tree.readingOrder == [f.title.id, f.subtitle.id, f.button.id])
    #expect(!tree.readingOrder.contains(f.card.id))
}

@Test @MainActor
func a06_hideRemovesTheSubtreeButNotKeyboardFocus() throws {
    let f = Fixture()
    f.card.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Hidden",
        childrenPolicy: .hide
    )
    let snapshot = try #require(f.snapshot())
    let tree = AccessibilityTree.build(from: snapshot, scope: nil)
    #expect(tree.elements.isEmpty)
    #expect(tree.readingOrder.isEmpty)
    #expect(tree.count == 0)
    // The hidden button is still a focus candidate (D37).
    #expect(snapshot.focusCandidates(scope: nil) == [f.button.id])
}

@Test @MainActor
func a06_fourPoliciesOnOneFixtureGiveFourDifferentTrees() throws {
    let f = Fixture()
    f.card.accessibility = AccessibilityProperties(isElement: true, label: "Card")
    var trees: [AccessibilityTree] = []
    for policy in AccessibilityChildrenPolicy.allCases {
        f.card.accessibility.childrenPolicy = policy
        trees.append(try #require(f.tree()))
    }
    #expect(trees[0] != trees[1])
    #expect(trees[1] != trees[2])
    #expect(trees[2] != trees[3])
    #expect(trees[0] != trees[3])
    #expect(trees.map(\.readingOrder.count) == [3, 1, 3, 0])
}

@Test @MainActor
func a06_disabledControlIsReadAndPlainTextIsReadWithoutFocus() throws {
    let f = Fixture()
    f.button.isEnabled = false
    let tree = try #require(f.tree())
    let button = try #require(tree.element(for: f.button.id))
    #expect(!button.isEnabled)
    #expect(button.label == "Buy")
    #expect(button.actions == [.activate])  // listed; performing it is refused (A07)
    let title = try #require(tree.element(for: f.title.id))
    #expect(title.isEnabled)
    #expect(title.actions.isEmpty)
    // Text is never focusable and the button is disabled: no candidates at all.
    #expect(f.snapshot()?.focusCandidates(scope: nil) == [])
}

@Test @MainActor
func a06_sortPriorityOrdersSiblingsAndTiesKeepCommittedOrder() throws {
    let f = Fixture()
    f.button.accessibility.sortPriority = 10
    f.subtitle.accessibility.sortPriority = 10
    let tree = try #require(f.tree())
    #expect(tree.readingOrder == [f.subtitle.id, f.button.id, f.title.id])

    // Reordering the siblings live keeps every NodeID and follows the new committed order.
    f.card.moveSubnode(from: 2, to: 1)  // button before subtitle
    let reordered = try #require(f.tree())
    #expect(reordered.readingOrder == [f.button.id, f.subtitle.id, f.title.id])
    #expect(reordered.element(for: f.button.id)?.label == "Buy")
}

@Test @MainActor
func a06_modalScopeConfinesTheTreeAndArrangementWrappersAreTransparent() throws {
    let f = Fixture()
    let background = Node()
    background.accessibility = AccessibilityProperties(isElement: true, label: "Background")
    f.root.addSubnode(background)
    f.frames[background.id] = frame(20, 300)
    let wrapper = Node()
    wrapper.isArrangementWrapper = true
    // Ignored: a wrapper is transparent whatever it declares.
    wrapper.accessibility = AccessibilityProperties(isElement: true, label: "Wrapper")
    f.card.addSubnode(wrapper)
    let inner = Node()
    inner.accessibility = AccessibilityProperties(isElement: true, label: "Inner")
    wrapper.addSubnode(inner)
    f.frames[wrapper.id] = frame(20, 170, 200, 30)
    f.frames[inner.id] = frame(20, 170)

    let whole = try #require(f.tree())
    #expect(
        whole.readingOrder == [f.title.id, f.subtitle.id, f.button.id, inner.id, background.id]
    )
    #expect(whole.element(for: wrapper.id) == nil)

    let scoped = try #require(f.tree(scope: f.card.id))
    #expect(scoped.readingOrder == [f.title.id, f.subtitle.id, f.button.id, inner.id])
    #expect(scoped.element(for: background.id) == nil)
    #expect(scoped.scope == f.card.id)

    #expect(f.tree(scope: NodeID(rawValue: 987_654))?.count == 0)
}

@Test @MainActor
func a06_nestedPoliciesAndZeroSizedParentsDoNotHideVisibleDescendants() throws {
    let f = Fixture()
    // A zero-sized container: no visible area of its own, yet its children are on screen.
    f.frames[f.card.id] = frame(10, 10, 0, 0)
    let tree = try #require(f.tree())
    #expect(tree.readingOrder == [f.title.id, f.subtitle.id, f.button.id])

    // Nested: a labelled group card containing a combined row containing a hidden leaf.
    f.frames[f.card.id] = frame(10, 10, 300, 200)
    f.card.accessibility = AccessibilityProperties(isElement: true, label: "Card")
    let row = Node()
    row.accessibility = AccessibilityProperties(childrenPolicy: .combine)
    let price = Node()
    price.accessibility = AccessibilityProperties(isElement: true, label: "Price")
    let secret = Node()
    secret.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Secret",
        childrenPolicy: .hide
    )
    row.addSubnode(price)
    row.addSubnode(secret)
    f.card.addSubnode(row)
    f.frames[row.id] = frame(20, 170, 200, 30)
    f.frames[price.id] = frame(20, 170)
    f.frames[secret.id] = frame(120, 170)
    let nested = try #require(f.tree())
    let card = try #require(nested.element(for: f.card.id))
    #expect(card.children.map(\.id) == [f.title.id, f.subtitle.id, f.button.id, row.id])
    #expect(nested.element(for: row.id)?.label == "Price")
    #expect(nested.element(for: row.id)?.isElement == true)
    #expect(nested.element(for: secret.id) == nil)
    #expect(nested.readingOrder == [f.title.id, f.subtitle.id, f.button.id, row.id])

    // A fully clipped subtree: the card clips and the row sits outside its bounds.
    f.card.style.visual = LayoutVisualProperties(overflow: .hidden)
    f.frames[row.id] = frame(500, 500, 200, 30)
    f.frames[price.id] = frame(500, 500)
    let clipped = try #require(f.tree())
    #expect(clipped.element(for: row.id) == nil)
    #expect(clipped.readingOrder == [f.title.id, f.subtitle.id, f.button.id])
}

// T08 (D57): TextNode's automatic accessibility defaults (TextNodeAccessibilityTests.swift)
// reach the native semantic tree exactly like an author-assigned value would.

@Test @MainActor
func t08_accessibilityTreeSeesTextNodeLabelEqualToItsText() throws {
    let root = Node()
    let label = TextNode(text: "Hello, Trellis")
    root.addSubnode(label)
    let placements = [
        LayoutPlacement(identity: root.id, frame: frame(0, 0, 400, 400)),
        LayoutPlacement(identity: label.id, frame: frame(10, 10, 200, 24)),
    ]
    #expect(root.applyLayoutResult(LayoutResult(placements: placements, treeIdentity: root.id)))
    let geometry = try #require(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: frame(0, 0, 400, 400))
    )
    let snapshot = SemanticSnapshot(
        geometry: geometry,
        root: root,
        geometryGeneration: 1,
        revision: 1
    )
    let tree = AccessibilityTree.build(from: snapshot, scope: nil)

    let element = try #require(tree.element(for: label.id))
    #expect(element.isElement)
    #expect(element.label == "Hello, Trellis")
    #expect(element.role == .text)
}

@Test @MainActor
func t08_combineJoinsSeveralTextNodesIntoOneLabel() throws {
    let root = Node()
    root.accessibility = AccessibilityProperties(childrenPolicy: .combine)
    let first = TextNode(text: "Hello")
    let second = TextNode(text: "World")
    root.addSubnode(first)
    root.addSubnode(second)
    let placements = [
        LayoutPlacement(identity: root.id, frame: frame(0, 0, 400, 400)),
        LayoutPlacement(identity: first.id, frame: frame(0, 0, 100, 20)),
        LayoutPlacement(identity: second.id, frame: frame(0, 30, 100, 20)),
    ]
    #expect(root.applyLayoutResult(LayoutResult(placements: placements, treeIdentity: root.id)))
    let geometry = try #require(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: frame(0, 0, 400, 400))
    )
    let snapshot = SemanticSnapshot(
        geometry: geometry,
        root: root,
        geometryGeneration: 1,
        revision: 1
    )
    let tree = AccessibilityTree.build(from: snapshot, scope: nil)

    let combined = try #require(tree.element(for: root.id))
    #expect(combined.label == "Hello, World")
    #expect(combined.children.isEmpty)
    #expect(tree.element(for: first.id) == nil)
}
