#if canImport(UIKit)
    import Testing
    import UIKit

    @testable import TrellisCore
    @testable import TrellisRender
    @testable import TrellisUIKit

    // A09: the UIKit host as an accessibility container of real `UIAccessibilityElement`
    // proxies — enumeration and reading order, label/value/hint/traits/state, screen frames,
    // actions routed back through the bridge's live guard, reuse and notifications (D47),
    // modal exposure (D40). Runs on the iOS and tvOS Simulators through `xcodebuild test`.

    @MainActor
    private func waitForCommit(_ host: TrellisHostView) async {
        for _ in 0..<10_000 where host.layer.sublayers?.isEmpty != false { await Task.yield() }
    }

    @MainActor
    private func settle() async {
        for _ in 0..<300 { await Task.yield() }
    }

    @MainActor
    private final class Stage {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let host = TrellisHostView()
        let root = Node()
        let card = Node()
        let title = Node()
        let button = ControlNode()
        let slider = Node()
        let background = ControlNode()
        var notifications: [(UIAccessibility.Notification, NodeID?)] = []
        var activations: [ActivationSource] = []
        var adjustments: [AccessibilityAction] = []

        init() {
            host.frame = window.bounds
            window.addSubview(host)
            window.makeKeyAndVisible()
            root.style {
                $0.flexDirection = .column; $0.gap = 10
            }
            card.style {
                $0.flexDirection = .column; $0.gap = 4; $0.width = 300
            }
            card.accessibility = AccessibilityProperties(isElement: true, label: "Product")
            title.style {
                $0.width = 200; $0.height = 20
            }
            title.accessibility = AccessibilityProperties(
                isElement: true,
                label: "Title",
                role: .header
            )
            button.style {
                $0.width = 120; $0.height = 44
            }
            button.accessibility = AccessibilityProperties(
                isElement: true,
                label: "Buy",
                value: "0",
                hint: "Adds to cart",
                identifier: "buy",
                customActions: [AccessibilityCustomAction(id: "share", name: "Share")]
            )
            slider.style {
                $0.width = 200; $0.height = 30
            }
            slider.accessibility = AccessibilityProperties(
                isElement: true,
                label: "Volume",
                value: "5",
                role: .adjustable,
                isSelected: true,
                actions: [.increment, .decrement]
            )
            background.style {
                $0.width = 100; $0.height = 40
            }
            background.accessibility.label = "Background"
            root.addSubnode(card)
            card.addSubnode(title)
            card.addSubnode(button)
            card.addSubnode(slider)
            root.addSubnode(background)
            button.activation = { [weak self, weak button] in
                if let source = button?.lastActivationSource { self?.activations.append(source) }
            }
            button.onAccessibilityAction = { $0 == .custom("share") }
            slider.onAccessibilityAction = { [weak self] action in
                guard action == .increment || action == .decrement else { return false }

                self?.adjustments.append(action)
                return true
            }
            host.accessibilityNotificationSink = { [weak self] notification, id in
                self?.notifications.append((notification, id))
            }
            host.attach(root: root)
        }

        func proxy(_ node: Node) -> TrellisNodeProxy? {
            host.proxyCoordinatorForTesting?.proxy(for: node.id)
        }
    }

    @Test @MainActor
    func a09_hostExposesTheTreeAsProxiesWithPropertiesAndScreenFrames() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        #expect(stage.host.isAccessibilityElement == false)
        let roots = try #require(stage.host.accessibilityElements as? [TrellisNodeProxy])
        #expect(roots.map(\.identity) == [stage.card.id, stage.background.id])

        let card = try #require(stage.proxy(stage.card))
        #expect(card.isAccessibilityElement == false)  // labelled group (A01 §3.2)
        #expect(card.accessibilityLabel == "Product")
        #expect(card.accessibilityContainerType == .semanticGroup)
        let children = try #require(card.accessibilityElements as? [TrellisNodeProxy])
        #expect(children.map(\.identity) == [stage.title.id, stage.button.id, stage.slider.id])

        let title = try #require(stage.proxy(stage.title))
        #expect(title.isAccessibilityElement)
        #expect(title.accessibilityTraits == .header)
        let button = try #require(stage.proxy(stage.button))
        #expect(button.accessibilityLabel == "Buy")
        #expect(button.accessibilityValue == "0")
        #expect(button.accessibilityHint == "Adds to cart")
        #expect(button.accessibilityIdentifier == "buy")
        #expect(button.accessibilityTraits == .button)
        #expect(button.accessibilityCustomActions?.map(\.name) == ["Share"])
        let slider = try #require(stage.proxy(stage.slider))
        #expect(slider.accessibilityTraits == [.adjustable, .selected])

        // Screen frame: the committed visible bounds through the host's screen conversion.
        let committed = try #require(stage.button.calculatedFrame)
        let expected = UIAccessibility.convertToScreenCoordinates(
            TrellisNodeProxy.cgRect(committed),
            in: stage.host
        )
        #expect(button.accessibilityFrame == expected)
        #expect(expected.size == CGSize(width: 120, height: 44))
        #expect(stage.notifications.map(\.0) == [.screenChanged])  // first tree of the mount
    }

    @Test @MainActor
    func a09_actionsRouteThroughTheBridgeAndRespectEnabledAndStaleness() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        let button = try #require(stage.proxy(stage.button))
        let slider = try #require(stage.proxy(stage.slider))

        #expect(button.accessibilityActivate())
        #expect(stage.activations == [.accessibility])
        #expect(stage.host.focusedID == nil)  // D45: never moves keyboard focus
        let share = try #require(button.accessibilityCustomActions?.first)
        #expect(share.actionHandler?(share) == true)
        slider.accessibilityIncrement()
        slider.accessibilityDecrement()
        #expect(stage.adjustments == [.increment, .decrement])
        #expect(!slider.accessibilityActivate())  // not activatable, no handler for activate

        stage.button.isEnabled = false
        await settle()
        #expect(button.accessibilityTraits.contains(.notEnabled))
        #expect(!button.accessibilityActivate())
        #expect(stage.activations == [.accessibility])

        // A proxy the OS may still hold after a detach never reaches a node — not even after
        // the same root is attached again and its NodeIDs are valid once more.
        stage.button.isEnabled = true
        stage.host.detach()
        #expect(!button.accessibilityActivate())
        stage.host.attach(root: stage.root)
        await waitForCommit(stage.host)
        #expect(stage.proxy(stage.button) !== button)
        #expect(!button.accessibilityActivate())
        #expect(stage.proxy(stage.button)?.accessibilityActivate() == true)
        #expect(stage.activations == [.accessibility, .accessibility])
    }

    @Test @MainActor
    func a09_valueChangeKeepsIdentityNoOpDoesNotNotifyAndModalHidesTheBackground() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        let button = try #require(stage.proxy(stage.button))
        stage.notifications.removeAll()

        stage.button.accessibility.value = "1"
        await settle()
        #expect(stage.proxy(stage.button) === button)
        #expect(button.accessibilityValue == "1")
        #expect(stage.notifications.map(\.0) == [.layoutChanged])

        stage.button.accessibility.value = "1"  // same value: no publish, no notification
        stage.title.appearance.cornerRadius = 3  // paint-only: no tree change
        await settle()
        #expect(stage.notifications.count == 1)

        stage.host.focus(stage.button.id)
        stage.host.setFocusScope(stage.card.id)
        let roots = try #require(stage.host.accessibilityElements as? [TrellisNodeProxy])
        #expect(roots.map(\.identity) == [stage.card.id])
        #expect(stage.proxy(stage.background) == nil)
        #expect(stage.notifications.last?.0 == .screenChanged)
        #expect(stage.notifications.last?.1 == stage.button.id)  // the cursor is offered the focus
        #expect(!stage.host.performAccessibilityAction(.activate, on: stage.background.id))

        stage.host.setFocusScope(nil)
        #expect((stage.host.accessibilityElements as? [TrellisNodeProxy])?.count == 2)
        #expect(stage.notifications.last?.0 == .screenChanged)
    }

    @Test @MainActor
    func a09_resizeAndWindowMoveUpdateFramesWithoutTouchingIdentity() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        let button = try #require(stage.proxy(stage.button))
        let before = button.accessibilityFrame

        // The host moves inside its window: whatever layout the platform runs for the new
        // safe area, the proxy's screen frame is always the host-space conversion of the
        // committed frame — computed on read, never cached from an older commit — and the
        // proxy keeps its identity.
        stage.host.frame.origin.x += 40
        stage.host.layoutIfNeeded()
        await settle()
        let moved = try #require(stage.button.calculatedFrame)
        #expect(
            button.accessibilityFrame
                == UIAccessibility.convertToScreenCoordinates(
                    TrellisNodeProxy.cgRect(moved),
                    in: stage.host
                )
        )
        #expect(button.accessibilityFrame.size == before.size)
        #expect(stage.proxy(stage.button) === button)

        // Resize: a new commit, a new frame, the same proxy.
        stage.host.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        stage.host.setNeedsLayout()
        stage.host.layoutIfNeeded()
        await settle()
        #expect(stage.proxy(stage.button) === button)
        #expect(button.frame.size == CGSize(width: 120, height: 44))
    }
#endif
