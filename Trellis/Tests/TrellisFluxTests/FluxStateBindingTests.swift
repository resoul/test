import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisFlux
@testable import TrellisRender

/// A minimal C29-style node: compares against what it last showed, records every call and
/// the animation intent it arrived with. Mirrors `StateBindingTests.swift`'s `CardNode`.
@MainActor
private final class CardNode: Node {
    private(set) var shown: Int?
    private(set) var updateCalls = 0
    private(set) var intents: [Animation] = []
    private(set) var deliveredValues: [Int] = []

    func update(_ value: Int, animation: Animation) {
        updateCalls += 1
        intents.append(animation)
        deliveredValues.append(value)
        shown = value
    }
}

/// Unlike `CardNode` above, this actually calls `animate(_:_:)` around its own mutation —
/// proving the delivered intent reaches a real geometry change, not just that the right
/// `Animation` value was handed to a recording closure.
@MainActor
private final class GeometryCardNode: Node {
    func update(_ width: Double, animation: Animation) {
        animate(animation) { style.width = .points(width) }
    }
}

@MainActor
private final class Fixture {
    let hostLayer = CALayer()
    let bridge: NodeHostBridge
    let root = Node()
    let card = CardNode()

    init() {
        bridge = NodeHostBridge(hostLayer: hostLayer)
        root.addSubnode(card)
    }

    @discardableResult
    func attach(root: Node? = nil) -> Bool {
        bridge.attach(
            root: root ?? self.root,
            bounds: LayoutFrame(width: 300, height: 200),
            scale: 1
        )
    }

    func settle() async {
        for _ in 0..<300 { await Task.yield() }
    }
}

@Test @MainActor
func test_fluxBinding_initialLandsInFirstCommitWithoutAnimation() async throws {
    let f = Fixture()
    #expect(f.attach())
    let (stream, _) = AsyncStream<Int>.makeStream()
    let flux = Flux { stream }
    f.bridge.bindFlux(flux, initial: 100) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()

    #expect(f.card.updateCalls == 1)
    #expect(f.card.shown == 100)
    #expect(f.card.intents == [.none])
}

@Test @MainActor
func test_fluxBinding_rapidSuccessionConvergesToTheLastValueWithoutCorruption() async throws {
    // A raw, unthrottled Flux producer emitting many values in quick succession is NOT
    // guaranteed to coalesce to one delivery (see `bindFlux`'s doc comment: each `for await`
    // iteration is a genuine suspension, verified empirically to interleave with this
    // binding's own scheduled deliveries rather than draining in one sweep) — what R03
    // actually guarantees here is correctness under that interleaving: every delivered
    // (value, intent) pair is internally consistent, nothing is lost, and the sequence ends
    // on the last value with the intent computed against the previously *delivered* value,
    // not against whatever intermediate value a delivery raced past.
    let f = Fixture()
    #expect(f.attach())
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    let flux = Flux { stream }
    f.bridge.bindFlux(
        flux,
        initial: 0,
        animation: { from, to in Animation.linear(duration: .milliseconds(Double(to - from))) }
    ) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)
    #expect(f.card.intents == [.none])

    for value in stride(from: 10, through: 100, by: 10) {
        continuation.yield(value)
    }
    await f.settle()

    #expect(f.card.shown == 100)
    // Each intent after the first matches (previous *delivered* value, this delivered value):
    // the deltas are internally consistent regardless of how many of the ten intermediate
    // values actually reached `update`.
    var previous = 0
    for (index, intent) in f.card.intents.enumerated() {
        let delivered = f.card.deliveredValues[index]
        if index == 0 {
            #expect(intent == .none)
        } else {
            #expect(intent == .linear(duration: .milliseconds(Double(delivered - previous))))
        }
        previous = delivered
    }
    #expect(f.card.deliveredValues.last == 100)
}

@Test @MainActor
func test_fluxBinding_throttledUpstreamIsHowACallerCoalescesAFastProducer() async throws {
    // The documented tool for coalescing (`bindFlux`'s doc comment): compose Flux's own
    // `throttle` upstream instead of expecting `bindFlux` to rate-limit a raw producer.
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    let throttled = pipe.flux.throttle(.milliseconds(200))
    f.bridge.bindFlux(throttled, initial: 0) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)

    for value in stride(from: 1, through: 20, by: 1) {
        pipe.send(value)
    }
    await f.settle()

    // Throttled to at most one value per 200ms window: nowhere near one delivery per send.
    #expect(f.card.updateCalls < 20)
}

@Test @MainActor
func test_fluxBinding_equalValueIsANoOp() async throws {
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    f.bridge.bindFlux(pipe.flux, initial: 5) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)

    pipe.send(5)
    await f.settle()
    #expect(f.card.updateCalls == 1)

    pipe.send(6)
    await f.settle()
    #expect(f.card.updateCalls == 2)
}

@Test @MainActor
func test_fluxBinding_cancelAfterEnqueuePreventsLateDelivery() async throws {
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    let binding = f.bridge.bindFlux(pipe.flux, initial: 1) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)

    pipe.send(2)
    binding.cancel()
    await f.settle()

    #expect(f.card.updateCalls == 1)
    #expect(f.card.shown == 1)
    #expect(!binding.isActive)
    #expect(f.bridge.bindingCount == 0)
}

@Test @MainActor
func test_fluxBinding_detachStopsDeliveryAndReattachRestoresLatest() async throws {
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    let binding = f.bridge.bindFlux(pipe.flux, initial: 1) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)

    f.bridge.detach()
    pipe.send(2)
    pipe.send(3)
    await f.settle()
    #expect(f.card.updateCalls == 1)  // nothing while detached

    #expect(f.attach())
    await f.settle()
    #expect(f.card.updateCalls == 2)  // only the latest, once
    #expect(f.card.shown == 3)
    #expect(binding.isActive)
}

@Test @MainActor
func test_fluxBinding_suspendHoldsLatestAndResumeDeliversIt() async throws {
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    f.bridge.bindFlux(pipe.flux, initial: 1) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()

    f.bridge.suspend()
    pipe.send(2)
    pipe.send(3)
    await f.settle()
    #expect(f.card.updateCalls == 1)

    f.bridge.resume()
    await f.settle()
    #expect(f.card.updateCalls == 2)
    #expect(f.card.shown == 3)
}

@Test @MainActor
func test_fluxBinding_twoHostsEachGetIndependentDelivery() async throws {
    let hostA = CALayer()
    let hostB = CALayer()
    let bridgeA = NodeHostBridge(hostLayer: hostA)
    let bridgeB = NodeHostBridge(hostLayer: hostB)
    let rootA = Node()
    let rootB = Node()
    let cardA = CardNode()
    let cardB = CardNode()
    rootA.addSubnode(cardA)
    rootB.addSubnode(cardB)
    #expect(bridgeA.attach(root: rootA, bounds: LayoutFrame(width: 100, height: 100), scale: 1))
    #expect(bridgeB.attach(root: rootB, bounds: LayoutFrame(width: 100, height: 100), scale: 1))

    let pipe = Pipe<Int>()
    let bindingA = bridgeA.bindFlux(pipe.flux, initial: 0) { value, animation in
        cardA.update(value, animation: animation)
    }
    bridgeB.bindFlux(pipe.flux, initial: 0) { value, animation in
        cardB.update(value, animation: animation)
    }
    for _ in 0..<300 { await Task.yield() }
    #expect(cardA.updateCalls == 1)
    #expect(cardB.updateCalls == 1)

    pipe.send(42)
    for _ in 0..<300 { await Task.yield() }
    #expect(cardA.shown == 42)
    #expect(cardB.shown == 42)

    bindingA.cancel()
    pipe.send(43)
    for _ in 0..<300 { await Task.yield() }
    // Cancelling one host's binding does not touch the other's.
    #expect(cardA.shown == 42)
    #expect(cardB.shown == 43)
}

@Test @MainActor
func test_fluxBinding_reentrantSendFromInsideUpdateDoesNotDeadlockOrLoseValues() async throws {
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    var seen: [Int] = []
    f.bridge.bindFlux(pipe.flux, initial: 0) { value, _ in
        seen.append(value)
        // Reentrant: mutating the same source from inside its own delivery must not deadlock
        // or corrupt delivery (the send below lands as a distinct, later delivery, not
        // recursively inline).
        if value == 1 { pipe.send(2) }
    }
    await f.settle()
    #expect(seen == [0])

    pipe.send(1)
    await f.settle()
    #expect(seen == [0, 1, 2])
}

@Test @MainActor
func test_fluxBinding_replaceRootStopsDeliveryToTheOldTreeWhenCancelled() async throws {
    let f = Fixture()
    #expect(f.attach())
    let pipe = Pipe<Int>()
    let binding = f.bridge.bindFlux(pipe.flux, initial: 1) { [card = f.card] value, animation in
        card.update(value, animation: animation)
    }
    await f.settle()
    #expect(f.card.updateCalls == 1)

    // The caller's own responsibility before replacing the root, same as `bindState`
    // (D14): cancel bindings scoped to the tree being replaced.
    binding.cancel()
    let replacement = Node()
    let replacementCard = CardNode()
    replacement.addSubnode(replacementCard)
    #expect(f.attach(root: replacement))
    pipe.send(2)
    await f.settle()

    #expect(f.card.updateCalls == 1)  // old tree never sees the later value
    #expect(f.card.shown == 1)
}

@Test @MainActor
func test_fluxBinding_bridgeReleasesNothingItShouldNot() async throws {
    weak var weakCard: CardNode?
    do {
        let f = Fixture()
        weakCard = f.card
        #expect(f.attach())
        let pipe = Pipe<Int>()
        let binding = f.bridge.bindFlux(pipe.flux, initial: 1) { [card = f.card] value, animation in
            card.update(value, animation: animation)
        }
        await f.settle()
        binding.cancel()
        f.bridge.detach()
    }
    await Task.yield()
    #expect(weakCard == nil)
}

@Test @MainActor
func test_fluxBinding_stateDrivesARealAnimatedGeometryChangeAndReplayIsInstant() async throws {
    let hostLayer = CALayer()
    let bridge = NodeHostBridge(hostLayer: hostLayer)
    let root = Node()
    let card = GeometryCardNode()
    root.addSubnode(card)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))

    func waitForCommits(_ count: Int) async {
        for _ in 0..<10_000 where bridge.committedCount < count { await Task.yield() }
    }

    let pipe = Pipe<Int>()
    bridge.bindFlux(pipe.flux, initial: 100) { value, animation in
        card.update(Double(value), animation: animation)
    }
    await waitForCommits(1)
    for _ in 0..<300 { await Task.yield() }
    // Replay/first attach (P6.2): delivered through `Animation.none` — still a real,
    // instantly-applied geometry change, not merely a recorded intent value.
    #expect(card.calculatedFrame?.width == 100)

    pipe.send(180)
    await waitForCommits(2)
    for _ in 0..<300 { await Task.yield() }
    #expect(card.calculatedFrame?.width == 180)
}
