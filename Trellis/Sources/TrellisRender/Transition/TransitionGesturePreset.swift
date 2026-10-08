import Foundation

/// D72's finish/cancel thresholds — "Решение finish/cancel учитывает progress и скорость в
/// согласованных единицах; пороги — часть preset и проверяются граничными тестами." Both units
/// are the same `progress` scale `NodeHostBridge.updateTransitionGesture(deltaProgress:)` and
/// `endTransitionGesture(velocity:)` already use — a plain `0...1` fraction and its rate of
/// change per second — not points, not seconds-remaining, so a caller never has to convert.
///
/// **Note on the decision's outcome names.** The settled state table
/// (`docs/validation/m10-transition-contract.md` §1.3) labels the two outcomes of this decision
/// "finish" (→ `settling(.presented)`) and "cancel" (→ `settling(.closed)`) — and explicitly
/// warns the labels are "по итогу жеста закрытия, не по слову в отрыве от контекста" (named by
/// the outcome of the *closing* gesture, not by the bare word). Read plainly, "cancel" here means
/// the dismissal actually completes (the presented page is cancelled, ending at the closed
/// card) and "finish" means the dismissal attempt itself concludes without completing (the
/// gesture finishes, the presented page stays). This type and
/// `NodeHostBridge.endTransitionGesture(velocity:)` avoid repeating those two words as API
/// vocabulary for exactly that reason — `TransitionSettleTarget.presented`/`.closed` says what
/// actually happens without relying on which of "finish"/"cancel" a reader expects it to mean.
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TransitionGesturePreset: Sendable, Hashable {
    /// The closing-direction progress fraction at or above which the gesture is decided as a
    /// completed dismissal (settles to `.closed`) even at zero velocity.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let progressThreshold: Double

    /// The closing-direction velocity (progress fraction per second) at or above which the
    /// gesture is decided as a completed dismissal (settles to `.closed`) regardless of where
    /// `progressThreshold` sits — a fast flick completes the dismissal even started from well
    /// under half.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let velocityThreshold: Double

    /// Creates a preset. Both thresholds are compared with `>=` — a value exactly at the
    /// threshold decides toward `.closed`, matching the boundary tests this card requires (D72:
    /// "пороги... проверяются граничными тестами").
    ///
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(progressThreshold: Double, velocityThreshold: Double) {
        self.progressThreshold = progressThreshold
        self.velocityThreshold = velocityThreshold
    }

    /// `.expand`'s default preset: past the halfway point, or a flick at 1.2 progress-fractions
    /// per second or faster in the closing direction, completes the dismissal.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let `default` = TransitionGesturePreset(
        progressThreshold: 0.5,
        velocityThreshold: 1.2
    )
}
