import LayoutCore
import StateCore
import Testing

@testable import Nodes

// Hosts are laid out explicitly with `layoutIfNeeded()`, which also flushes state updates,
// so every test is synchronous and deterministic.

/// A leaf of a fixed content size that can change.
@MainActor
private final class Box: Node {
    var contentSize: LayoutSize {
        didSet { setNeedsLayout() }
    }

    init(_ width: Double, _ height: Double) {
        contentSize = LayoutSize(width: width, height: height)
    }

    override var layoutContent: LeafContent? { .size(contentSize) }
}

@MainActor
private final class Card: Node {
    let avatar = Box(40, 40)
    let title = Box(100, 20)
    let follow = Box(60, 30)
    let showsFollow = State(true)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            avatar
            title.flex(grow: 1)
            if showsFollow.value { follow }
        }
        .alignItems(.center)
        .gap(10)
        .padding(10)
    }
}

@MainActor
private final class Screen: Node {
    let card = Card()

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { card }
            .padding(20)
    }
}

@MainActor
private func host(_ root: Node, width: Double = 400, height: Double = 300) -> NodeHost {
    let host = NodeHost(root: root, size: LayoutSize(width: width, height: height))
    host.layoutIfNeeded()
    return host
}

@Test @MainActor
func framesAreInTheCoordinatesOfTheSupernode() {
    let screen = Screen()
    let host = host(screen)

    #expect(screen.frame == LayoutRect(x: 0, y: 0, width: 400, height: 300))
    #expect(screen.card.frame == LayoutRect(x: 20, y: 20, width: 360, height: 60))
    #expect(screen.card.avatar.frame == LayoutRect(x: 10, y: 10, width: 40, height: 40))
    #expect(screen.card.title.frame == LayoutRect(x: 60, y: 20, width: 220, height: 20))
    #expect(screen.card.follow.frame == LayoutRect(x: 290, y: 15, width: 60, height: 30))
    host.detach()
}

@Test @MainActor
func theWholeTreeIsLaidOutInOnePass() {
    let screen = Screen()
    let host = host(screen)

    #expect(host.passes == 1)
    host.detach()
}

@Test @MainActor
func subnodesAreTheNodesTheLayoutMentions() {
    let screen = Screen()
    let host = host(screen)
    let card = screen.card

    #expect(screen.subnodes.map(\.id) == [card.id])
    #expect(card.subnodes.map(\.id) == [card.avatar.id, card.title.id, card.follow.id])
    #expect(card.title.supernode === card)
    #expect(card.supernode === screen)
    #expect(card.title.host === host)
    host.detach()
}

@Test @MainActor
func stateReadInTheLayoutLaysTheTreeOutAgain() {
    let screen = Screen()
    let host = host(screen)
    let card = screen.card
    let follow = card.follow
    let followID = follow.id

    card.showsFollow.value = false
    host.layoutIfNeeded()

    #expect(host.passes == 2)
    #expect(!follow.isMounted)
    #expect(follow.supernode == nil)
    #expect(card.subnodes.map(\.id) == [card.avatar.id, card.title.id])
    #expect(card.title.frame.size.width == 290)

    card.showsFollow.value = true
    host.layoutIfNeeded()

    #expect(card.follow === follow)
    #expect(card.follow.id == followID)
    #expect(follow.isMounted)
    host.detach()
}

@MainActor
private final class Greeting: Node {
    let label = Box(0, 20)
    let name: State<String>
    var updates = 0

    init(name: State<String>) {
        self.name = name
    }

    override func update() {
        updates += 1
        label.contentSize = LayoutSize(width: Double(name.value.count) * 10, height: 20)
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) { label }
    }
}

@Test @MainActor
func updateRunsBeforeTheFirstLayoutAndAfterItsStateChanges() {
    let name = State("Ann")
    let greeting = Greeting(name: name)
    let host = host(greeting)

    #expect(greeting.updates == 1)
    #expect(host.passes == 1)
    #expect(greeting.label.frame.size.width == 30)

    name.value = "Annabel"
    host.layoutIfNeeded()

    #expect(greeting.updates == 2)
    #expect(host.passes == 2)
    #expect(greeting.label.frame.size.width == 70)
    host.detach()
}

@Test @MainActor
func theAdapterIsToldOnceUntilItLaysOut() {
    let screen = Screen()
    let host = host(screen)
    var requests = 0
    host.onNeedsLayout = { requests += 1 }

    screen.card.showsFollow.value = false
    screen.card.title.contentSize = LayoutSize(width: 120, height: 20)
    StateUpdates.flush()
    host.size = LayoutSize(width: 500, height: 300)

    #expect(requests == 1)
    host.layoutIfNeeded()
    screen.card.title.contentSize = LayoutSize(width: 130, height: 20)

    #expect(requests == 2)
    host.detach()
}

@Test @MainActor
func unmountedNodesNoLongerUpdate() {
    let name = State("Ann")
    let greeting = Greeting(name: name)
    let showsGreeting = State(true)
    let root = Switch(child: greeting, isOn: showsGreeting)
    let host = host(root)

    showsGreeting.value = false
    host.layoutIfNeeded()
    name.value = "Bob"
    host.layoutIfNeeded()

    #expect(!greeting.isMounted)
    #expect(greeting.updates == 1)
    host.detach()
}

@MainActor
private final class Switch: Node {
    let child: Node
    let isOn: State<Bool>

    init(child: Node, isOn: State<Bool>) {
        self.child = child
        self.isOn = isOn
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer {
            if isOn.value { child }
        }
    }
}

@MainActor
private final class Adaptive: Node {
    let avatar = Box(40, 40)
    let text = Box(100, 20)

    override func layoutSpec() -> LayoutSpec? {
        Breakpoint(from: 300) {
            FlexContainer(.row) {
                avatar; text
            }
        } otherwise: {
            FlexContainer(.column) {
                avatar; text
            }
        }
    }
}

@Test @MainActor
func aNodeInBothBranchesOfABreakpointIsMountedOnce() {
    let adaptive = Adaptive()
    let host = host(adaptive, width: 400)

    #expect(adaptive.subnodes.map(\.id) == [adaptive.avatar.id, adaptive.text.id])
    #expect(adaptive.text.frame.origin.x == 40)

    host.size = LayoutSize(width: 200, height: 300)
    host.layoutIfNeeded()

    #expect(adaptive.subnodes.map(\.id) == [adaptive.avatar.id, adaptive.text.id])
    #expect(adaptive.text.frame.origin == LayoutPoint(x: 0, y: 40))
    host.detach()
}

@Test @MainActor
func detachingUnmountsTheTree() {
    let screen = Screen()
    let host = host(screen)

    host.detach()

    #expect(!screen.isMounted)
    #expect(!screen.card.isMounted)
    #expect(screen.card.title.host == nil)
}

@Test @MainActor
func anAppearanceChangeAsksForDrawingNotForLayout() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()
    var renders = 0
    var layouts = 0
    host.onNeedsRender = { renders += 1 }
    host.onNeedsLayout = { layouts += 1 }

    screen.card.appearance.background = .white
    screen.card.appearance.cornerRadius = 12

    #expect(renders == 1)
    #expect(layouts == 0)
    #expect(host.needsRender)
    host.detach()
}

@Test @MainActor
func theHostMeasuresItsTree() {
    let screen = Screen()
    let host = NodeHost(root: screen, size: LayoutSize(width: 0, height: 0))

    #expect(host.fittingSize(width: .definite(400)) == LayoutSize(width: 280, height: 100))
    #expect(host.fittingSize(width: .maxContent) == LayoutSize(width: 280, height: 100))
    host.detach()
}

// MARK: - Taps

@MainActor
private final class Tappable: Node {
    let icon = Box(20, 20)
    var taps = 0
    var presses: [Bool] = []

    override init() {
        super.init()
        onTap = { [unowned self] in taps += 1 }
    }

    override func pressChanged(_ isPressed: Bool) {
        presses.append(isPressed)
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer { icon }.padding(10)
    }
}

@MainActor
private final class Toolbar: Node {
    let first = Tappable()
    let second = Tappable()
    let plain = Box(40, 40)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            first; second; plain
        }
        .alignItems(.start)
    }
}

@Test @MainActor
func hitTestingFindsTheDeepestNodeUnderThePoint() {
    let toolbar = Toolbar()
    let host = host(toolbar)

    #expect(toolbar.hitTest(LayoutPoint(x: 15, y: 15)) === toolbar.first.icon)
    #expect(toolbar.hitTest(LayoutPoint(x: 42, y: 2)) === toolbar.second)
    #expect(toolbar.hitTest(LayoutPoint(x: 90, y: 30)) === toolbar.plain)
    #expect(toolbar.hitTest(LayoutPoint(x: 300, y: 250)) === toolbar)
    #expect(toolbar.hitTest(LayoutPoint(x: 500, y: 250)) == nil)
    #expect(toolbar.hitTest(LayoutPoint(x: -1, y: 0)) == nil)
    host.detach()
}

@Test @MainActor
func aTapGoesToTheNearestNodeWithATapAction() {
    let toolbar = Toolbar()
    let host = host(toolbar)

    #expect(host.pointerDown(at: LayoutPoint(x: 15, y: 15)))
    host.pointerUp(at: LayoutPoint(x: 16, y: 16))

    #expect(toolbar.first.taps == 1)
    #expect(toolbar.first.presses == [true, false])
    #expect(toolbar.second.taps == 0)
    host.detach()
}

@Test @MainActor
func releasingOutsideThePressedNodeTapsNothing() {
    let toolbar = Toolbar()
    let host = host(toolbar)

    host.pointerDown(at: LayoutPoint(x: 15, y: 15))
    host.pointerUp(at: LayoutPoint(x: 55, y: 15))

    #expect(toolbar.first.taps == 0)
    #expect(toolbar.second.taps == 0)
    #expect(toolbar.first.presses == [true, false])
    host.detach()
}

@Test @MainActor
func aPressWithNothingTappableIsPassedOn() {
    let toolbar = Toolbar()
    let host = host(toolbar)

    #expect(!host.pointerDown(at: LayoutPoint(x: 90, y: 30)))
    host.detach()
}

@Test @MainActor
func hiddenAndCancelledNodesAreNotTapped() {
    let toolbar = Toolbar()
    let host = host(toolbar)
    toolbar.second.appearance.opacity = 0

    #expect(toolbar.hitTest(LayoutPoint(x: 45, y: 15)) === toolbar)
    host.pointerDown(at: LayoutPoint(x: 15, y: 15))
    host.pointerCancelled()
    host.pointerUp(at: LayoutPoint(x: 15, y: 15))

    #expect(toolbar.first.taps == 0)
    host.detach()
}

// MARK: - Node cache

@MainActor
private final class Row: Node {
    let key: Int

    init(key: Int) {
        self.key = key
    }

    override var layoutContent: LeafContent? { .size(width: 100, height: 20) }
}

@MainActor
private final class List: Node {
    let keys: State<[Int]>
    let rows = NodeCache<Int, Row> { Row(key: $0) }

    init(keys: [Int]) {
        self.keys = State(keys)
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for key in keys.value { rows[key] }
        }
    }
}

@Test @MainActor
func aCachedNodeKeepsItsIdentityAcrossReorders() {
    let list = List(keys: [1, 2, 3])
    let host = host(list)
    let second = list.rows[2]

    list.keys.value = [3, 2, 1]
    host.layoutIfNeeded()

    #expect(list.rows[2] === second)
    #expect(list.subnodes.map { ($0 as? Row)?.key } == [3, 2, 1])
    #expect(second.frame.origin.y == 20)
    host.detach()
}

@Test @MainActor
func nodesNoLongerAskedForAreReleasedAtTheNextPass() {
    let list = List(keys: [1, 2, 3])
    let host = host(list)
    weak var removed = list.rows[3]

    list.keys.value = [1, 2]
    host.layoutIfNeeded()
    #expect(list.rows.count == 3)

    list.keys.value = [2, 1]
    host.layoutIfNeeded()

    #expect(list.rows.count == 2)
    #expect(removed == nil)
    host.detach()
}

// MARK: - Background solving

@Test @MainActor
func aBackgroundSolveKeepsTheOldFramesUntilTheNewOnesArrive() async {
    let screen = Screen()
    let host = host(screen)
    host.solvesInBackground = true
    var renders = 0
    host.onNeedsRender = { renders += 1 }
    host.didRender()

    screen.card.showsFollow.value = false
    host.layoutIfNeeded()

    #expect(screen.card.title.frame.size.width == 220)
    await host.layoutFinished()
    #expect(screen.card.title.frame.size.width == 290)
    #expect(host.passes == 2)
    #expect(renders == 1)
    host.detach()
}

@Test @MainActor
func anOvertakenSolveIsDropped() async {
    let screen = Screen()
    let host = host(screen)
    host.solvesInBackground = true

    screen.card.showsFollow.value = false
    host.layoutIfNeeded()
    screen.card.showsFollow.value = true
    screen.card.title.contentSize = LayoutSize(width: 50, height: 20)
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(screen.card.follow.isMounted)
    #expect(screen.card.title.frame.size.width == 220)
    host.detach()
}

@MainActor
private final class Level: Node {
    let leaf = Box(6, 3)
    let next: Level?

    init(depth: Int) {
        next = depth > 0 ? Level(depth: depth - 1) : nil
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            leaf
            if let next { next }
        }
        .padding(1)
    }

    var deepest: Level { next?.deepest ?? self }
}

@Test @MainActor
func aDeepTreeIsSolvedOnAThreadWithRoomForIt() async {
    let root = Level(depth: 200)
    let host = host(root, width: 800, height: 3000)
    host.solvesInBackground = true

    root.deepest.leaf.contentSize = LayoutSize(width: 6, height: 7)
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.passes == 2)
    #expect(root.deepest.leaf.frame.size.height == 7)
    host.detach()
}

private struct MainThreadOnly: ContentMeasurer {
    var requiresMainThread: Bool { true }
    func minContentWidth() -> Double { 30 }
    func maxContentWidth() -> Double { 30 }
    func height(forWidth width: Double) -> Double { 30 }
}

@MainActor
private final class ViewLike: Node {
    override var layoutContent: LeafContent? { .measured(MainThreadOnly()) }
}

@MainActor
private final class Holder: Node {
    let view = ViewLike()
    let width = State(100.0)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer { view }.width(.points(width.value))
    }
}

@Test @MainActor
func contentMeasuredOnlyOnTheMainThreadIsSolvedThere() {
    let holder = Holder()
    let host = host(holder)
    host.solvesInBackground = true

    holder.width.value = 200
    host.layoutIfNeeded()

    #expect(host.passes == 2)
    host.detach()
}
