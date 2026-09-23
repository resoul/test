import Foundation

/// State of a recognizer's current pointer session (H05, D31).
///
/// Ownership: the recognizer owns its state. Isolation: MainActor. Errors: none.
/// Cancellation: `.failed` and `.cancelled` never lead to an activation.
public enum GestureState: Sendable, Hashable {
    /// Waiting: nothing seen yet, or seen nothing that decides.
    case possible
    /// The gesture has started (a continuous gesture, e.g. Pan past its threshold).
    case began
    /// A continuous gesture progressed.
    case changed
    /// The gesture completed — the activation moment.
    case ended
    /// The gesture cannot happen in this session (Tap moved past its slop).
    case failed
    /// The session was cancelled from outside: pointer cancel, host lifecycle, arbitration loss.
    case cancelled
}

/// What one recognizer did with one event — the transition it made, or `.ignored`.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum GestureResult: Sendable, Hashable {
    case ignored
    case began
    case changed
    case ended
    case failed
    case cancelled
}

/// Thresholds recognizers decide by (D31), in host points. One value, injected into every
/// recognizer, tested at, below and above each threshold.
///
/// Ownership: an immutable value copied into recognizers. Isolation: none. Errors: negative or
/// non-finite values fall back to the defaults. Cancellation: not applicable.
public struct GestureConfiguration: Sendable, Hashable {
    /// How far the pointer may travel from its down point and still count as a tap. Movement
    /// *beyond* this fails the tap; exactly this far is still a tap.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let tapSlop: Double

    /// Distance from the down point past which a pan begins. Exactly this far does not begin.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let panThreshold: Double

    /// Creates a configuration; both defaults are 10 pt (D31).
    ///
    /// Ownership: values are copied. Isolation: none. Errors: invalid values use the defaults.
    /// Cancellation: not applicable.
    public init(tapSlop: Double = 10, panThreshold: Double = 10) {
        self.tapSlop = tapSlop.isFinite && tapSlop >= 0 ? tapSlop : 10
        self.panThreshold = panThreshold.isFinite && panThreshold >= 0 ? panThreshold : 10
    }
}

/// A pointer-session state machine that the arena feeds events to (H05, D29). Registered on
/// a `Node` with `addGestureRecognizer(_:)`; collected into the session's arena at
/// `pointerDown` along the route — the target's first, then each ancestor's — in registration
/// order. Ported in spirit from Weave's `GestureRecognizer`; the arena, not the recognizer,
/// knows about sessions.
///
/// Ownership: retained by the node it is registered on and by the arena of a live session.
/// Isolation: MainActor. Errors: unexpected event types are ignored. Cancellation: `reset()`
/// ends the current session without activation and is idempotent.
@MainActor
public protocol GestureRecognizer: AnyObject {
    /// The state of the current session.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    var state: GestureState { get }

    /// Feeds one event of the session; returns the transition made.
    ///
    /// Ownership: `event` is borrowed. Isolation: MainActor. Errors: none. Cancellation: a
    /// `.pointerCancel` event yields `.cancelled`.
    func handle(_ event: Event) -> GestureResult

    /// Ends the session without activation: an active gesture (`.began`/`.changed`) reports
    /// `.cancelled` exactly once to its callbacks, a waiting one goes quietly back to
    /// `.possible`. Idempotent.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: this is it.
    func reset()
}

func distance(_ lhs: LayoutPoint, _ rhs: LayoutPoint) -> Double {
    let x = lhs.x - rhs.x
    let y = lhs.y - rhs.y
    return (x * x + y * y).squareRoot()
}

/// A single press and release within `tapSlop` of the down point (D31). No maximum duration.
///
/// Ownership: retained by the node it is registered on. Isolation: MainActor. Errors: none.
/// Cancellation: movement past the slop fails the tap; pointer cancel and `reset()` cancel it.
@MainActor
public final class TapRecognizer: GestureRecognizer {
    /// The state of the current session.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var state: GestureState = .possible

    /// Called once per completed tap with the up point (host coordinates).
    /// Ownership: the recognizer retains the closure; capture the node weakly. Isolation:
    /// MainActor. Errors: none. Cancellation: not called for failed or cancelled sessions.
    public var onTap: (@MainActor (LayoutPoint) -> Void)?

    private let configuration: GestureConfiguration
    private var down: PointerData?

    /// Creates a tap recognizer.
    ///
    /// Ownership: the configuration is copied. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        self.configuration = configuration
    }

    /// Feeds one event of the session; returns the transition made.
    ///
    /// Ownership: `event` is borrowed. Isolation: MainActor. Errors: none. Cancellation: a
    /// `.pointerCancel` event yields `.cancelled`.
    public func handle(_ event: Event) -> GestureResult {
        // Recognizers only ever see pointer events (D29: the arena runs on pointer sessions);
        // a non-pointer event is ignored rather than read as a press at (0, 0).
        guard let data = event.pointer else { return .ignored }

        switch event.type {
        case .pointerDown where down == nil && state == .possible:
            down = data
            return .ignored
        case .pointerMove where down?.pointerID == data.pointerID:
            guard let down, distance(down.point, data.point) <= configuration.tapSlop else {
                self.down = nil
                state = .failed
                return .failed
            }

            return .ignored
        case .pointerUp where down?.pointerID == data.pointerID:
            guard let down, distance(down.point, data.point) <= configuration.tapSlop else {
                self.down = nil
                state = .failed
                return .failed
            }

            self.down = nil
            state = .ended
            onTap?(data.point)
            return .ended
        case .pointerCancel where down?.pointerID == data.pointerID:
            down = nil
            state = .cancelled
            return .cancelled
        default:
            return .ignored
        }
    }

    /// Ends the session without activation; idempotent. A tap is never `.began`, so this is
    /// always quiet.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: this is it.
    public func reset() {
        down = nil
        state = .possible
    }
}

/// One step of a pan, in host coordinates (D31).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: `state ==
/// .cancelled` is the last step of a session and carries the last known point.
public struct PanGesture: Sendable, Hashable {
    /// `.began`, `.changed`, `.ended` or `.cancelled`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let state: GestureState

    /// The down point.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let start: LayoutPoint

    /// The current point.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let current: LayoutPoint

    /// `current − start`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let translation: LayoutPoint

    /// `current − previous step's current`; at `.began`, `current − start`.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let delta: LayoutPoint
}

/// A drag that begins once the pointer travels past `panThreshold` from its down point and
/// then reports every move until up or cancel (D31).
///
/// Ownership: retained by the node it is registered on. Isolation: MainActor. Errors: none.
/// Cancellation: pointer cancel, `reset()` while active → one `.cancelled` step.
@MainActor
public final class PanRecognizer: GestureRecognizer {
    /// The state of the current session.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var state: GestureState = .possible

    /// Called for every step: `.began` once, `.changed` per move, then `.ended` or
    /// `.cancelled` exactly once.
    /// Ownership: the recognizer retains the closure; capture the node weakly. Isolation:
    /// MainActor. Errors: none. Cancellation: `.cancelled` is delivered once.
    public var onPan: (@MainActor (PanGesture) -> Void)?

    private let configuration: GestureConfiguration
    private var down: PointerData?
    private var previous: LayoutPoint?

    /// Creates a pan recognizer.
    ///
    /// Ownership: the configuration is copied. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        self.configuration = configuration
    }

    /// Feeds one event of the session; returns the transition made.
    ///
    /// Ownership: `event` is borrowed. Isolation: MainActor. Errors: none. Cancellation: a
    /// `.pointerCancel` event yields `.cancelled` when the pan is active, `.ignored` otherwise.
    public func handle(_ event: Event) -> GestureResult {
        guard let data = event.pointer else { return .ignored }

        switch event.type {
        case .pointerDown where down == nil && state == .possible:
            down = data
            return .ignored
        case .pointerMove where down?.pointerID == data.pointerID:
            guard let down else { return .ignored }

            switch state {
            case .possible:
                guard distance(down.point, data.point) > configuration.panThreshold else {
                    return .ignored
                }

                return step(.began, to: data.point)
            case .began, .changed:
                return step(.changed, to: data.point)
            default:
                return .ignored
            }
        case .pointerUp where down?.pointerID == data.pointerID:
            defer { down = nil }
            switch state {
            case .began, .changed:
                return step(.ended, to: data.point)
            default:
                state = .failed
                return .failed
            }
        case .pointerCancel where down?.pointerID == data.pointerID:
            defer { down = nil }
            switch state {
            case .began, .changed:
                return step(.cancelled, to: data.point)
            default:
                state = .cancelled
                return .cancelled
            }
        default:
            return .ignored
        }
    }

    /// Ends the session: an active pan reports one `.cancelled` step at its last point; a
    /// waiting one goes quietly back to `.possible`. Idempotent.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: this is it.
    public func reset() {
        if state == .began || state == .changed, let last = previous {
            _ = step(.cancelled, to: last)
        }
        down = nil
        previous = nil
        state = .possible
    }

    private func step(_ next: GestureState, to point: LayoutPoint) -> GestureResult {
        guard let down else { return .ignored }

        let from = previous ?? down.point
        state = next
        previous = point
        onPan?(
            PanGesture(
                state: next,
                start: down.point,
                current: point,
                translation: LayoutPoint(x: point.x - down.point.x, y: point.y - down.point.y),
                delta: LayoutPoint(x: point.x - from.x, y: point.y - from.y)
            )
        )
        switch next {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        default: return .cancelled
        }
    }
}
