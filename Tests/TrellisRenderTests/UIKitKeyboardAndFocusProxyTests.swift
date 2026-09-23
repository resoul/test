#if canImport(UIKit)
    import Testing
    import UIKit

    @testable import TrellisCore
    @testable import TrellisRender
    @testable import TrellisUIKit

    // A08: the UIKit host — press mapping (keyboard on iOS/iPadOS, Siri Remote on tvOS), the
    // native focus proxies and the engine ↔ platform handshake (D44/D45). `UIPress`/`UIKey`
    // cannot be constructed, so the host's `receive(_:pressType:key:)` step is driven with
    // the press already taken apart; the handshake is driven through the coordinator the
    // proxies call. Runs on the iOS and tvOS Simulators (C27 matrix).

    @MainActor
    private func waitForCommit(_ host: TrellisHostView) async {
        for _ in 0..<10_000 where host.layer.sublayers?.isEmpty != false { await Task.yield() }
    }

    /// Keeps the window alive for the test's duration: a host whose window is released is
    /// removed from it and suspends its bridge, which is exactly the lifecycle being tested
    /// elsewhere — not here.
    @MainActor
    private final class Stage {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let host: TrellisHostView
        let cards: [ControlNode]

        init(host: TrellisHostView, cards: [ControlNode]) {
            self.host = host
            self.cards = cards
        }
    }

    @MainActor
    private func makeHost() -> Stage {
        let stage = Stage(host: TrellisHostView(), cards: (0..<3).map { _ in ControlNode() })
        let window = stage.window
        let host = stage.host
        let cards = stage.cards
        host.frame = window.bounds
        window.addSubview(host)
        window.makeKeyAndVisible()
        let root = Node()
        root.style {
            $0.flexDirection = .row; $0.gap = 20
        }
        for card in cards {
            card.style {
                $0.width = 80; $0.height = 80
            }
            card.accessibility.label = "Card"
            root.addSubnode(card)
        }
        host.attach(root: root)
        return stage
    }

    @Test @MainActor
    func a08_uiKitPressMappingKeepsArrowsForThePlatformOnTV() {
        #expect(
            TrellisHostView.keyData(pressType: .select, key: nil, isTV: true)
                == KeyData(key: .select)
        )
        #expect(
            TrellisHostView.keyData(pressType: .select, key: nil, isTV: false)
                == KeyData(key: .select)
        )
        #expect(TrellisHostView.keyData(pressType: .upArrow, key: nil, isTV: true) == nil)
        #expect(
            TrellisHostView.keyData(pressType: .rightArrow, key: nil, isTV: false)
                == KeyData(key: .rightArrow)
        )
        #expect(TrellisHostView.keyData(pressType: .menu, key: nil, isTV: true) == nil)
        #expect(TrellisHostView.keyData(pressType: .playPause, key: nil, isTV: true) == nil)
    }

    @Test @MainActor
    func a08_uiKitSelectAndArrowsDriveTheEngineWhereTheEngineOwnsTraversal() async {
        let stage = makeHost()
        let host = stage.host
        let cards = stage.cards
        await waitForCommit(host)
        var activations: [ActivationSource] = []
        for card in cards {
            card.activation = { [weak card] in
                if let source = card?.lastActivationSource { activations.append(source) }
            }
        }
        let isTV = host.traitCollection.userInterfaceIdiom == .tv

        if isTV {
            // Arrows are the platform focus system's (D44): the host does not consume them.
            #expect(host.receive(.keyDown, pressType: .rightArrow, key: nil) == .unhandled)
            #expect(host.focusedID == nil)
            host.focus(cards[1].id)
        } else {
            #expect(host.receive(.keyDown, pressType: .rightArrow, key: nil) == .handled)
            #expect(host.focusedID == cards[0].id)
            #expect(host.receive(.keyDown, pressType: .rightArrow, key: nil) == .handled)
            #expect(host.receive(.keyUp, pressType: .rightArrow, key: nil) == .unhandled)
        }
        #expect(host.focusedID == cards[1].id)

        #expect(host.receive(.keyDown, pressType: .select, key: nil) == .handled)
        #expect(cards[1].isPressed)
        #expect(host.receive(.keyUp, pressType: .select, key: nil) == .handled)
        #expect(activations == [.remote])
        #expect(host.receive(.keyDown, pressType: .menu, key: nil) == .unhandled)

        // A cancelled press closes the cycle without activation.
        #expect(host.receive(.keyDown, pressType: .select, key: nil) == .handled)
        host.pressesCancelled([], with: nil)  // the set is empty: nothing to map, no cancel
        #expect(cards[1].isPressed)
        host.detach()
        #expect(!cards[1].isPressed)
        #expect(activations == [.remote])
    }

    @Test @MainActor
    func a08_proxiesFollowThePublishedCandidatesAndAreReusedWithinAMount() async throws {
        let stage = makeHost()
        let host = stage.host
        let cards = stage.cards
        await waitForCommit(host)
        let coordinator = try #require(host.proxyCoordinatorForTesting)
        #expect(host.nativeProxyCount == 3)
        let first = try #require(coordinator.proxy(for: cards[0].id))
        // The root folds the window's safe area into its padding, so compare with the
        // committed frame rather than a literal origin.
        let committed = try #require(cards[0].calculatedFrame)
        #expect(first.frame == TrellisNodeProxy.cgRect(committed))
        #expect(first.frame.size == CGSize(width: 80, height: 80))
        #expect(first.canBecomeFocused)
        #expect(first.mountEpoch == coordinator.mountEpoch)

        // Metadata-only republish: same proxy object, updated state.
        cards[0].isEnabled = false
        for _ in 0..<300 { await Task.yield() }
        #expect(coordinator.proxy(for: cards[0].id) === first)
        #expect(!first.canBecomeFocused)  // no longer a focus candidate…
        #expect(host.nativeProxyCount == 3)  // …but still an accessibility element

        // A removed node loses its proxy; the others keep theirs.
        cards[2].dispose()
        for _ in 0..<600 { await Task.yield() }
        #expect(host.nativeProxyCount == 2)
        #expect(coordinator.proxy(for: cards[2].id) == nil)
        #expect(coordinator.proxy(for: cards[1].id) != nil)

        // Focus items are exposed on tvOS only.
        let items = host.focusItems(in: host.bounds).compactMap { $0 as? TrellisNodeProxy }
        if host.traitCollection.userInterfaceIdiom == .tv {
            #expect(items.map(\.identity) == [cards[1].id])
        } else {
            #expect(items.isEmpty)
        }

        host.detach()
        #expect(host.nativeProxyCount == 0)
    }

    @Test @MainActor
    func a08_nativeHandshakeConfirmsEngineRequestsAndMirrorsPlatformMoves() async throws {
        let stage = makeHost()
        let host = stage.host
        let cards = stage.cards
        await waitForCommit(host)
        let coordinator = try #require(host.proxyCoordinatorForTesting)
        coordinator.isNativeFocusEnabled = true  // drive the tvOS path on any simulator
        var changes: [FocusChange] = []
        host.onFocusChange = { changes.append($0) }

        // Engine-initiated: the request is pending until the platform lands on the proxy.
        host.focus(cards[1].id)
        #expect(coordinator.pendingNativeRequest == cards[1].id)
        #expect(
            (coordinator.preferredFocusEnvironments.first as? TrellisNodeProxy)?.identity
                == cards[1].id
        )
        let proxy1 = try #require(coordinator.proxy(for: cards[1].id))
        coordinator.nativeFocusDidLand(on: proxy1)
        #expect(coordinator.pendingNativeRequest == nil)
        #expect(host.focusedID == cards[1].id)
        // The confirmation is a no-op for the engine: no second transition.
        #expect(changes.map(\.reason) == [.request])

        // Platform-initiated (a remote arrow): the engine follows with `.native`, and that
        // mirrored transition is not sent back as a new request (D45 loop guard).
        let proxy2 = try #require(coordinator.proxy(for: cards[2].id))
        coordinator.nativeFocusDidLand(on: proxy2)
        #expect(host.focusedID == cards[2].id)
        #expect(changes.map(\.reason) == [.request, .native])
        #expect(coordinator.pendingNativeRequest == nil)

        // Focus left to a neighbouring native control: engine focus clears.
        coordinator.nativeFocusDidLeave(from: proxy2)
        #expect(host.focusedID == nil)
        #expect(changes.last == FocusChange(previous: cards[2].id, next: nil, reason: .native))
        coordinator.nativeFocusDidLeave(from: proxy2)  // not focused any more: ignored
        #expect(changes.count == 3)

        // A pending request the platform answered with a different item: the platform wins.
        host.focus(cards[0].id)
        #expect(coordinator.pendingNativeRequest == cards[0].id)
        coordinator.nativeFocusDidLand(on: proxy1)
        #expect(coordinator.pendingNativeRequest == nil)
        #expect(host.focusedID == cards[1].id)

        // A stale proxy from a previous mount never reaches the engine.
        host.detach()
        host.attach(
            root: {
                let root = Node()
                root.addSubnode(cards[0])
                return root
            }()
        )
        await waitForCommit(host)
        let before = changes.count
        coordinator.nativeFocusDidLand(on: proxy1)
        #expect(host.focusedID == nil)
        #expect(changes.count == before)
    }

    // MARK: - A12: proxies are bounded by the published set, not by commits

    @Test @MainActor
    func a12_proxyCountFollowsTheSnapshotAndDetachDuringAPendingNativeRequestIsClean() async throws
    {
        let stage = makeHost()
        let host = stage.host
        let cards = stage.cards
        await waitForCommit(host)
        let coordinator = try #require(host.proxyCoordinatorForTesting)
        #expect(host.nativeProxyCount == 3)
        let created = host.createdNativeProxyTotal
        #expect(created == 3)

        // 20 geometry commits and metadata bursts: the same three proxies throughout.
        for i in 0..<20 {
            for card in cards { card.style.height = .points(Double(81 + (i % 2))) }
            for card in cards { card.accessibility.value = "\(i)" }
            for _ in 0..<20_000
            where coordinator.proxy(for: cards[0].id)?.accessibilityValue != "\(i)" {
                await Task.yield()
            }
        }
        #expect(host.nativeProxyCount == 3)
        #expect(host.createdNativeProxyTotal == created)

        // Detach while an engine request awaits native confirmation: nothing dangles.
        coordinator.isNativeFocusEnabled = true
        host.focus(cards[1].id)
        #expect(coordinator.pendingNativeRequest == cards[1].id)
        weak var proxy: TrellisNodeProxy?
        proxy = coordinator.proxy(for: cards[1].id)
        host.detach()
        #expect(coordinator.pendingNativeRequest == nil)
        #expect(host.nativeProxyCount == 0)
        #expect(coordinator.preferredFocusEnvironments.isEmpty)
        for _ in 0..<300 { await Task.yield() }
        #expect(proxy == nil)
    }
#endif
