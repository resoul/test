import Foundation

/// A pressable primitive with a single closure activation — no Flux/`ActionPipe` dependency
/// (H06, D22/G07). Ported in spirit from Weave's `ButtonNode`/`ControlNode` (`Controls.swift`),
/// with Flux removed and activation wired through the gesture pipeline (H03–H05) instead of an
/// `ActionPipe`.
///
/// `isPressed` tracks live pointer geometry, independent of gesture arbitration: it goes `true`
/// on an accepted `pointerDown` (the route only reaches this node when the down point is
/// already within it, D27), `false` the moment the pointer leaves this node's own committed
/// bounds, and `true` again if it comes back — checked against `Event.snapshot`, the commit in
/// effect at that event, not the one from `pointerDown` (D34). It goes `false` unconditionally
/// on `pointerUp`/`pointerCancel`, whether or not activation follows.
///
/// Activation is separate and stricter: an internal `TapRecognizer`, registered on this node
/// like any other (`Node.addGestureRecognizer`), makes it the default action of a winning Tap
/// (D29 (5)) — it never fires if a sibling recognizer (e.g. a `PanRecognizer`) wins arbitration,
/// if the pointer session is cancelled, or if `preventDefault()` was called. Even when Tap ends,
/// activation additionally requires the up point to fall inside this node's own bounds in the
/// *latest* commit (D22/D34) — `up-inside`, not just "close enough to the down point": a
/// decorative child inside this node does not change that (H01 §5 (7); the child may be the
/// topmost hit, this node is still on the route and still asks about its own geometry via
/// `HitTestSnapshot.contains(_:node:)`).
///
/// Since A07 (D43) there is one default activation for every input source: a winning Tap
/// (`.pointer`), a Return/Space key-up after a key-down on this same focused control
/// (`.keyboard`), a Siri Remote Select (`.remote`), and an assistive-technology activate
/// (`.accessibility`) — all through `activate(source:)`, all refused while `isEnabled` is
/// `false`. `isFocused` mirrors the focus engine's `focusIn`/`focusOut` and is independent of
/// `isPressed`.
///
/// Ownership: retains its own `TapRecognizer` and the `activation` closure; the closure should
/// capture this node weakly, since the node owns it and it is free to remove or dispose this
/// node or any part of the tree. Isolation: MainActor. Errors: none. Cancellation: a cancelled
/// or lost session clears `isPressed` and never activates; losing focus or being disabled
/// cancels a key press cycle the same way.
@MainActor
open class ControlNode: Node {
    /// Called once per completed press-release cycle: Tap won arbitration and the up point is
    /// still inside this node's committed bounds (D22, D29 (5)).
    ///
    /// Ownership: the node retains the closure; capture `self` weakly. Isolation: MainActor.
    /// Errors: none. Cancellation: never called for a failed, cancelled, or lost session, nor
    /// for an up outside this node's latest committed geometry.
    public var activation: (@MainActor () -> Void)?

    /// Whether the pointer is currently down and within this node's own committed bounds.
    /// Changing it marks this node's appearance dirty — the paint-only invalidation path
    /// (H06): a subclass observes it (`didSet` on a stored property that mirrors it, or by
    /// overriding `arrangeSubnodes()`/style) to show a pressed appearance.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }

            markAppearanceDirty()
        }
    }

    /// Whether this control holds keyboard/remote focus (A07, D39/D45): `true` between the
    /// `focusIn` and `focusOut` events the focus engine delivers to it. Independent of
    /// `isPressed` and of the VoiceOver cursor. Changing it marks appearance dirty so a
    /// subclass can draw a focus ring.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }

            markAppearanceDirty()
        }
    }

    /// The source of the most recent activation, or `nil` before the first one (D43) — read
    /// it inside `activation` to tell a tap from a key press from an assistive-technology
    /// action.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var lastActivationSource: ActivationSource?

    /// Whether this control takes part in interaction (A03, D41) — the single source of
    /// "enabled" for focus eligibility, every activation source and the accessibility state.
    /// Disabling a pressed control clears `isPressed` and never activates for that press;
    /// the change marks semantics dirty (republish) and appearance dirty (a subclass may
    /// draw a disabled look). Assigning the same value is a no-op.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: disabling
    /// cancels the current press without activation.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }

            if !isEnabled {
                trackedPointerID = nil
                pressedKey = nil
                isPressed = false
            }
            Log.on(.semantics, "changed", node: id, "kind=isEnabled value=\(isEnabled)")
            markSemanticsDirty()
            markAppearanceDirty()
        }
    }

    package override var isEnabledForSemantics: Bool { isEnabled }
    override var isActivatable: Bool { true }

    private let tap = TapRecognizer()
    private var trackedPointerID: UInt64?
    private var lastSnapshot: HitTestSnapshot?
    /// The key whose press cycle is open — set by an accepted key-down default action,
    /// cleared by key-up, focus loss, disable or dispose (A07).
    private var pressedKey: KeyboardKey?

    /// Creates a control with no activation closure and an internal `TapRecognizer` already
    /// registered.
    ///
    /// Ownership: retains the recognizer. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public override init(
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        super.init(style: style, appearance: appearance, environment: environment)
        // Controls opt into focus (D37) and into the semantic tree (D42) by default; a plain
        // `Node` does neither. The author still supplies a meaningful label.
        focus.isFocusable = true
        accessibility.isElement = true
        addGestureRecognizer(tap)
        tap.onTap = { [weak self] point in self?.tapEnded(at: point) }
    }

    /// Reached only when this node is itself the pointer target (no decorative child under the
    /// point). Tracks the same way `handleBubble` does.
    ///
    /// Ownership: `event` is borrowed. Isolation: MainActor. Errors: none. Cancellation: see
    /// class documentation.
    open override func handleEvent(_ event: Event) { track(event) }

    /// Reached on every event of a session that targets a descendant of this node — a
    /// decorative child under the point (H01 §5 (7)).
    ///
    /// Ownership: `event` is borrowed. Isolation: MainActor. Errors: none. Cancellation: see
    /// class documentation.
    open override func handleBubble(_ event: Event) { track(event) }

    /// The one default activation (D43): runs `activation` once if this control is enabled
    /// and not disposed, recording `source`. Every input path ends here — a subclass that
    /// wants to intercept activation overrides this and calls `super` when it agrees.
    ///
    /// Ownership: nothing escapes; `activation` may dispose this node or detach the tree.
    /// Isolation: MainActor. Errors: `false` when refused (disabled or disposed). Cancellation:
    /// not applicable.
    @discardableResult
    open func activate(source: ActivationSource) -> Bool {
        guard isEnabled, !isDisposed else {
            Log.on(.event, "activation-refused", node: id, "source=\(source) enabled=\(isEnabled)")
            return false
        }

        lastActivationSource = source
        Log.on(.event, "activated", node: id, "source=\(source)")
        activation?()
        return true
    }

    /// `.activate` is this control's default activation (`.accessibility` source); any other
    /// action goes to `Node`'s handler closure.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: `false` when not handled.
    /// Cancellation: not applicable.
    open override func performAccessibilityAction(_ action: AccessibilityAction) -> Bool {
        guard action == .activate else { return super.performAccessibilityAction(action) }

        return activate(source: .accessibility)
    }

    /// Ends the tree on `dispose()`: an open key cycle can never activate afterwards.
    ///
    /// Ownership: releases as `Node.dispose()`. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal.
    open override func dispose() {
        pressedKey = nil
        super.dispose()
    }

    /// Closes an open key press cycle without activation (A08): the platform cancelled the
    /// press (`pressesCancelled`, window loss) and no key-up will follow.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: this is
    /// one; idempotent.
    func cancelKeyPress() {
        guard pressedKey != nil else { return }

        pressedKey = nil
        if trackedPointerID == nil { isPressed = false }
    }

    /// The default action of a key event addressed to this focused control (A07, D43), run by
    /// the focus engine *after* three-phase dispatch unless a handler called
    /// `preventDefault()`: an accepted, non-repeat key-down of Return/Space/Select opens a
    /// press cycle (`isPressed`); the matching key-up closes it and activates exactly once. A
    /// key-up without an open cycle, a repeat, a different key, or a prevented default never
    /// activates; a prevented key-up still closes the cycle so a later stray key-up is a no-op.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: focus
    /// loss, disable and dispose close the cycle without activation.
    func handleKeyDefault(_ event: Event, defaultPrevented: Bool, source: ActivationSource) {
        guard let key = event.key else { return }

        switch event.type {
        case .keyDown:
            guard !defaultPrevented, !key.isRepeat, isEnabled, isFocused, pressedKey == nil
            else { return }

            pressedKey = key.key
            isPressed = true
        case .keyUp:
            let matched = pressedKey == key.key
            guard matched else { return }

            pressedKey = nil
            isPressed = false
            if !defaultPrevented { activate(source: source) }
        default:
            break
        }
    }

    private func track(_ event: Event) {
        switch event.type {
        case .focusIn:
            isFocused = true
            return
        case .focusOut:
            // A press cycle cannot outlive focus: the key-up would reach someone else.
            isFocused = false
            let hadKeyCycle = pressedKey != nil
            pressedKey = nil
            if hadKeyCycle, trackedPointerID == nil { isPressed = false }
            return
        default:
            break
        }
        // Pointer-only bookkeeping: a focus or key event has no coordinates and must not be
        // read as a press at (0, 0) (ADR 0013, D43).
        guard let data = event.pointer else { return }

        lastSnapshot = event.snapshot
        switch event.type {
        case .pointerDown where trackedPointerID == nil && isEnabled:
            trackedPointerID = data.pointerID
            // The route only reaches this node because the down point hit it or a descendant
            // of it — always "inside" at down (D27); no geometry check needed here.
            isPressed = true
        case .pointerMove where trackedPointerID == data.pointerID:
            isPressed = event.snapshot?.contains(data.point, node: id) ?? isPressed
        case .pointerUp where trackedPointerID == data.pointerID:
            trackedPointerID = nil
            isPressed = false
        case .pointerCancel where trackedPointerID == data.pointerID:
            trackedPointerID = nil
            isPressed = false
        default:
            break
        }
    }

    private func tapEnded(at point: LayoutPoint) {
        // `isPressed` is already `false` here: `track(_:)` ran during dispatch, before the
        // arena — which is what calls this — sees the same `pointerUp` event (D29 (1)).
        guard lastSnapshot?.contains(point, node: id) == true else { return }

        activate(source: .pointer)
    }
}

/// Which input path activated a control (A07, D43).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ActivationSource: Sendable, Hashable {
    /// A winning Tap with the up point inside the control (H06).
    case pointer
    /// Return/Space key-up after a key-down on the focused control.
    case keyboard
    /// Siri Remote Select on the focused control (tvOS).
    case remote
    /// An assistive-technology activate action.
    case accessibility
}
