import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisFlux
@testable import TrellisRender

/// R05: the same shape as `Playground/Shared/Scenarios/S32_FluxFilterFeed.swift` (filter
/// buttons, a simulated delayed load, one guaranteed failure recovered by retry, an animated
/// update) — but automated and repeatable here with real `Task.sleep` delays, not a manually
/// clicked demo. This is the "working Flux integration, not just operators in unit tests"
/// R05 asks for: real `CurrentValue`, real `EffectOwner`, real `NodeHostBridge.bindFlux`, a
/// real `ControlNode` activated exactly like a tap would, wired together end to end.
private enum DemoFilter: Sendable, Equatable, CaseIterable {
    case all, even, odd
}

private enum DemoState: Sendable, Equatable {
    case loading(DemoFilter)
    case loaded(DemoFilter, [Int])
    case failed(DemoFilter, String)
}

private let demoAllItems = Array(1...10)

@MainActor
private final class DemoFeedModel {
    private let stateSubject = CurrentValue<DemoState>(.loading(.all))
    private let effects = EffectOwner<String>()
    private var pendingFailure: DemoFilter?

    var stateFlux: Flux<DemoState> { stateSubject.flux }

    init(failFirst filter: DemoFilter?) {
        pendingFailure = filter
        load(.all)
    }

    func select(_ filter: DemoFilter) { load(filter) }
    func retry(_ filter: DemoFilter) { load(filter) }

    private func load(_ filter: DemoFilter) {
        let shouldFail = pendingFailure == filter
        if shouldFail { pendingFailure = nil }
        let subject = stateSubject
        Task { await subject.set(.loading(filter)) }
        effects.run(
            "load",
            onConflict: .restart,
            operation: { () async -> DemoState in
                try? await Task.sleep(for: .milliseconds(40))
                if shouldFail { return .failed(filter, "boom") }
                let items: [Int]
                switch filter {
                case .all: items = demoAllItems
                case .even: items = demoAllItems.filter { $0.isMultiple(of: 2) }
                case .odd: items = demoAllItems.filter { !$0.isMultiple(of: 2) }
                }
                return .loaded(filter, items)
            },
            apply: { [subject] result in
                Task { await subject.set(result) }
            }
        )
    }
}

/// A tappable filter button — a real `ControlNode`, activated the same way `TapCardNode`
/// (S21) is: through the pointer/hit-test/arena pipeline (H09), not a direct method call.
private final class DemoFilterButtonNode: ControlNode {
    var onTap: (() -> Void)?
    init() {
        super.init()
        style {
            $0.width = .points(60); $0.height = .points(32)
        }
        activation = { [weak self] in self?.onTap?() }
    }
}

private final class DemoScreenNode: Node {
    private(set) var shown: DemoState?
    private(set) var deliveries: [(DemoState, Animation)] = []

    func update(_ state: DemoState, animation: Animation) {
        deliveries.append((state, animation))
        guard state != shown else { return }
        shown = state
        // Real geometry change under `animate`, same convention R03 proved end to end:
        // width encodes item count (or 0 while loading/failed) so a real committed frame
        // shows the transition took effect, not just that the right `Animation` value
        // arrived at this closure.
        animate(animation) {
            switch state {
            case .loading, .failed: style.width = .points(0)
            case .loaded(_, let items): style.width = .points(Double(items.count) * 10)
            }
        }
    }
}

@MainActor
private func tap(_ button: DemoFilterButtonNode, on root: Node, snapshot: HitTestSnapshot) throws {
    let frame = try #require(button.calculatedFrame, "button has no committed frame yet")
    let point = LayoutPoint(
        x: frame.origin.x + frame.width / 2,
        y: frame.origin.y + frame.height / 2
    )
    let sessions = PointerSessions()
    _ = sessions.send(
        .pointerDown,
        PointerData(point: point, pointerID: 1),
        snapshot: snapshot,
        root: root
    )
    _ = sessions.send(
        .pointerUp,
        PointerData(point: point, pointerID: 1),
        snapshot: snapshot,
        root: root
    )
}

private func waitUntil(
    timeout: Int = 100_000,
    _ condition: @autoclosure @MainActor () -> Bool
) async {
    for _ in 0..<timeout where !(await condition()) { await Task.yield() }
}

@Test @MainActor
func test_externalConsumer_selectingAFilterLoadsThenShowsFilteredItemsAnimated() async throws {
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    let root = Node()
    let screen = DemoScreenNode()
    root.addSubnode(screen)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))

    let model = DemoFeedModel(failFirst: nil)
    let binding = bridge.bindFlux(model.stateFlux, initial: .loading(.all)) { state, animation in
        screen.update(state, animation: animation)
    }

    await waitUntil(screen.shown == .loaded(.all, Array(1...10)))
    #expect(screen.calculatedFrame?.width == 100)
    // Replay/first attach: no animation.
    #expect(screen.deliveries.first?.1 == Animation.none)

    model.select(.even)
    await waitUntil(screen.shown == .loaded(.even, [2, 4, 6, 8, 10]))
    #expect(screen.calculatedFrame?.width == 50)
    // A real, later change did carry a real (non-`.none`) animation intent.
    #expect(screen.deliveries.last?.1 != Animation.none)

    binding.cancel()
}

@Test @MainActor
func test_externalConsumer_filterButtonTapDrivesTheSameModel() async throws {
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    let root = Node()
    let screen = DemoScreenNode()
    let oddButton = DemoFilterButtonNode()
    root.addSubnode(screen)
    root.addSubnode(oddButton)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))

    let model = DemoFeedModel(failFirst: nil)
    let binding = bridge.bindFlux(model.stateFlux, initial: .loading(.all)) { state, animation in
        screen.update(state, animation: animation)
    }
    await waitUntil(screen.shown == .loaded(.all, Array(1...10)))

    oddButton.onTap = { [weak model] in model?.select(.odd) }
    let snapshot = try #require(
        HitTestSnapshot(root: root, mountEpoch: 1, bounds: LayoutFrame(width: 300, height: 200))
    )
    try tap(oddButton, on: root, snapshot: snapshot)

    await waitUntil(screen.shown == .loaded(.odd, [1, 3, 5, 7, 9]))
    #expect(screen.calculatedFrame?.width == 50)

    binding.cancel()
}

@Test @MainActor
func test_externalConsumer_retryRecoversAfterAGuaranteedFailure() async throws {
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    let root = Node()
    let screen = DemoScreenNode()
    root.addSubnode(screen)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))

    // "Even" fails exactly once, the same reproducible-not-random shape S32 uses.
    let model = DemoFeedModel(failFirst: .even)
    let binding = bridge.bindFlux(model.stateFlux, initial: .loading(.all)) { state, animation in
        screen.update(state, animation: animation)
    }
    await waitUntil(screen.shown == .loaded(.all, Array(1...10)))

    model.select(.even)
    await waitUntil(screen.shown == .failed(.even, "boom"))
    // The error did not permanently end the binding (R04: no undefined-forever state).
    #expect(binding.isActive)

    model.retry(.even)
    await waitUntil(screen.shown == .loaded(.even, [2, 4, 6, 8, 10]))
    #expect(screen.calculatedFrame?.width == 50)

    binding.cancel()
}

@Test @MainActor
func test_externalConsumer_switchingFiltersMidLoadCancelsTheStaleOne() async throws {
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    let root = Node()
    let screen = DemoScreenNode()
    root.addSubnode(screen)
    #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))

    let model = DemoFeedModel(failFirst: nil)
    let binding = bridge.bindFlux(model.stateFlux, initial: .loading(.all)) { state, animation in
        screen.update(state, animation: animation)
    }
    await waitUntil(screen.shown == .loaded(.all, Array(1...10)))

    // Two selections back to back, well inside the simulated network delay: only the last
    // (odd) must ever be shown — the stale even response, R04's own guarantee, is discarded.
    model.select(.even)
    model.select(.odd)

    await waitUntil(screen.shown == .loaded(.odd, [1, 3, 5, 7, 9]))
    // Let a real, wrongly-applied stale response show up if there were one.
    for _ in 0..<2_000 { await Task.yield() }
    #expect(screen.shown == .loaded(.odd, [1, 3, 5, 7, 9]))

    binding.cancel()
}

@Test @MainActor
func test_externalConsumer_cancelReleasesTheModelAndScreenNoLeaks() async throws {
    weak var weakModel: DemoFeedModel?
    weak var weakScreen: DemoScreenNode?
    let host = CALayer()
    let bridge = NodeHostBridge(hostLayer: host)
    do {
        let root = Node()
        let screen = DemoScreenNode()
        weakScreen = screen
        root.addSubnode(screen)
        #expect(bridge.attach(root: root, bounds: LayoutFrame(width: 300, height: 200), scale: 1))

        let model = DemoFeedModel(failFirst: nil)
        weakModel = model
        let binding = bridge.bindFlux(model.stateFlux, initial: .loading(.all)) {
            [weak screen] state, animation in
            screen?.update(state, animation: animation)
        }
        await waitUntil(screen.shown == .loaded(.all, Array(1...10)))
        binding.cancel()
        bridge.detach()
    }
    await waitUntil(weakModel == nil && weakScreen == nil)
    #expect(weakModel == nil)
    #expect(weakScreen == nil)
}
