import LayoutCore
import Testing

@testable import Nodes

@Test
func aNodeFadesByDefault() {
    #expect(Transition.opacity.insertion == Transition.Effect(opacity: 0))
    #expect(Transition.opacity.removal == Transition.Effect(opacity: 0))
    #expect(Transition.identity.insertion.isIdentity)
    #expect(!Transition.opacity.insertion.changesGeometry)
}

@Test
func movesGoTowardTheirEdgeByTheNodesSize() {
    #expect(Transition.move(edge: .top).insertion.sizeOffset == LayoutPoint(x: 0, y: -1))
    #expect(Transition.move(edge: .trailing).removal.sizeOffset == LayoutPoint(x: 1, y: 0))
    // In from the leading side, out toward the trailing one.
    #expect(Transition.slide.insertion.sizeOffset == LayoutPoint(x: -1, y: 0))
    #expect(Transition.slide.removal.sizeOffset == LayoutPoint(x: 1, y: 0))
    // A push comes from its edge and goes on to the one across, fading.
    let push = Transition.push(from: .bottom)
    #expect(push.insertion == Transition.Effect(opacity: 0, sizeOffset: LayoutPoint(x: 0, y: 1)))
    #expect(push.removal == Transition.Effect(opacity: 0, sizeOffset: LayoutPoint(x: 0, y: -1)))
}

@Test
func combinedEffectsMultiplyAndAddUp() {
    let both = Transition.scale(0.5, anchor: .top)
        .combined(with: .opacity)
        .combined(with: .offset(x: 10, y: 4))
        .combined(with: .offset(x: 2))
        .combined(with: .rotation(degrees: 30))

    #expect(both.insertion.opacity == 0)
    #expect(both.insertion.scaleX == 0.5)
    #expect(both.insertion.offset == LayoutPoint(x: 12, y: 4))
    #expect(both.insertion.rotation == 30)
    // The first anchor that is not the center.
    #expect(both.insertion.anchor == .top)
    #expect(
        Transition.opacity.combined(with: .scale(0.5, anchor: .bottom)).insertion.anchor == .bottom
    )
}

@Test
func anAsymmetricTransitionTakesEachWayFromItsOwn() {
    let transition = Transition.asymmetric(
        insertion: .move(edge: .bottom).animation(.spring()),
        removal: .opacity
    )

    #expect(transition.insertion.sizeOffset == LayoutPoint(x: 0, y: 1))
    #expect(transition.removal == Transition.Effect(opacity: 0))
    #expect(transition.animation == .spring())
}

@Test
func aFlipTurnsTheNodeEdgeOn() {
    #expect(Transition.flip().insertion.flipY == 90)
    #expect(Transition.flip(.horizontal).removal.flipX == 90)
    #expect(Transition.pop.animation != nil)
}

@Test @MainActor
func aNodeKeepsTheTransitionItIsPlacedWith() {
    let node = Node()
    #expect(node.transition == .opacity)

    let returned = node.transition(.scale)

    #expect(returned === node)
    #expect(node.transition == .scale)
}
