import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

private struct CardModel: Equatable, Sendable {
    var width: Double
    var tint: ThemeColor
    var showBadge: Bool
}

/// The C29 pattern: an ordinary node with an `update(model)` that compares with what it shows
/// and mutates only what changed — `style` for geometry, `appearance` for paint,
/// `markArrangementDirty()` for structure.
@MainActor
private final class CardNode: Node {
    let badge = Node()
    private(set) var shown: CardModel?
    private(set) var updateCalls = 0
    private(set) var arrangeCalls = 0

    func update(_ model: CardModel) {
        updateCalls += 1
        guard model != shown else { return }
        let previous = shown
        shown = model
        if previous?.width != model.width { style.width = .points(model.width) }
        if previous?.tint != model.tint { appearance.background = .color(model.tint) }
        if previous?.showBadge != model.showBadge { markArrangementDirty() }
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        arrangeCalls += 1
        return Row {
            if shown?.showBadge == true {
                Leaf(badge).size(width: .points(10), height: .points(10))
            }
        }
    }
}

@MainActor
private final class Fixture {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let card = CardNode()
    let subject = StateSubject(
        CardModel(width: 100, tint: ThemeColor(red: 1, green: 0, blue: 0), showBadge: false)
    )

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        root.style.flexDirection = .column
        root.addSubnode(card)
    }

    func attach() -> Bool {
        bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1)
    }

    func waitForCommits(_ count: Int) async {
        for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
    }

    func settle() async {
        for _ in 0..<300 { await Task.yield() }
    }
}

@Test @MainActor
func test_stateBinding_currentValueLandsInTheFirstCommitAndEqualStateDoesNothing() async throws {
    let f = Fixture()
    #expect(f.attach())
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()

    // Bound after attach, delivered synchronously: one commit already shows the model.
    #expect(f.card.updateCalls == 1)
    #expect(f.card.calculatedFrame?.width == 100)
    #expect(f.bridge.committedCount == 1)

    // Same state: the subject drops it before it reaches the binding.
    f.subject.send(f.subject.current)
    await f.settle()
    #expect(f.card.updateCalls == 1)
    #expect(f.bridge.committedCount == 1)
}

@Test @MainActor
func test_stateBinding_burstDeliversOnlyTheLastValueAndOneCommit() async throws {
    let f = Fixture()
    #expect(f.attach())
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()

    for width in stride(from: 110.0, through: 200.0, by: 10) {
        f.subject.send(CardModel(width: width, tint: f.subject.current.tint, showBadge: false))
    }
    await f.waitForCommits(2)
    await f.settle()
    #expect(f.card.updateCalls == 2)  // initial + one for the burst
    #expect(f.card.shown?.width == 200)
    #expect(f.card.calculatedFrame?.width == 200)
    #expect(f.bridge.committedCount == 2)
}

@Test @MainActor
func test_stateBinding_appearanceOnlyChangeRepaintsWithoutALayoutPass() async throws {
    let f = Fixture()
    #expect(f.attach())
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()
    let commits = f.bridge.committedCount

    let green = ThemeColor(red: 0, green: 1, blue: 0)
    f.subject.send(CardModel(width: 100, tint: green, showBadge: false))
    await f.settle()

    #expect(f.card.updateCalls == 2)
    #expect(f.bridge.committedCount == commits)  // no snapshot/measure/place
    let layer = try #require(f.bridge.layer(for: f.card.id))
    let components = try #require(layer.backgroundColor?.components)
    #expect(components[0] == 0 && components[1] == 1)
}

@Test @MainActor
func test_stateBinding_structureChangeGoesThroughArrangementAndKeepsIdentity() async throws {
    let f = Fixture()
    #expect(f.attach())
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()
    #expect(f.card.subnodes.isEmpty)
    let cardLayer = try #require(f.bridge.layer(for: f.card.id))

    f.subject.send(CardModel(width: 100, tint: f.subject.current.tint, showBadge: true))
    await f.waitForCommits(2)
    await f.settle()
    #expect(f.card.subnodes.first === f.card.badge)
    #expect(f.card.badge.calculatedFrame?.width == 10)
    #expect(f.bridge.layer(for: f.card.id) === cardLayer)
    #expect(f.card.arrangeCalls == 2)
}

@Test @MainActor
func test_stateBinding_detachStopsDeliveryAndReattachRestoresLatest() async throws {
    let f = Fixture()
    #expect(f.attach())
    let binding = f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()
    #expect(f.subject.observerCount == 1)

    f.bridge.detach()
    #expect(f.subject.observerCount == 0)
    for width in [120.0, 130.0, 140.0] {
        f.subject.send(CardModel(width: width, tint: f.subject.current.tint, showBadge: false))
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)  // nothing while detached
    #expect(f.card.shown?.width == 100)

    #expect(f.attach())
    await f.waitForCommits(1)
    await f.settle()
    #expect(f.subject.observerCount == 1)
    #expect(f.card.updateCalls == 2)  // only the latest, once
    #expect(f.card.shown?.width == 140)
    #expect(f.card.calculatedFrame?.width == 140)
    #expect(binding.isActive)
    #expect(f.bridge.bindingCount == 1)
}

@Test @MainActor
func test_stateBinding_suspendHoldsLatestAndResumeDeliversIt() async throws {
    let f = Fixture()
    #expect(f.attach())
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()

    f.bridge.suspend()
    f.subject.send(CardModel(width: 150, tint: f.subject.current.tint, showBadge: false))
    f.subject.send(CardModel(width: 160, tint: f.subject.current.tint, showBadge: false))
    await f.settle()
    #expect(f.card.updateCalls == 1)

    f.bridge.resume()
    await f.waitForCommits(2)
    await f.settle()
    #expect(f.card.updateCalls == 2)
    #expect(f.card.shown?.width == 160)
}

@Test @MainActor
func test_stateBinding_boundWhileSuspendedIsInTheFirstCommitAfterResume() async throws {
    // Defect #19: a binding made (or a value received) while the host is suspended must be
    // applied before the flush that resume schedules — one commit with the state, never a
    // stale frame followed by a second commit.
    let f = Fixture()
    #expect(f.attach())
    await f.waitForCommits(1)
    await f.settle()
    f.bridge.suspend()
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    #expect(f.card.updateCalls == 0)
    f.subject.send(CardModel(width: 180, tint: f.subject.current.tint, showBadge: true))
    await f.settle()
    #expect(f.card.updateCalls == 0)

    f.bridge.resume()
    // Delivered synchronously on resume, before any flush ran.
    #expect(f.card.updateCalls == 1)
    #expect(f.card.shown?.width == 180)
    await f.waitForCommits(2)
    await f.settle()
    #expect(f.bridge.committedCount == 2)
    #expect(f.card.calculatedFrame?.width == 180)
    #expect(f.card.subnodes.first === f.card.badge)
}

@Test @MainActor
func test_stateBinding_attachAfterSuspendStartsActive() async throws {
    // Defect #21: the bridge outlives its mounts, so a suspend on the previous mount must not
    // leave a binding paused on the next attach — the new coordinator commits regardless, and
    // the first frame would miss the bound state with no resume in sight.
    let f = Fixture()
    #expect(f.attach())
    f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()
    f.bridge.suspend()
    f.bridge.detach()
    f.subject.send(CardModel(width: 190, tint: f.subject.current.tint, showBadge: false))

    #expect(f.attach())
    // Delivered synchronously as part of attach, before the first flush.
    #expect(f.card.shown?.width == 190)
    await f.waitForCommits(1)
    await f.settle()
    #expect(f.bridge.committedCount == 1)
    #expect(f.card.calculatedFrame?.width == 190)
}

@Test @MainActor
func test_stateBinding_cancelPreventsLateMutationsAndReleasesOwnership() async throws {
    let f = Fixture()
    #expect(f.attach())
    let binding = f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
    await f.waitForCommits(1)
    await f.settle()

    // A value already scheduled for delivery must not land after cancel.
    f.subject.send(CardModel(width: 170, tint: f.subject.current.tint, showBadge: false))
    binding.cancel()
    await f.settle()
    #expect(f.card.updateCalls == 1)
    #expect(f.card.shown?.width == 100)
    #expect(!binding.isActive)
    #expect(f.bridge.bindingCount == 0)
    #expect(f.subject.observerCount == 0)

    // Re-attaching does not resurrect it.
    f.bridge.detach()
    #expect(f.attach())
    await f.waitForCommits(1)
    await f.settle()
    #expect(f.card.updateCalls == 1)
}

@Test @MainActor
func test_stateBinding_bridgeReleasesNothingItShouldNot() async throws {
    weak var weakCard: CardNode?
    weak var weakSubject: StateSubject<CardModel>?
    do {
        let f = Fixture()
        weakCard = f.card
        weakSubject = f.subject
        #expect(f.attach())
        f.bridge.bindState(f.subject) { [card = f.card] in card.update($0) }
        await f.waitForCommits(1)
        f.bridge.cancelAllBindings()
        f.bridge.detach()
        #expect(f.bridge.bindingCount == 0)
    }
    await Task.yield()
    #expect(weakCard == nil)
    #expect(weakSubject == nil)
}
