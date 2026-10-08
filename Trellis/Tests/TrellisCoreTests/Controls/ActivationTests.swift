import Foundation
import Testing

@testable import TrellisCore

// A07 — one default activation for every source (D43), the key press cycle, `isFocused`,
// and accessibility actions. Cases refer to docs/validation/a01-focus-accessibility-contract.md §6.

private func frame(_ x: Double, _ y: Double, _ w: Double = 80, _ h: Double = 80) -> LayoutFrame {
    LayoutFrame(origin: LayoutPoint(x: x, y: y), width: w, height: h)
}

@MainActor
private final class Card: ControlNode {
    var activations: [ActivationSource] = []
    var preventDefaultOn: Set<EventType> = []
    var seen: [EventType] = []

    override init(
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        super.init(style: style, appearance: appearance, environment: environment)
        activation = { [weak self] in
            guard let self, let source = lastActivationSource else { return }
            activations.append(source)
        }
    }

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        seen.append(event.type)
        if preventDefaultOn.contains(event.type) { event.preventDefault() }
    }
}

/// A bubbling ancestor that can veto the default action.
@MainActor
private final class Vetoer: Node {
    var preventDefaultOn: Set<EventType> = []

    override func handleBubble(_ event: Event) {
        if preventDefaultOn.contains(event.type) { event.preventDefault() }
    }
}

@MainActor
private final class Fixture {
    let root = Vetoer()
    let a = Card()
    let b = Card()
    let engine = FocusEngine()
    var snapshot: SemanticSnapshot?
    var epoch: UInt64 = 1

    init() {
        root.addSubnode(a)
        root.addSubnode(b)
        publish()
    }

    func publish() {
        let result = LayoutResult(
            placements: [
                LayoutPlacement(identity: root.id, frame: frame(0, 0, 400, 400)),
                LayoutPlacement(identity: a.id, frame: frame(0, 0)),
                LayoutPlacement(identity: b.id, frame: frame(100, 0)),
            ].filter { placement in
                placement.identity == root.id
                    || root.subnodes.contains { $0.id == placement.identity }
            },
            treeIdentity: root.id
        )
        #expect(root.applyLayoutResult(result))
        guard
            let geometry = HitTestSnapshot(
                root: root,
                mountEpoch: epoch,
                bounds: frame(0, 0, 400, 400)
            )
        else { return }
        let snapshot = SemanticSnapshot(
            geometry: geometry,
            root: root,
            geometryGeneration: 1,
            revision: 1,
            previous: self.snapshot
        )
        self.snapshot = snapshot
        engine.apply(snapshot, root: root)
    }

    @discardableResult
    func key(_ type: EventType, _ key: KeyboardKey, shift: Bool = false, isRepeat: Bool = false)
        -> KeyOutcome
    {
        engine.sendKey(
            KeyData(key: key, isShiftDown: shift, isRepeat: isRepeat),
            type: type,
            root: root
        )
    }

    func press(_ key: KeyboardKey) {
        self.key(.keyDown, key)
        self.key(.keyUp, key)
    }
}

// MARK: - Source matrix (D43)

@Test @MainActor
func a07_returnAndSpaceActivateOnceOnKeyUpWithThePressCycleVisible() {
    let f = Fixture()
    f.engine.focus(f.b.id, root: f.root)
    #expect(f.b.isFocused)
    #expect(!f.a.isFocused)

    #expect(f.key(.keyDown, .returnKey) == .handled)  // 1
    #expect(f.b.isPressed)
    #expect(f.b.activations.isEmpty)
    #expect(f.key(.keyUp, .returnKey) == .handled)
    #expect(!f.b.isPressed)
    #expect(f.b.activations == [.keyboard])
    #expect(f.b.lastActivationSource == .keyboard)
    #expect(f.b.seen == [.focusIn, .keyDown, .keyUp])

    f.press(.space)
    #expect(f.b.activations == [.keyboard, .keyboard])
    f.press(.select)
    #expect(f.b.activations == [.keyboard, .keyboard, .remote])
    #expect(f.a.activations.isEmpty)
}

@Test @MainActor
func a07_repeatKeyDownAndStrayKeyUpNeverActivate() {
    let f = Fixture()
    f.engine.focus(f.b.id, root: f.root)
    f.key(.keyDown, .returnKey)
    f.key(.keyDown, .returnKey, isRepeat: true)  // 2
    f.key(.keyDown, .returnKey, isRepeat: true)
    f.key(.keyUp, .returnKey)
    #expect(f.b.activations == [.keyboard])
    f.key(.keyUp, .returnKey)  // 4: no open cycle
    f.key(.keyUp, .space)
    #expect(f.b.activations == [.keyboard])
    #expect(!f.b.isPressed)
    // A key-up of a different key than the one that opened the cycle does not close it.
    f.key(.keyDown, .space)
    f.key(.keyUp, .returnKey)
    #expect(f.b.isPressed)
    f.key(.keyUp, .space)
    #expect(f.b.activations == [.keyboard, .keyboard])
}

@Test @MainActor
func a07_focusChangeBetweenKeyDownAndKeyUpCancelsTheCycle() {
    let f = Fixture()
    f.engine.focus(f.b.id, root: f.root)
    f.key(.keyDown, .space)
    #expect(f.b.isPressed)
    f.engine.focus(f.a.id, root: f.root)  // 3
    #expect(!f.b.isPressed)
    #expect(!f.b.isFocused)
    #expect(f.a.isFocused)
    f.key(.keyUp, .space)
    #expect(f.b.activations.isEmpty)
    #expect(f.a.activations.isEmpty)
    #expect(!f.a.isPressed)
}

@Test @MainActor
func a07_disablingDuringThePressClearsItAndNeverActivates() {
    let f = Fixture()
    f.engine.focus(f.b.id, root: f.root)
    f.key(.keyDown, .returnKey)
    f.b.isEnabled = false  // 5
    #expect(!f.b.isPressed)
    f.key(.keyUp, .returnKey)
    #expect(f.b.activations.isEmpty)
    #expect(f.b.activate(source: .pointer) == false)
    #expect(f.b.activate(source: .accessibility) == false)
    #expect(f.b.lastActivationSource == nil)
    // Still focused until the publish moves focus away; a new key-down is refused meanwhile.
    f.key(.keyDown, .returnKey)
    #expect(!f.b.isPressed)
    f.publish()
    #expect(f.engine.focusedID == f.a.id)
}

@Test @MainActor
func a07_preventDefaultOnKeyUpOrKeyDownSuppressesActivation() {
    let f = Fixture()
    f.engine.focus(f.b.id, root: f.root)
    f.root.preventDefaultOn = [.keyUp]  // 6: vetoed in bubble on the ancestor
    f.press(.returnKey)
    #expect(f.b.activations.isEmpty)
    #expect(!f.b.isPressed)
    f.root.preventDefaultOn = []
    f.key(.keyUp, .returnKey)  // the vetoed cycle was closed, nothing to complete
    #expect(f.b.activations.isEmpty)

    f.b.preventDefaultOn = [.keyDown]  // vetoed at the target on key-down: no cycle at all
    f.press(.space)
    #expect(!f.b.isPressed)
    #expect(f.b.activations.isEmpty)
    f.b.preventDefaultOn = []
    f.press(.space)
    #expect(f.b.activations == [.keyboard])
}

@Test @MainActor
func a07_activationKeysWithoutFocusAndNavigationKeysReportTheOutcome() {
    let f = Fixture()
    #expect(f.key(.keyDown, .returnKey) == .unhandled)  // nobody focused
    #expect(f.key(.keyDown, .tab) == .handled)  // → A
    #expect(f.engine.focusedID == f.a.id)
    #expect(f.key(.keyUp, .tab) == .unhandled)  // key-up of a navigation key is never consumed
    #expect(f.key(.keyDown, .rightArrow) == .handled)  // → B
    // Nothing further right: the host passes the key on.
    #expect(f.key(.keyDown, .rightArrow) == .unhandled)
    #expect(f.key(.keyDown, .tab) == .unhandled)  // boundary: no keyboard trap
    #expect(f.key(.keyDown, .tab, shift: true) == .handled)  // ← A
    #expect(f.engine.focusedID == f.a.id)
    #expect(f.key(.pointerDown, .tab) == .unhandled)
    #expect(FocusEngine().sendKey(KeyData(key: .tab), type: .keyDown, root: f.root) == .unhandled)
}

@Test @MainActor
func a07_activationMayDisposeTheControlOrDetachTheTreeWithoutASecondDelivery() {
    let f = Fixture()
    f.engine.focus(f.b.id, root: f.root)
    f.b.activation = { [unowned f] in
        f.b.activations.append(.keyboard)
        f.b.dispose()
    }
    f.press(.returnKey)
    #expect(f.b.activations == [.keyboard])
    #expect(f.b.isDisposed)
    f.press(.returnKey)  // the route no longer resolves: nothing is delivered, nothing activates
    #expect(f.b.activations == [.keyboard])

    f.publish()  // focus falls back to A
    #expect(f.engine.focusedID == f.a.id)
    f.a.activation = { [unowned f] in
        f.a.activations.append(.keyboard)
        f.engine.reset()
    }
    f.press(.space)
    #expect(f.a.activations == [.keyboard])
    #expect(f.engine.focusedID == nil)
    #expect(f.key(.keyDown, .space) == .unhandled)
}

// MARK: - Accessibility actions

@Test @MainActor
func a07_accessibilityActivateUsesTheSameActivationAndKeepsKeyboardFocus() {
    let f = Fixture()
    f.engine.focus(f.a.id, root: f.root)
    #expect(f.b.performAccessibilityAction(.activate))  // 7
    #expect(f.b.activations == [.accessibility])
    #expect(f.engine.focusedID == f.a.id)
    #expect(!f.b.isFocused)
    #expect(!f.b.isPressed)

    f.b.isEnabled = false  // 8
    #expect(!f.b.performAccessibilityAction(.activate))
    #expect(f.b.activations == [.accessibility])
}

@Test @MainActor
func a07_customActionsReturnTheHandlerResultAndPlainNodesUseTheClosure() {
    let f = Fixture()
    var received: [AccessibilityAction] = []
    f.b.onAccessibilityAction = { action in  // 9
        received.append(action)
        return action == .custom("share")
    }
    #expect(f.b.performAccessibilityAction(.custom("share")))
    #expect(!f.b.performAccessibilityAction(.custom("unknown")))
    #expect(!f.b.performAccessibilityAction(.increment))
    #expect(received == [.custom("share"), .custom("unknown"), .increment])
    #expect(f.b.activations.isEmpty)  // custom actions never activate

    let text = Node()
    #expect(!text.performAccessibilityAction(.activate))
    text.onAccessibilityAction = { $0 == .increment }
    #expect(text.performAccessibilityAction(.increment))
    #expect(!text.performAccessibilityAction(.activate))
}

@Test @MainActor
func a07_pointerActivationRecordsItsSourceAndStillNeedsUpInside() {
    let f = Fixture()
    let sessions = PointerSessions()
    guard let geometry = HitTestSnapshot(root: f.root, mountEpoch: 1, bounds: frame(0, 0, 400, 400))
    else { return }
    let down = PointerData(point: LayoutPoint(x: 120, y: 20), pointerID: 1)
    sessions.send(.pointerDown, down, snapshot: geometry, root: f.root)
    #expect(f.b.isPressed)
    sessions.send(.pointerUp, down, snapshot: geometry, root: f.root)
    #expect(f.b.activations == [.pointer])
    #expect(f.b.lastActivationSource == .pointer)

    // Pointer and keyboard presses do not interfere: a key cycle survives an unrelated tap.
    f.engine.focus(f.b.id, root: f.root)
    f.key(.keyDown, .returnKey)
    let outside = PointerData(point: LayoutPoint(x: 300, y: 300), pointerID: 2)
    sessions.send(.pointerDown, outside, snapshot: geometry, root: f.root)
    sessions.send(.pointerUp, outside, snapshot: geometry, root: f.root)
    #expect(f.b.isPressed)
    f.key(.keyUp, .returnKey)
    #expect(f.b.activations == [.pointer, .keyboard])
}
