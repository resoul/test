import Foundation

/// Event categories the platform-neutral dispatcher understands (H03, D20; A04/A07, D48).
/// Pointer events carry `PointerData`; `focusIn`/`focusOut` carry `FocusData` and are
/// dispatched by the focus engine along the committed route of the node losing or gaining
/// focus (D39); `keyDown`/`keyUp` carry `KeyData` and go to the focused node (A07). Scroll
/// is not in this stage.
///
/// Ownership: the value is copied by an `Event`. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum EventType: Sendable, Hashable {
    case pointerDown
    case pointerMove
    case pointerUp
    case pointerCancel
    case focusIn
    case focusOut
    case keyDown
    case keyUp
}

/// Where a callback sits in one dispatch: ancestors first (capture), the target, ancestors
/// again (bubble).
///
/// Ownership: the value is owned by the dispatcher. Isolation: MainActor during dispatch.
/// Errors: none. Cancellation: not applicable.
public enum EventPhase: Sendable, Hashable {
    case capturing
    case atTarget
    case bubbling
}

/// Immutable pointer payload as the host adapters normalize it (D30): `point` in host bounds,
/// origin top-left, in points — the same space `HitTestSnapshot` and every committed frame use;
/// `pointerID` is stable from down to up/cancel and never reused while that session is active.
/// The identifier's namespace is the bridge the event arrived at — there is no window id.
///
/// Ownership: the value owns its coordinates. Isolation: none. Errors: none — `LayoutPoint` is
/// finite by construction; adapters reject non-finite input before it gets here.
/// Cancellation: not applicable.
public struct PointerData: Sendable, Hashable {
    /// Host point in points, origin top-left of the host bounds.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let point: LayoutPoint

    /// Identity of the pointer session, stable from down to up/cancel.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let pointerID: UInt64

    /// Creates pointer data.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(point: LayoutPoint, pointerID: UInt64) {
        self.point = point
        self.pointerID = pointerID
    }
}

/// Immutable focus-transition payload (A04, D39): the identities either side of the
/// transition and why it happened. The same value goes to the node losing focus (`focusOut`)
/// and to the node gaining it (`focusIn`).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct FocusData: Sendable, Hashable {
    /// The node that had focus before, if any.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let previous: NodeID?

    /// The node that has focus after, if any.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let next: NodeID?

    /// What caused the transition.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let reason: FocusChangeReason

    /// Creates focus data.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(previous: NodeID?, next: NodeID?, reason: FocusChangeReason) {
        self.previous = previous
        self.next = next
        self.reason = reason
    }
}

/// The keys the platform-neutral input path understands (A07/A08, D38/D43): the navigation
/// keys of a keyboard and the Siri Remote, and the keys that activate a control. Host
/// adapters map `UIPress`/`NSEvent` onto these; anything else stays with the platform.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum KeyboardKey: Sendable, Hashable, CaseIterable {
    case tab
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case returnKey
    case space
    /// Siri Remote / keyboard "select" — the tvOS activation key.
    case select
}

/// Immutable key payload (A07, D48).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct KeyData: Sendable, Hashable {
    /// The key.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let key: KeyboardKey

    /// Whether Shift was held — `tab` with Shift is `.previous` (D38).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isShiftDown: Bool

    /// Whether this `keyDown` is an auto-repeat of a key still held; never starts a second
    /// press cycle (A07).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let isRepeat: Bool

    /// Creates key data.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(key: KeyboardKey, isShiftDown: Bool = false, isRepeat: Bool = false) {
        self.key = key
        self.isShiftDown = isShiftDown
        self.isRepeat = isRepeat
    }
}

/// Immutable event payload — one case per input kind (D48, ADR 0013).
///
/// Ownership: associated values are copied. Isolation: none. Errors: none. Cancellation: not
/// applicable.
public enum EventPayload: Sendable, Hashable {
    case pointer(PointerData)
    case focus(FocusData)
    case key(KeyData)
}

/// Mutable context of one synchronous MainActor dispatch. Handlers read `phase` and the
/// payload, and may call `stopPropagation()` or `preventDefault()`; nothing else changes
/// during dispatch. The target is an identity from the committed snapshot (D20), never a live
/// reference.
///
/// Ownership: the dispatcher owns the event for the duration of `dispatch`; handlers borrow
/// it and must not keep it. Isolation: MainActor. Errors: none. Cancellation:
/// `stopPropagation()` ends callbacks after the current one; `preventDefault()` only marks the
/// event — neither undoes side effects handlers already had.
@MainActor
public final class Event {
    /// The event's category.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let type: EventType

    /// The committed node the event is addressed to — the hit at `pointerDown`, and for the
    /// rest of that pointer session the same node (D27).
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let targetID: NodeID

    /// The payload.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let payload: EventPayload

    /// The committed snapshot in effect when this event was created — the "last commit" a
    /// handler should measure geometry against (H06, D22/D34), not necessarily the one from
    /// `pointerDown`: `PointerSessions` passes its current snapshot with every event of a
    /// session, so a commit between down and up is reflected here for that session's later
    /// events. `nil` for events built without one — tests, and `PointerSessions`'s own
    /// synthesized cancel on session cancellation, which never needs committed geometry: a
    /// cancel always clears pressed-state unconditionally, it never activates anything.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let snapshot: HitTestSnapshot?

    /// The phase of the callback currently running; `.capturing` before dispatch starts.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var phase: EventPhase = .capturing

    /// Whether a handler has called `stopPropagation()`.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isPropagationStopped = false

    /// Whether a handler has called `preventDefault()`.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isDefaultPrevented = false

    /// Creates an event with both flags clear.
    ///
    /// Ownership: the payload is copied. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init(
        type: EventType,
        targetID: NodeID,
        payload: EventPayload,
        snapshot: HitTestSnapshot? = nil
    ) {
        self.type = type
        self.targetID = targetID
        self.payload = payload
        self.snapshot = snapshot
    }

    /// The pointer payload, or `nil` for a focus or key event (ADR 0013): a handler that only
    /// deals with pointers guards on this instead of receiving made-up coordinates (D43).
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var pointer: PointerData? {
        if case .pointer(let data) = payload { return data }
        return nil
    }

    /// The focus payload, or `nil` for any other event.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var focus: FocusData? {
        if case .focus(let data) = payload { return data }
        return nil
    }

    /// The key payload, or `nil` for any other event.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var key: KeyData? {
        if case .key(let data) = payload { return data }
        return nil
    }

    /// Stops capture/target/bubble callbacks after the current one. Side effects of callbacks
    /// already run stay; the default action is unaffected — that is `preventDefault()` (D20).
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: terminal
    /// for this dispatch's remaining callbacks.
    public func stopPropagation() { isPropagationStopped = true }

    /// Marks the default action — recognizers and the control activation they lead to (D29) —
    /// as not to be performed. Propagation continues.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: terminal
    /// for this event's default action.
    public func preventDefault() { isDefaultPrevented = true }

    func setPhase(_ phase: EventPhase) { self.phase = phase }
}

/// What one dispatch did.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct EventResult: Sendable, Hashable {
    /// `stopPropagation()` was called by some handler.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let propagationStopped: Bool

    /// `preventDefault()` was called by some handler.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let defaultPrevented: Bool

    /// The route no longer matched the live tree at some point — a node on it was disposed,
    /// detached or reparented, before or during dispatch (D28). Callbacks after that point were
    /// not run; the pointer session that produced the event must be cancelled (D21).
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let routeBroken: Bool

    /// The target callback ran.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let reachedTarget: Bool
}
