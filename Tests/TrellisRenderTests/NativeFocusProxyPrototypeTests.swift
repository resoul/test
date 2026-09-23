#if canImport(UIKit)
    import Testing
    import UIKit

    // A02 — native evidence for D44 (docs/validation/a02-native-prototype.md): one NSObject
    // proxy per node that is both a `UIAccessibilityElement` and a `UIFocusItem`, returned from
    // a container view's `focusItems(in:)`, with no `UIView` per node. Runs on the iOS and
    // tvOS Simulators through `xcodebuild test` (C27 matrix). What a headless runner can prove
    // is here: accessibility enumeration, action routing, screen frames, touch hit-testing
    // untouched, proxy cost. The tvOS focus system is inert inside the xctest host (even a
    // `UIButton` never becomes focused there), so the focus-transition evidence lives in the
    // Playground-tvOS probe run recorded in the A02 report, not in this file. No Trellis
    // module is involved on purpose: this proves the platform mechanism before A08/A09.

    @MainActor
    private final class NodeProxy: UIAccessibilityElement, UIFocusItem {
        let identity: Int
        var proxyFrame: CGRect
        private(set) var focusInCount = 0
        private(set) var focusOutCount = 0
        private(set) var previousOnLastFocusIn: NodeProxy?
        var activations = 0
        weak var container: ProxyContainerView?

        init(identity: Int, frame: CGRect, container: ProxyContainerView) {
            self.identity = identity
            proxyFrame = frame
            self.container = container
            super.init(accessibilityContainer: container)
            isAccessibilityElement = true
            accessibilityLabel = "Card \(identity)"
            accessibilityTraits = .button
        }

        // UIAccessibilityElement: the frame VoiceOver reads, in screen coordinates.
        override var accessibilityFrame: CGRect {
            get {
                guard let container else { return .zero }
                return UIAccessibility.convertToScreenCoordinates(proxyFrame, in: container)
            }
            set {}
        }

        override func accessibilityActivate() -> Bool {
            activations += 1
            return true
        }

        // UIFocusItem — frame in the container's coordinate space.
        var canBecomeFocused: Bool { true }
        var frame: CGRect { proxyFrame }

        // UIFocusEnvironment.
        var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
        var parentFocusEnvironment: (any UIFocusEnvironment)? { container }
        var focusItemContainer: (any UIFocusItemContainer)? { container }

        func setNeedsFocusUpdate() {
            UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self)
        }

        func updateFocusIfNeeded() {
            UIFocusSystem.focusSystem(for: self)?.updateFocusIfNeeded()
        }

        func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }

        func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            if context.nextFocusedItem === self {
                focusInCount += 1
                previousOnLastFocusIn = context.previouslyFocusedItem as? NodeProxy
            }
            if context.previouslyFocusedItem === self { focusOutCount += 1 }
        }
    }

    @MainActor
    private final class ProxyContainerView: UIView {
        var proxies: [NodeProxy] = []
        var requested: NodeProxy?

        override var canBecomeFocused: Bool { false }

        override func focusItems(in rect: CGRect) -> [any UIFocusItem] {
            super.focusItems(in: rect) + proxies.filter { $0.frame.intersects(rect) }
        }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            requested.map { [$0] } ?? []
        }
    }

    @MainActor
    private func makeWindow() -> (UIWindow, ProxyContainerView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let container = ProxyContainerView(frame: window.bounds)
        window.addSubview(container)
        window.makeKeyAndVisible()
        return (window, container)
    }

    @MainActor
    private func makeProxies(_ count: Int, in container: ProxyContainerView) -> [NodeProxy] {
        let proxies = (0..<count).map { index in
            NodeProxy(
                identity: index,
                frame: CGRect(
                    x: 40 + (index % 10) * 70,
                    y: 40 + (index / 10) * 70,
                    width: 60,
                    height: 60
                ),
                container: container
            )
        }
        container.proxies = proxies
        container.accessibilityElements = proxies
        return proxies
    }

    @Test @MainActor
    func a02_proxiesAreTheOnlyAccessibilityElementsAndActivateOnce() {
        let (_, container) = makeWindow()
        let proxies = makeProxies(2, in: container)

        #expect(container.isAccessibilityElement == false)
        #expect((container.accessibilityElements as? [NodeProxy])?.count == 2)
        #expect(proxies[1].accessibilityLabel == "Card 1")
        #expect(proxies[1].accessibilityTraits == .button)
        // Screen frame of the second card — the window is at the origin, so screen == window.
        #expect(proxies[1].accessibilityFrame == CGRect(x: 110, y: 40, width: 60, height: 60))
        #expect(proxies[0].accessibilityActivate())
        #expect(proxies[0].activations == 1)
        #expect(proxies[1].activations == 0)
    }

    @Test @MainActor
    func a02_proxiesDoNotInterceptTouchHitTesting() {
        let (_, container) = makeWindow()
        _ = makeProxies(2, in: container)
        // No UIView per node: the container itself is the hit view, so H07's touch path is
        // untouched. (The rejected alternative — transparent UIView proxies — would return the
        // proxy view here unless every one disabled user interaction.)
        #expect(container.hitTest(CGPoint(x: 60, y: 60), with: nil) === container)
    }

    @Test @MainActor
    func a02_thousandProxiesCostVersusViews() {
        let (_, container) = makeWindow()
        let clock = ContinuousClock()
        let proxyTime = clock.measure { _ = makeProxies(1000, in: container) }
        let viewTime = clock.measure {
            for index in 0..<1000 {
                let view = UIView(
                    frame: CGRect(x: index % 10 * 70, y: index / 10 * 70, width: 60, height: 60)
                )
                view.isUserInteractionEnabled = false
                container.addSubview(view)
            }
        }
        print("A02 proxies=1000 create=\(proxyTime) views=1000 create=\(viewTime)")
        #expect(container.proxies.count == 1000)
        #expect(container.subviews.count == 1000)
        // Enumerating focus items over the visible bounds returns every intersecting proxy.
        let visibleProxies = container.proxies.filter { $0.frame.intersects(container.bounds) }
        let items = container.focusItems(in: container.bounds)
        #expect(visibleProxies.allSatisfy { proxy in items.contains { $0 === proxy } })
        print("A02 focusItems(in: bounds)=\(items.count) visibleProxies=\(visibleProxies.count)")
    }
#endif
