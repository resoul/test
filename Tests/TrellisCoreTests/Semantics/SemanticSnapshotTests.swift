import Foundation
import Testing

@testable import TrellisCore

// A03 — metadata on Node, visible bounds (D46) and the committed semantic snapshot (D36).
// Geometry cases reuse docs/validation/h01-contract.md §1 trees where they apply.

@MainActor
private func commit(_ root: Node, _ frames: [(Node, LayoutFrame)], bounds: LayoutFrame) throws
    -> HitTestSnapshot
{
    let result = LayoutResult(
        placements: frames.map { LayoutPlacement(identity: $0.0.id, frame: $0.1) },
        treeIdentity: root.id
    )
    #expect(root.applyLayoutResult(result))
    return try #require(HitTestSnapshot(root: root, mountEpoch: 1, bounds: bounds))
}

private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: w, height: h)
}

// MARK: - Metadata on Node (D41)

@Test @MainActor
func a03_focusAndAccessibilityAreNoOpOnEqualValueAndPingSemanticsOnly() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    root.consumePendingInvalidation()
    var pings: [DirtyReasons] = []
    root.onInvalidate = { _, reasons in pings.append(reasons) }
    let geometryBefore = root.geometryRevision

    child.focus = FocusProperties()  // equal to the default
    child.accessibility = AccessibilityProperties()
    #expect(child.semanticsRevision == 0)
    #expect(pings.isEmpty)
    #expect(root.consumePendingInvalidation() == nil)

    child.focus.isFocusable = true
    #expect(child.semanticsRevision == 1)
    #expect(pings == [.semantics])
    child.accessibility.label = "Card"
    #expect(child.semanticsRevision == 2)
    #expect(pings.count == 1)  // coalesced into the same pending window
    let pending = root.consumePendingInvalidation()
    #expect(pending?.reasons == .semantics)
    #expect(pending?.origin === child)
    // No layout and no appearance work: ancestor geometry did not move.
    #expect(root.geometryRevision == geometryBefore)
    #expect(child.geometryRevision == 0)
    #expect(child.appearanceRevision == 0)
}

@Test @MainActor
func a03_sortPriorityNormalizesNonFinite() {
    var properties = AccessibilityProperties(sortPriority: .nan)
    #expect(properties.sortPriority == 0)
    properties.sortPriority = .infinity
    #expect(properties.sortPriority == 0)
    properties.sortPriority = 3
    #expect(properties.sortPriority == 3)
}

@Test @MainActor
func a03_controlIsEnabledIsTheSingleSourceAndClearsPress() {
    let root = Node()
    let control = ControlNode()
    root.addSubnode(control)
    #expect(control.focus.isFocusable)
    #expect(control.isEnabledForSemantics)
    #expect(control.isActivatable)
    #expect(!root.isActivatable)
    root.consumePendingInvalidation()
    var pings: [DirtyReasons] = []
    root.onInvalidate = { _, reasons in pings.append(reasons) }

    let revisionBefore = control.semanticsRevision  // init already opted into focus
    control.isEnabled = true  // no-op
    #expect(pings.isEmpty)
    control.isEnabled = false
    #expect(!control.isEnabledForSemantics)
    #expect(control.semanticsRevision == revisionBefore + 1)
    #expect(pings.count == 1)
    #expect(root.consumePendingInvalidation()?.reasons == [.semantics, .appearance])
}

// MARK: - Visible bounds (D46)

@Test @MainActor
func a03_visibleBoundsFollowsRotationClipOpacityAndZeroSize() throws {
    let root = Node()
    let rotated = Node()
    let clipper = Node()
    let clipped = Node()
    let outside = Node()
    let zero = Node()
    let ghost = Node()
    let ghostChild = Node()
    let offHost = Node()
    for node in [rotated, clipper, zero, ghost, offHost] { root.addSubnode(node) }
    clipper.addSubnode(clipped)
    clipper.addSubnode(outside)
    ghost.addSubnode(ghostChild)
    rotated.style.visual = LayoutVisualProperties(
        transform: LayoutTransform(rotationRadians: .pi / 2)
    )
    clipper.style.visual = LayoutVisualProperties(overflow: .hidden)
    ghost.style.visual = LayoutVisualProperties(opacity: 0)
    let snapshot = try commit(
        root,
        [
            (root, frame(0, 0, 400, 400)),
            (rotated, frame(110, 120, 100, 50)),  // h01 §1 #20
            (clipper, frame(0, 0, 100, 100)),
            (clipped, frame(50, 50, 100, 100)),  // h01 §1 #17
            (outside, frame(150, 150, 50, 50)),  // h01 §1 #16
            (zero, frame(10, 10, 0, 0)),
            (ghost, frame(200, 200, 100, 100)),
            (ghostChild, frame(210, 210, 20, 20)),
            (offHost, frame(380, 380, 100, 100)),
        ],
        bounds: frame(0, 0, 400, 400)
    )

    #expect(snapshot.visibleBounds(of: root.id) == frame(0, 0, 400, 400))
    // Rotated by π/2 around (160, 145): the image spans x ∈ [135, 185], y ∈ [95, 195].
    #expect(snapshot.visibleBounds(of: rotated.id) == frame(135, 95, 50, 100))
    #expect(snapshot.visibleBounds(of: clipped.id) == frame(50, 50, 50, 50))
    #expect(snapshot.visibleBounds(of: outside.id) == nil)
    #expect(snapshot.visibleBounds(of: zero.id) == nil)
    #expect(snapshot.visibleBounds(of: ghost.id) == nil)
    #expect(snapshot.visibleBounds(of: ghostChild.id) == nil)
    // Host bounds clip what the root does not: only the top-left 20×20 corner is on screen.
    #expect(snapshot.visibleBounds(of: offHost.id) == frame(380, 380, 20, 20))
    #expect(snapshot.visibleBounds(of: NodeID(rawValue: 999_999)) == nil)
}

@Test @MainActor
func a03_visibleBoundsComposesNestedTransformThenClip() throws {
    // h01 §1 #23/#25: a translated parent moves its child; a clipping parent's clip applies
    // in the parent's local space before the parent's own transform.
    let root = Node()
    let mover = Node()
    let moved = Node()
    let diamond = Node()
    let big = Node()
    root.addSubnode(mover)
    mover.addSubnode(moved)
    root.addSubnode(diamond)
    diamond.addSubnode(big)
    mover.style.visual = LayoutVisualProperties(transform: LayoutTransform(translationX: 50))
    diamond.style.visual = LayoutVisualProperties(
        overflow: .hidden,
        transform: LayoutTransform(rotationRadians: .pi / 4)
    )
    let snapshot = try commit(
        root,
        [
            (root, frame(0, 0, 400, 400)),
            (mover, frame(100, 100, 200, 100)),
            (moved, frame(100, 100, 50, 50)),
            (diamond, frame(100, 100, 100, 100)),
            (big, frame(0, 0, 400, 400)),
        ],
        bounds: frame(0, 0, 400, 400)
    )

    #expect(snapshot.visibleBounds(of: moved.id) == frame(150, 100, 50, 50))
    // `big` is cut to the diamond's 100×100 local box, then that box is rotated 45° around
    // (150, 150): a square of side 100√2 ≈ 141.42 centred there.
    let visible = try #require(snapshot.visibleBounds(of: big.id))
    let side = 100 * 2.0.squareRoot()
    #expect(abs(visible.width - side) < 1e-9)
    #expect(abs(visible.height - side) < 1e-9)
    #expect(abs(visible.origin.x - (150 - side / 2)) < 1e-9)
}

// MARK: - Semantic snapshot (D36)

@Test @MainActor
func a03_snapshotPublishesCommittedIdentitiesInPreorderWithMetadata() throws {
    let root = Node()
    let a = ControlNode()
    let wrapper = Node()
    let b = ControlNode()
    let c = Node()
    root.addSubnode(a)
    root.addSubnode(wrapper)
    wrapper.addSubnode(b)
    wrapper.addSubnode(c)
    wrapper.isArrangementWrapper = true
    wrapper.focus.isFocusable = true
    a.accessibility = AccessibilityProperties(isElement: true, label: "A")
    b.isEnabled = false
    c.focus = FocusProperties(isFocusable: true, priority: 3)
    let geometry = try commit(
        root,
        [
            (root, frame(0, 0, 400, 400)),
            (a, frame(0, 0, 80, 80)),
            (wrapper, frame(100, 0, 200, 80)),
            (b, frame(100, 0, 80, 80)),
            (c, frame(200, 0, 80, 80)),
        ],
        bounds: frame(0, 0, 400, 400)
    )

    let snapshot = SemanticSnapshot(
        geometry: geometry,
        root: root,
        geometryGeneration: 7,
        revision: 3
    )
    #expect(snapshot.order == [root.id, a.id, wrapper.id, b.id, c.id])
    #expect(snapshot.count == 5)
    #expect(snapshot.geometryGeneration == 7)
    #expect(snapshot.revision == 3)
    #expect(snapshot.mountEpoch == 1)
    #expect(snapshot.record(for: c.id)?.traversalIndex == 4)
    #expect(snapshot.record(for: a.id)?.accessibility.label == "A")
    #expect(snapshot.record(for: a.id)?.isActivatable == true)
    #expect(snapshot.record(for: a.id)?.isFocusCandidate == true)
    #expect(snapshot.record(for: b.id)?.isEnabled == false)
    #expect(snapshot.record(for: b.id)?.isFocusCandidate == false)
    #expect(snapshot.record(for: wrapper.id)?.isArrangementWrapper == true)
    #expect(snapshot.record(for: wrapper.id)?.isFocusCandidate == false)
    #expect(snapshot.record(for: c.id)?.focus.priority == 3)
    #expect(snapshot.record(for: c.id)?.visibleBounds == frame(200, 0, 80, 80))
    #expect(snapshot.focusCandidates(scope: nil) == [a.id, c.id])
    #expect(snapshot.focusCandidates(scope: wrapper.id) == [c.id])
    #expect(snapshot.focusCandidates(scope: NodeID(rawValue: 424_242)) == [])
    #expect(snapshot.isDescendantOrSelf(c.id, of: wrapper.id))
    #expect(snapshot.isDescendantOrSelf(wrapper.id, of: wrapper.id))
    #expect(!snapshot.isDescendantOrSelf(a.id, of: wrapper.id))
}

@Test @MainActor
func a03_snapshotNeverPublishesUncommittedNodesAndKeepsRemovedOnesFromPrevious() throws {
    let root = Node()
    let a = ControlNode()
    root.addSubnode(a)
    a.accessibility.label = "A"
    let geometry = try commit(
        root,
        [(root, frame(0, 0, 400, 400)), (a, frame(0, 0, 80, 80))],
        bounds: frame(0, 0, 400, 400)
    )
    let first = SemanticSnapshot(geometry: geometry, root: root, geometryGeneration: 1, revision: 1)

    // Live mutation between commits: a new child with metadata but no frame, and `a` gone.
    let late = ControlNode()
    late.accessibility.label = "Late"
    root.addSubnode(late)
    a.removeFromSupernode()

    let republished = SemanticSnapshot(
        geometry: geometry,
        root: root,
        geometryGeneration: 1,
        revision: 2,
        previous: first
    )
    #expect(republished.record(for: late.id) == nil)
    #expect(republished.order == [root.id, a.id])
    // Still on screen, so still described — with the metadata it was last published with.
    #expect(republished.record(for: a.id)?.accessibility.label == "A")
    #expect(republished.hasSameContent(as: first))

    // Without a previous snapshot of the same mount the removed node falls back to defaults.
    let cold = SemanticSnapshot(geometry: geometry, root: root, geometryGeneration: 1, revision: 3)
    #expect(cold.record(for: a.id)?.accessibility.label == nil)
    #expect(!cold.hasSameContent(as: first))
}
