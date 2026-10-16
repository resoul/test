import Foundation

/// The interpolation curve used by an ``Animation`` timing value.
///
/// Ownership: immutable copied value. Isolation: none. Errors: none. Cancellation: not
/// applicable.
public enum AnimationCurve: Sendable, Hashable {
    /// Constant-rate interpolation.
    case linear
    /// Slow start followed by acceleration.
    case easeIn
    /// Deceleration toward the target.
    case easeOut
    /// Acceleration followed by deceleration.
    case easeInOut
    /// A physically driven spring (M09) — real `CASpringAnimation` physics in
    /// `TrellisRender`, never a pre-baked easing curve standing in for one (defect #41).
    /// `response` is the perceived duration in seconds (an undamped spring's period to first
    /// reach the target); `dampingFraction` is `0` (exclusive) `...1` — `1` is critically
    /// damped (reaches the target with no overshoot), less is bouncier. Same two-parameter
    /// shape as SwiftUI's `.spring(response:dampingFraction:)`; `LayerAnimator` converts these
    /// to `CASpringAnimation`'s `mass`/`stiffness`/`damping` at commit time and reads the
    /// SDK's own `settlingDuration` back rather than guessing one.
    case spring(response: Double, dampingFraction: Double)
}

/// Immutable timing for the next visual change in a node subtree.
///
/// A non-positive duration is normalized to ``none``. The first animation slice deliberately
/// has no delay, completion, keyframes, or spring parameters; those are independent contracts.
///
/// Ownership: immutable copied value. Isolation: none. Errors: non-positive durations become
/// ``none``. Cancellation: not applicable.
public struct Animation: Sendable, Hashable {
    /// Normalized transition duration.
    ///
    /// Ownership: returns a copied value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public let duration: Duration

    /// The interpolation curve. A zero-duration value always stores ``AnimationCurve/linear``.
    ///
    /// Ownership: returns a copied value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public let curve: AnimationCurve

    /// An explicit immediate transition.
    ///
    /// Ownership: returns an immutable value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static let none = Animation(duration: .zero, curve: .linear)

    /// The default 250 ms ease-in-out transition.
    ///
    /// Ownership: returns an immutable value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static let smooth = Animation(duration: .milliseconds(250), curve: .easeInOut)

    /// Creates normalized timing with the requested curve.
    ///
    /// Ownership: the caller owns the returned value. Isolation: none. Errors: a non-positive
    /// duration is represented as ``none``. Cancellation: not applicable.
    public init(duration: Duration, curve: AnimationCurve = .easeInOut) {
        if duration <= .zero {
            self.duration = .zero
            self.curve = .linear
        } else {
            self.duration = duration
            self.curve = curve
        }
    }

    /// Creates a linear transition.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: as ``init(duration:curve:)``.
    /// Cancellation: not applicable.
    public static func linear(duration: Duration) -> Animation {
        Animation(duration: duration, curve: .linear)
    }

    /// Creates an ease-in transition.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: as ``init(duration:curve:)``.
    /// Cancellation: not applicable.
    public static func easeIn(duration: Duration) -> Animation {
        Animation(duration: duration, curve: .easeIn)
    }

    /// Creates an ease-out transition.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: as ``init(duration:curve:)``.
    /// Cancellation: not applicable.
    public static func easeOut(duration: Duration) -> Animation {
        Animation(duration: duration, curve: .easeOut)
    }

    /// Creates an ease-in-out transition.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: as ``init(duration:curve:)``.
    /// Cancellation: not applicable.
    public static func easeInOut(duration: Duration) -> Animation {
        Animation(duration: duration, curve: .easeInOut)
    }

    /// Creates a physically driven spring (M09) — see ``AnimationCurve/spring(response:dampingFraction:)``.
    /// `duration` here is only the value this model reports before a real `CASpringAnimation`
    /// exists (the `> .zero` check every reconciliation path uses to tell "animate" from
    /// "snap") — `response` itself, converted to seconds, is an honest stand-in: the renderer
    /// always overrides it with the SDK's own computed `settlingDuration` once the spring is
    /// actually built, never this estimate.
    ///
    /// Ownership: returns a new value. Isolation: none. Errors: `response` is clamped to a
    /// small positive minimum (a non-positive response has no physical meaning and would divide
    /// by zero converting to stiffness/damping); `dampingFraction` is clamped to `0.05...1` —
    /// `0` never settles (undamped oscillation forever) and is rejected the same way a
    /// non-positive duration normalizes elsewhere in this type. Cancellation: not applicable.
    public static func spring(response: Double = 0.35, dampingFraction: Double = 0.86) -> Animation
    {
        let safeResponse = response.isFinite ? Swift.max(0.05, response) : 0.35
        let safeDamping =
            dampingFraction.isFinite ? Swift.min(1, Swift.max(0.05, dampingFraction)) : 0.86
        return Animation(
            duration: .seconds(safeResponse),
            curve: .spring(response: safeResponse, dampingFraction: safeDamping)
        )
    }

    /// The one ready-made spring preset D74/M09 asks for — tuned against the S27 disclosure
    /// scene's press/expand interaction: a light, controlled bounce (`dampingFraction` close to
    /// but under `1`) that reads as responsive without visibly overshooting on the properties a
    /// press/disclosure typically animates (bounds/position for the card, opacity for a fade).
    ///
    /// Ownership: returns an immutable value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.86)
}

/// One subtree policy captured with a pending visual change.
///
/// The record contains identities and values only: pending animation metadata must not retain a
/// live `Node`, enter a solver snapshot, or participate in layout work identity (D62/D64).
package struct AnimationIntent: Sendable, Hashable {
    package let scopeNodeID: NodeID
    package let sequence: UInt64
    package let epoch: UInt64
    package let animation: Animation
}
