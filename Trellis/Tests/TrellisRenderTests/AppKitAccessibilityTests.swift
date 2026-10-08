#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore

    // A10: the AppKit host as a group of real `NSAccessibilityElement` children — enumeration
    // and reading order, roles/values/help/state, parent links, screen frames through the
    // flipped host, actions (press/custom/increment/decrement), reuse and notifications (D47),
    // two windows kept apart, window moves without layout, stale handlers after re-attach.

    @MainActor
    private func waitForCommit(_ host: TrellisHostView) async {
        for _ in 0..<10_000 where host.layer?.sublayers?.isEmpty != false { await Task.yield() }
    }

    @MainActor
    private func settle() async {
        for _ in 0..<300 { await Task.yield() }
    }

    @MainActor
    private final class Stage {
        let window: NSWindow
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let root = Node()
        let card = Node()
        let title = Node()
        let button = ControlNode()
        let slider = Node()
        let background = ControlNode()
        var notifications: [(NSAccessibility.Notification, NodeID?)] = []
        var activations: [ActivationSource] = []
        var adjustments: [AccessibilityAction] = []

        init(origin: NSPoint = NSPoint(x: 100, y: 100)) {
            window = NSWindow(
                contentRect: NSRect(origin: origin, size: NSSize(width: 400, height: 300)),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
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
            host.attach(root: root)
            host.accessibilityCoordinatorForTesting?.notificationSink = {
                [weak self] notification, id in
                self?.notifications.append((notification, id))
            }
        }

        func element(_ node: Node) -> TrellisAccessibilityElement? {
            host.accessibilityCoordinatorForTesting?.element(for: node.id)
        }

        func screenRect(of node: Node) -> NSRect? {
            guard let frame = node.calculatedFrame else { return nil }

            let hostRect = NSRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
            return window.convertToScreen(host.convert(hostRect, to: nil))
        }
    }

    @Test @MainActor
    func a10_hostExposesRealElementsWithRolesValuesParentsAndScreenFrames() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        #expect(stage.host.isAccessibilityElement() == false)
        #expect(stage.host.accessibilityRole() == .group)
        let roots = try #require(
            stage.host.accessibilityChildren() as? [TrellisAccessibilityElement]
        )
        #expect(roots.map(\.identity) == [stage.card.id, stage.background.id])

        let card = try #require(stage.element(stage.card))
        #expect(card.accessibilityRole() == .group)
        #expect(card.accessibilityLabel() == "Product")
        #expect(card.accessibilityParent() as? NSView === stage.host)
        let children = try #require(card.accessibilityChildren() as? [TrellisAccessibilityElement])
        #expect(children.map(\.identity) == [stage.title.id, stage.button.id, stage.slider.id])
        #expect(children[0].accessibilityParent() as? TrellisAccessibilityElement === card)

        let title = try #require(stage.element(stage.title))
        #expect(title.accessibilityRole() == .staticText)  // header fallback (A01 §3.1)
        let button = try #require(stage.element(stage.button))
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "Buy")
        #expect(button.accessibilityValue() as? String == "0")
        #expect(button.accessibilityHelp() == "Adds to cart")
        #expect(button.accessibilityIdentifier() == "buy")
        #expect(button.isAccessibilityEnabled())
        #expect(button.accessibilityCustomActions()?.map(\.name) == ["Share"])
        let slider = try #require(stage.element(stage.slider))
        #expect(slider.accessibilityRole() == .slider)
        #expect(slider.isAccessibilitySelected())
        #expect(
            slider.isAccessibilitySelectorAllowed(
                #selector(NSAccessibilityElement.accessibilityPerformIncrement)
            )
        )
        #expect(
            !slider.isAccessibilitySelectorAllowed(
                #selector(NSAccessibilityElement.accessibilityPerformPress)
            )
        )

        // Flipped host → window → screen: the button's screen frame includes the window origin.
        #expect(button.accessibilityFrame() == stage.screenRect(of: stage.button))
        #expect(button.accessibilityFrame().size == NSSize(width: 120, height: 44))
        #expect(button.accessibilityFrame().origin.x >= 100)
        #expect(stage.notifications.map(\.0) == [.layoutChanged])
    }

    @Test @MainActor
    func a10_voiceOverActionsRouteThroughTheBridge() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        let button = try #require(stage.element(stage.button))
        let slider = try #require(stage.element(stage.slider))

        #expect(button.accessibilityPerformPress())
        #expect(stage.activations == [.accessibility])
        #expect(stage.host.focusedID == nil)  // D45
        let share = try #require(button.accessibilityCustomActions()?.first)
        #expect(share.handler?() == true)
        #expect(slider.accessibilityPerformIncrement())
        #expect(slider.accessibilityPerformDecrement())
        #expect(stage.adjustments == [.increment, .decrement])
        #expect(!slider.accessibilityPerformPress())

        stage.button.isEnabled = false
        await settle()
        #expect(!button.isAccessibilityEnabled())
        #expect(!button.accessibilityPerformPress())
        #expect(stage.activations == [.accessibility])
    }

    @Test @MainActor
    func a10_reuseValueChangedNotificationsAndTeardown() async throws {
        let stage = Stage()
        await waitForCommit(stage.host)
        let button = try #require(stage.element(stage.button))
        stage.notifications.removeAll()

        stage.button.accessibility.value = "1"
        await settle()
        #expect(stage.element(stage.button) === button)
        #expect(button.accessibilityValue() as? String == "1")
        #expect(stage.notifications.map(\.0) == [.layoutChanged, .valueChanged])
        #expect(stage.notifications.last?.1 == stage.button.id)

        stage.button.accessibility.value = "1"  // same value: nothing
        stage.title.appearance.cornerRadius = 3  // paint-only: nothing
        await settle()
        #expect(stage.notifications.count == 2)

        stage.host.setFocusScope(stage.card.id)
        #expect(
            (stage.host.accessibilityChildren() as? [TrellisAccessibilityElement])?.map(\.identity)
                == [stage.card.id]
        )
        #expect(stage.element(stage.background) == nil)
        stage.host.setFocusScope(nil)
        #expect(stage.host.nativeAccessibilityElementCount == 5)

        // Re-attach: the old element the OS may still hold never reaches the new tree.
        stage.host.detach()
        #expect(stage.host.nativeAccessibilityElementCount == 0)
        #expect(stage.host.accessibilityChildren()?.isEmpty == true)
        #expect(!button.accessibilityPerformPress())
        stage.host.attach(root: stage.root)
        await waitForCommit(stage.host)
        #expect(stage.element(stage.button) !== button)
        #expect(!button.accessibilityPerformPress())
        #expect(stage.element(stage.button)?.accessibilityPerformPress() == true)
        #expect(stage.activations == [.accessibility])
    }

    @Test @MainActor
    func a10_twoWindowsKeepTheirElementsApartAndAWindowMoveUpdatesScreenFrames() async throws {
        let first = Stage(origin: NSPoint(x: 100, y: 100))
        let second = Stage(origin: NSPoint(x: 700, y: 500))
        await waitForCommit(first.host)
        await waitForCommit(second.host)
        let firstButton = try #require(first.element(first.button))
        let secondButton = try #require(second.element(second.button))
        #expect(firstButton !== secondButton)
        #expect(firstButton.accessibilityFrame().origin != secondButton.accessibilityFrame().origin)
        #expect(second.element(first.button) == nil)
        #expect(first.element(first.card)?.accessibilityParent() as? NSView === first.host)
        #expect(second.element(second.card)?.accessibilityParent() as? NSView === second.host)

        // Move the first window: no layout pass, the screen frame follows the notification.
        let committed = first.button.calculatedFrame
        let before = firstButton.accessibilityFrame()
        first.window.setFrameOrigin(NSPoint(x: 160, y: 140))
        await settle()
        #expect(first.button.calculatedFrame == committed)
        #expect(firstButton.accessibilityFrame() == before.offsetBy(dx: 60, dy: 40))
        #expect(firstButton.accessibilityFrame() == first.screenRect(of: first.button))
        #expect(first.element(first.button) === firstButton)
    }
#endif
