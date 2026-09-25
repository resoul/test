import Foundation
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

    // Two hundred levels do not fit the main thread's stack budget, so even the first
    // layout went to the host's thread; the change overtook it, and one pass was applied.
    #expect(host.passes == 1)
    #expect(root.deepest.leaf.frame.size.height == 7)
    host.detach()
}

@Test @MainActor
func aNodeChangedWhileItsFirstLayoutIsSolvedIsLaidOutAgain() async {
    let screen = Screen()
    screen.card.showsFollow.value = false
    let host = host(screen)
    host.solvesInBackground = true

    // `follow` comes back in a layout solved in the background, and changes before it lands.
    screen.card.showsFollow.value = true
    host.layoutIfNeeded()
    screen.card.follow.contentSize = LayoutSize(width: 90, height: 30)
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(screen.card.follow.isMounted)
    #expect(screen.card.follow.frame.size.width == 90)
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

// MARK: - Accessibility

@MainActor
private final class Label: Node {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    override var layoutContent: LeafContent? { .size(width: 60, height: 20) }
    override var accessibilityContentLabel: String? { text }
    override var accessibilityContentTraits: AccessibilityTraits { .staticText }
}

@MainActor
private final class ProfileRow: Node {
    let avatar = Box(40, 40)
    let name = Label("Ada")
    let bio = Label("Wrote the first program")
    let badge = Badge()

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            avatar
            FlexContainer(.column) {
                name; bio
            }
            badge
        }
        .padding(10)
    }
}

@MainActor
private final class Badge: Node {
    let label = Label("Follow")
    var taps = 0

    override init() {
        super.init()
        onTap = { [unowned self] in taps += 1 }
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer { label }.padding(5)
    }
}

@Test @MainActor
func textAndTappableNodesBecomeElementsInReadingOrder() {
    let row = ProfileRow()
    let host = host(row)

    let items = host.accessibilityItems()

    #expect(items.map(\.label) == ["Ada", "Wrote the first program", "Follow"])
    #expect(items.map(\.traits) == [.staticText, .staticText, .button])
    #expect(items[0].frame == LayoutRect(x: 50, y: 10, width: 60, height: 20))
    #expect(items[2].node == row.badge.id)
    host.detach()
}

@Test @MainActor
func accessibilitySettingsOverrideWhatNodesSayByThemselves() {
    let row = ProfileRow()
    row.avatar.accessibility.label = "Portrait of Ada"
    row.avatar.accessibility.traits = .image
    row.bio.accessibility.isElement = false
    row.badge.accessibility.label = "Follow Ada"
    let host = host(row)

    let items = host.accessibilityItems()

    #expect(items.map(\.label) == ["Portrait of Ada", "Ada", "Follow Ada"])
    #expect(items[0].traits == .image)
    host.detach()
}

@Test @MainActor
func activatingAnElementTapsItsNode() {
    let row = ProfileRow()
    let host = host(row)

    #expect(host.activate(row.badge.id))
    #expect(!host.activate(row.name.id))
    #expect(row.badge.taps == 1)
    host.detach()
}

// MARK: - Animation

@Test @MainActor
func changesInsideWithAnimationAreDrawnWithIt() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    withAnimation {
        screen.card.showsFollow.value = false
    }
    host.layoutIfNeeded()

    #expect(host.renderAnimation == .default)
    host.didRender()
    #expect(host.renderAnimation == nil)
    host.detach()
}

@Test @MainActor
func changesOutsideWithAnimationAreDrawnAtOnce() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    screen.card.showsFollow.value = false
    host.layoutIfNeeded()
    screen.appearance.opacity = 0.5

    #expect(host.needsRender)
    #expect(host.renderAnimation == nil)
    host.detach()
}

@Test @MainActor
func anAppearanceChangedInsideWithAnimationIsDrawnWithIt() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    withAnimation(.linear(duration: 1)) {
        screen.card.appearance.opacity = 0.5
    }

    #expect(host.renderAnimation == .linear(duration: 1))
    host.detach()
}

@Test @MainActor
func withAnimationNilTurnsAnimationOffInside() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    withAnimation {
        withAnimation(nil) {
            screen.card.showsFollow.value = false
        }
    }
    host.layoutIfNeeded()

    #expect(host.renderAnimation == nil)
    host.detach()
}

@Test @MainActor
func aBackgroundSolveCarriesTheAnimationOfTheChangeThatAskedForIt() async {
    let screen = Screen()
    let host = host(screen)
    host.solvesInBackground = true
    host.didRender()

    withAnimation(.spring()) {
        screen.card.showsFollow.value = false
    }
    host.layoutIfNeeded()
    // Overtaken by a change without animation: the pass that replaces it still animates.
    screen.card.title.contentSize = LayoutSize(width: 50, height: 20)
    host.layoutIfNeeded()
    await host.layoutFinished()

    #expect(host.renderAnimation == .spring())
    #expect(host.passes == 2)
    host.detach()
}

@Test
func aSpringRunsUntilItComesToRest() {
    let bouncy = Animation.spring(response: 0.5, dampingRatio: 0.5)
    let calm = Animation.spring(response: 0.5, dampingRatio: 1)

    #expect(bouncy.duration > calm.duration)
    #expect(abs(calm.duration - log(1000) * 0.5 / (2 * Double.pi)) < 1e-9)
}

// MARK: - Focus

@Test @MainActor
func nodesWithATapActionAreFocusItems() {
    let row = ProfileRow()
    row.avatar.isFocusable = true
    let host = host(row)

    let items = host.focusItems()

    #expect(items.map(\.node) == [row.avatar.id, row.badge.id])
    #expect(items[0].frame == row.avatar.frame)
    host.detach()
}

@Test @MainActor
func aNodeCanBeTakenOutOfFocus() {
    let row = ProfileRow()
    row.badge.isFocusable = false
    let host = host(row)

    #expect(host.focusItems().isEmpty)
    host.detach()
}

@Test @MainActor
func focusingANodeTellsItAndAnimatesTheChange() {
    let row = ProfileRow()
    let host = host(row)
    host.didRender()

    host.focus(row.badge.id)

    #expect(host.focusedNode == row.badge.id)
    #expect(row.badge.isFocused)
    #expect(row.badge.appearance.scale == 1.1)
    #expect(host.renderAnimation == host.focusAnimation)

    host.focus(nil)

    #expect(!row.badge.isFocused)
    #expect(row.badge.appearance.scale == 1)
    host.detach()
}

@Test @MainActor
func aNodeThatCannotBeFocusedIsNotFocused() {
    let row = ProfileRow()
    let host = host(row)

    host.focus(row.name.id)

    #expect(host.focusedNode == nil)
    #expect(!row.name.isFocused)
    host.detach()
}

@Test @MainActor
func theSelectButtonTapsTheFocusedNode() {
    let row = ProfileRow()
    let host = host(row)

    #expect(!host.selectBegan())
    host.focus(row.badge.id)
    #expect(host.selectBegan())
    host.selectEnded()
    #expect(host.selectBegan())
    host.pointerCancelled()
    host.selectEnded()

    #expect(row.badge.taps == 1)
    host.detach()
}

@Test @MainActor
func aFocusedNodeThatLeavesTheTreeLosesTheFocus() {
    let card = Card()
    card.follow.isFocusable = true
    let host = host(card)
    host.focus(card.follow.id)

    card.showsFollow.value = false
    host.layoutIfNeeded()

    #expect(host.focusedNode == nil)
    #expect(!card.follow.isFocused)
    host.detach()
}

@MainActor
private final class Rows: Node {
    let first = ProfileRow()
    let second = ProfileRow()
    let plain = ProfileRow()

    override init() {
        super.init()
        first.isFocusSection = true
        second.isFocusSection = true
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            first; second; plain
        }
    }
}

@Test @MainActor
func focusSectionsListTheFocusableNodesInside() {
    let rows = Rows()
    rows.first.avatar.isFocusable = true
    let host = host(rows)

    let sections = host.focusSections()

    #expect(sections.map(\.node) == [rows.first.id, rows.second.id])
    #expect(sections[0].items == [rows.first.avatar.id, rows.first.badge.id])
    #expect(sections[1].items == [rows.second.badge.id])
    #expect(sections[1].frame == rows.second.frame)
    host.detach()
}

@Test @MainActor
func aSectionWithNothingToFocusIsLeftOut() {
    let rows = Rows()
    rows.second.badge.isFocusable = false
    let host = host(rows)

    #expect(host.focusSections().map(\.node) == [rows.first.id])
    host.detach()
}

/// Four tappable boxes in two rows of two.
@MainActor
private final class Grid: Node {
    let cells = (0..<4).map { _ in Badge() }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            FlexContainer(.row) {
                cells[0]; cells[1]
            }.gap(10)
            FlexContainer(.row) {
                cells[2]; cells[3]
            }.gap(10)
        }
        .gap(10)
        .alignItems(.start)
    }
}

@Test @MainActor
func tabMovesTheFocusInReadingOrderAndStopsAtTheEnds() {
    let grid = Grid()
    let host = host(grid)
    let ids = grid.cells.map(\.id)

    #expect(host.moveFocus(.next))
    #expect(host.focusedNode == ids[0])
    #expect(host.moveFocus(.next))
    #expect(host.moveFocus(.next))
    #expect(host.moveFocus(.next))
    #expect(host.focusedNode == ids[3])
    #expect(!host.moveFocus(.next))
    #expect(host.focusedNode == ids[3])
    #expect(host.moveFocus(.previous))
    #expect(host.focusedNode == ids[2])
    host.focus(nil)
    #expect(host.moveFocus(.previous))
    #expect(host.focusedNode == ids[3])
    host.detach()
}

@Test @MainActor
func arrowsMoveTheFocusToTheNearestNodeThatWay() {
    let grid = Grid()
    let host = host(grid)
    let ids = grid.cells.map(\.id)
    host.focus(ids[0])

    #expect(host.moveFocus(.right))
    #expect(host.focusedNode == ids[1])
    #expect(host.moveFocus(.down))
    #expect(host.focusedNode == ids[3])
    #expect(host.moveFocus(.left))
    #expect(host.focusedNode == ids[2])
    #expect(!host.moveFocus(.left))
    #expect(host.moveFocus(.up))
    #expect(host.focusedNode == ids[0])
    host.detach()
}

@Test @MainActor
func withARingTheNodeIsNotLifted() {
    let row = ProfileRow()
    let host = host(row)
    host.focusLook = .ring

    host.focus(row.badge.id)

    #expect(row.badge.isFocused)
    #expect(row.badge.appearance.scale == 1)
    host.detach()
}

@Test @MainActor
func aFocusRequestGoesToTheAdapterOrFocusesAtOnce() {
    let row = ProfileRow()
    let host = host(row)

    host.requestFocus(row.badge.id)
    #expect(host.focusedNode == row.badge.id)

    host.focus(nil)
    var requested: [NodeID] = []
    host.onFocusRequest = { requested.append($0) }
    host.requestFocus(row.badge.id)
    host.requestFocus(row.name.id)

    #expect(requested == [row.badge.id])
    #expect(host.focusedNode == nil)
    host.detach()
}

// MARK: - Reports

@MainActor
private final class Twice: Node {
    let badge = Box(10, 10)
    let repeats = State(false)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            badge
            if repeats.value { badge }
        }
    }
}

@Test @MainActor
func aNodeLaidOutTwiceRejectsThePass() {
    let root = Twice()
    let host = NodeHost(root: root, size: LayoutSize(width: 100, height: 50))
    var reports: [LayoutReport] = []
    host.onLayoutReport = { reports.append($0) }
    host.layoutIfNeeded()
    let frame = root.badge.frame

    root.repeats.value = true
    host.layoutIfNeeded()

    #expect(reports.count == 2)
    #expect(reports[0].isRejected == false)
    #expect(reports[1].isRejected)
    #expect(reports[1].duplicates == [root.badge.id])
    #expect(host.passes == 1)
    #expect(root.badge.frame == frame)
    #expect(root.subnodes.map(\.id) == [root.badge.id])
    host.detach()
}

@MainActor
private final class BranchedBox: Node {
    let item = Box(10, 10)

    override func layoutSpec() -> LayoutSpec? {
        Breakpoint(from: 100) {
            item
        } otherwise: {
            item.size(20)
        }
    }
}

@MainActor
private final class AdaptiveRow: Node {
    let branched = BranchedBox()
    let grows = State(false)

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) { branched.flex(grow: grows.value ? 1 : 0) }
    }
}

@Test @MainActor
func aBreakpointWithoutAWidthIsReported() {
    let root = AdaptiveRow()
    let host = NodeHost(root: root, size: LayoutSize(width: 300, height: 50))
    var last: LayoutReport?
    host.onLayoutReport = { last = $0 }
    host.layoutIfNeeded()

    // The row sizes `branched` to its content: there is no width to choose a branch by.
    #expect(last?.variantsWithoutWidth == [root.branched.item.id])
    #expect(last?.hasProblems == true)
    host.detach()
}

@Test @MainActor
func aTraceFollowsTheNodesAskedFor() throws {
    let screen = Screen()
    let host = NodeHost(root: screen, size: LayoutSize(width: 400, height: 300))
    var last: LayoutReport?
    host.onLayoutReport = { last = $0 }
    host.traceAreas = [.place]
    host.tracedNodes = [screen.card.id]
    host.layoutIfNeeded()

    let report = try #require(last)
    #expect(report.trace.map(\.node) == [screen.card.id])
    #expect(
        report.trace.first?.event
            == .placed(
                try #require(report.trace.first?.event.id),
                frame: LayoutRect(x: 20, y: 20, width: 360, height: 60)
            )
    )
    #expect(report.hasProblems == false)

    let lines = report.lines
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("[layout] pass host=\(host.number) gen=1 elements="))
    #expect(lines[0].hasSuffix("rejected=no stack=enough duplicates=none widthless=none"))
    #expect(
        lines[1]
            == "[layout] place host=\(host.number) gen=1 \(screen.card.id) x=20 y=20 size=360x60"
    )
    host.detach()
}

// MARK: - Stack

/// Content that can only be measured on the main thread, as a view's.
private struct MainThreadContent: ContentMeasurer {
    var requiresMainThread: Bool { true }
    func minContentWidth() -> Double { 10 }
    func maxContentWidth() -> Double { 10 }
    func height(forWidth width: Double) -> Double { 10 }
}

@MainActor
private final class MainThreadLeaf: Node {
    override var layoutContent: LeafContent? { .measured(MainThreadContent()) }
}

/// `depth` nodes, each a padded column around the next.
@MainActor
private final class Nest: Node {
    let inner: Node

    init(depth: Int, leaf: @MainActor () -> Node) {
        inner = depth > 0 ? Nest(depth: depth - 1, leaf: leaf) : leaf()
    }

    var deepest: Node { (inner as? Nest)?.deepest ?? inner }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) { inner }.padding(1)
    }
}

@Test @MainActor
func aTreeTooDeepForTheMainThreadIsSolvedOnTheHostsThread() async {
    let root = Nest(depth: 60) { Box(10, 10) }
    let host = NodeHost(root: root, size: LayoutSize(width: 300, height: 600))
    host.mainThreadStackBudget = 16 << 10
    var reports: [LayoutReport] = []
    host.onLayoutReport = { reports.append($0) }

    host.layoutIfNeeded()
    #expect(reports.isEmpty)
    #expect(!root.deepest.isMounted)

    await host.layoutFinished()
    #expect(reports.map(\.stack) == [.moved])
    #expect(reports.first?.hasProblems == true)
    #expect(host.passes == 1)
    #expect(root.deepest.isMounted)
    #expect(root.deepest.frame.size == LayoutSize(width: 178, height: 10))
    host.detach()
}

@Test @MainActor
func aTreeWithViewsTooDeepForTheMainThreadIsRejected() {
    let root = Nest(depth: 60) { MainThreadLeaf() }
    let host = NodeHost(root: root, size: LayoutSize(width: 300, height: 600))
    host.mainThreadStackBudget = 16 << 10
    var reports: [LayoutReport] = []
    host.onLayoutReport = { reports.append($0) }

    host.layoutIfNeeded()

    #expect(reports.map(\.stack) == [.exhausted])
    #expect(reports.first?.isRejected == true)
    #expect(host.passes == 0)
    #expect(!root.deepest.isMounted)
    host.detach()
}

@Test @MainActor
func aDeepTreeOfNodesIsPreparedWithoutRunningOutOfStack() {
    // Preparing a layout calls every node's `layoutSpec()`, so it runs on the main thread;
    // walked recursively, three thousand levels would overflow even the 8 MiB main thread
    // of a Mac in an unoptimized build.
    let root = Nest(depth: 3000) { Box(10, 10) }

    let prepared = root.asLayoutSpec.prepare()

    #expect(prepared.elementCount == 3002)
    #expect(prepared.ids(of: root.deepest).count == 1)
}

@Test @MainActor
func walksOfAVeryDeepTreeDoNotRunOutOfStack() {
    // Mounted by hand: no layout goes this deep, but the walks must not depend on that.
    let nodes = (0..<100_000).map { _ in Node() }
    for (index, node) in nodes.enumerated() {
        node.mount(
            in: index > 0 ? nodes[index - 1] : nil,
            subnodes: index + 1 < nodes.count ? [nodes[index + 1]] : []
        )
    }
    let host = NodeHost(root: nodes[0], size: LayoutSize(width: 100, height: 100))

    // Every frame is empty, so nothing is hit and every walk goes all the way down.
    #expect(nodes[0].hitTest(LayoutPoint(x: 0, y: 0)) == nil)
    #expect(host.accessibilityItems().isEmpty)
    #expect(host.focusItems().isEmpty)
    #expect(host.focusSections().isEmpty)

    // Unmounted one by one, the chain is released a node at a time.
    host.detach()
    for node in nodes {
        node.unmount()
    }
}

/// Takes a transaction the way `StateFlux`'s `bind(to:animation:)` does.
@MainActor
private func write(_ transaction: some StateTransaction, _ writes: () -> Void) {
    transaction.perform(writes)
}

@Test @MainActor
func anAnimationIsATransactionThatAnimatesItsWrites() {
    let screen = Screen()
    let host = host(screen)
    host.didRender()

    write(.linear(duration: 1)) {
        screen.card.showsFollow.value = false
    }
    host.layoutIfNeeded()

    #expect(host.renderAnimation == .linear(duration: 1))
    host.detach()
}
