import Foundation

/// Arbitration among the recognizers of one pointer session (H05, D29). Ported in spirit from
/// Weave's `GestureArena`, made per-session: the session collects the route's recognizers —
/// target's first, then each ancestor's, in registration order — and the arena feeds every
/// event to them in that order until one begins or ends. That one wins; the others are
/// `reset()` exactly once and see nothing more. Ties go to the earlier recognizer: the first
/// to answer `.began`/`.ended` is the winner, later ones never receive that event.
///
/// G06, deliberately: a recognizer that goes `.possible → .ended` in one step (Tap on up) is
/// never stored as the winner of a session that this same event closes — `winner` is set only
/// for `.began`; `.ended`, `.failed` and `.cancelled` close the session at once.
///
/// Ownership: retains the recognizers for the life of the session. Isolation: MainActor.
/// Errors: none. Cancellation: `cancel()` resets every recognizer once and closes the arena.
@MainActor
public final class GestureArena {
    /// The recognizers, in arbitration order.
    /// Ownership: retained. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public let recognizers: [any GestureRecognizer]

    /// The recognizer that has `.began` and now receives every event alone; `nil` before a
    /// winner exists and after the session closes.
    /// Ownership: borrowed from `recognizers`. Isolation: MainActor. Errors: none.
    /// Cancellation: cleared by `cancel()`.
    public private(set) var winner: (any GestureRecognizer)?

    /// Whether the session has closed: an `.ended`/`.failed`/`.cancelled` transition, a
    /// `pointerUp`/`pointerCancel`, or `cancel()`. A closed arena ignores further events.
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var isClosed = false

    /// Creates an arena over `recognizers` in arbitration order.
    ///
    /// Ownership: retains the recognizers. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public init(recognizers: [any GestureRecognizer]) {
        self.recognizers = recognizers
    }

    /// Feeds one event of the session. Returns the winner's transition, or the transition that
    /// decided the arbitration, or `.ignored`.
    ///
    /// Ownership: `event` is borrowed. Isolation: MainActor. Errors: none. Cancellation: an
    /// `.ended`/`.failed`/`.cancelled` winner result, and every `pointerUp`/`pointerCancel`,
    /// close the session and reset all recognizers for the next one.
    @discardableResult
    public func handle(_ event: Event) -> GestureResult {
        guard !isClosed else { return .ignored }

        let result: GestureResult
        if let winner {
            result = winner.handle(event)
        } else {
            result = arbitrate(event)
        }
        if result == .ended || result == .failed || result == .cancelled
            || event.type == .pointerUp || event.type == .pointerCancel
        {
            close()
        }

        return result
    }

    /// Closes the session from outside — the pointer session was cancelled (D21). Every
    /// recognizer is `reset()` once: an active one reports `.cancelled`, the rest go quiet.
    /// Idempotent.
    ///
    /// Ownership: nothing escapes. Isolation: MainActor. Errors: none. Cancellation: this is it.
    public func cancel() {
        guard !isClosed else { return }

        close()
    }

    private func arbitrate(_ event: Event) -> GestureResult {
        for (index, recognizer) in recognizers.enumerated() {
            let result = recognizer.handle(event)
            switch result {
            case .began:
                winner = recognizer
                resetOthers(than: index)
                return result
            case .ended:
                // One-step completion (Tap on up): decided, but no winner survives the event.
                resetOthers(than: index)
                return result
            case .ignored, .changed, .failed, .cancelled:
                continue
            }
        }

        return .ignored
    }

    private func resetOthers(than index: Int) {
        for (other, recognizer) in recognizers.enumerated() where other != index {
            recognizer.reset()
        }
    }

    private func close() {
        isClosed = true
        winner = nil
        for recognizer in recognizers {
            recognizer.reset()
        }
    }
}
