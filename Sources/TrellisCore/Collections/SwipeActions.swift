import Foundation

/// Visual weight of a row action.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RowActionStyle: Sendable, Hashable {
    /// A neutral action.
    case normal
    /// An action that removes or destroys data.
    case destructive
}

/// Outcome of a row action.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RowActionResult: Sendable, Hashable {
    /// The action finished; the row closes.
    case completed
    /// The action failed; the row stays open showing the error and the action can be retried.
    case failed(String)
}

/// One action revealed by swiping a table row, also offered to accessibility and other input
/// (P6.6). It receives the row's stable item ID, never an index.
///
/// Ownership: a value; retains `perform`. Isolation: `perform` runs on the MainActor. Errors:
/// reported through `RowActionResult`. Cancellation: the table owns the task; a row removed
/// while its action runs does not repeat the action.
public struct RowAction<ItemID: Hashable & Sendable>: Sendable {
    /// Stable identity inside the row's actions.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let id: String

    /// Label shown on the button and read by accessibility.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let title: String

    /// Visual weight.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let style: RowActionStyle

    /// The work, for the row's item ID.
    ///
    /// Ownership: retained. Isolation: MainActor. Errors: via the result. Cancellation: not
    /// applicable.
    public let perform: @MainActor @Sendable (ItemID) async -> RowActionResult

    /// Creates an action.
    ///
    /// Ownership: retains `perform`. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        id: String,
        title: String,
        style: RowActionStyle = .normal,
        perform: @escaping @MainActor @Sendable (ItemID) async -> RowActionResult
    ) {
        self.id = id
        self.title = title
        self.style = style
        self.perform = perform
    }
}

/// Side of a row whose actions a swipe reveals, in reading direction: in right-to-left layout
/// `.leading` is on the right.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RowSwipeEdge: Sendable, Hashable {
    /// Actions on the leading side, revealed by dragging toward the trailing side.
    case leading
    /// Actions on the trailing side, revealed by dragging toward the leading side.
    case trailing
}

/// Whether a table accepts the row swipe gesture (P6.6). Disabling it disables only the
/// gesture: the actions stay available to accessibility.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SwipeActionsPolicy: Sendable, Hashable {
    /// Enabled when actions are configured and no enclosing container disables row swipes
    /// (`RowSwipeContextKey`).
    case automatic
    /// Never.
    case disabled
    /// Always when actions are configured, even inside a container that disables them.
    case enabled

    /// Resolves the policy for a table.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func allowsSwipe(hasActions: Bool, contextAllows: Bool) -> Bool {
        guard hasActions else { return false }

        switch self {
        case .automatic: return contextAllows
        case .disabled: return false
        case .enabled: return true
        }
    }
}

/// Environment key a composite container (a pager) sets to `false` so tables inside it leave
/// the horizontal gesture to the container (P6.6). Paint- and geometry-neutral.
///
/// Ownership: the key supplies an immutable default. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum RowSwipeContextKey: EnvironmentKey {
    /// Row swipes are allowed unless a container says otherwise.
    ///
    /// Ownership: immutable. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue = true

    /// Does not affect geometry.
    ///
    /// Ownership: immutable. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let affectsLayout = false
}

/// Phase of the open row.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum RowSwipePhase: Sendable, Hashable {
    /// The finger drives the row.
    case tracking
    /// Actions are revealed and wait for a tap.
    case open
    /// An action runs; further taps are blocked.
    case performing(actionID: String)
    /// The action failed; the row stays open and the action can be retried.
    case failed(actionID: String, message: String)
}

/// Swipe state of one table (P6.6, ADR 0034): at most one open row, identified by item ID. Pure
/// logic — the cell nodes render `offset(for:)` and forward gestures and taps.
///
/// Ownership: owned by the table; retains running action tasks. Isolation: MainActor.
/// Errors: none — action failures become `.failed`. Cancellation: `close()`, `itemsRemoved`
/// and `cancelAll()` end interactions; a running action is not repeated or cancelled by a close.
@MainActor
public final class RowSwipeController<ItemID: Hashable & Sendable> {
    /// The open row, or `nil`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var openRow: ItemID?

    /// Revealed side of the open row.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var edge: RowSwipeEdge = .trailing

    /// Revealed width of the open row, in points (always ≥ 0).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var revealed = 0.0

    /// Phase of the open row.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var phase: RowSwipePhase = .open

    /// Width of one action button.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var buttonWidth = 80.0

    /// Fraction of the row width past which releasing performs the first action (full swipe).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var fullSwipeFraction = 0.6

    /// Called whenever the open row, its offset or its phase changes.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var onChange: (@MainActor (ItemID?) -> Void)?

    private var running: [ItemID: Task<Void, Never>] = [:]

    /// Creates an idle controller.
    ///
    /// Ownership: the table owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public init() {}

    /// Signed offset of `id`'s content along reading direction: positive moves it toward the
    /// trailing side (leading actions revealed), negative toward the leading side.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func offset(for id: ItemID) -> Double {
        guard openRow == id else { return 0 }

        return edge == .leading ? revealed : -revealed
    }

    /// Starts or continues tracking `id` with a reading-direction translation (positive toward
    /// trailing). Another open row closes. Returns `false` when `id` has no actions on the side
    /// the translation reveals or an action of `id` is running.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    @discardableResult
    public func track(
        _ id: ItemID,
        translation: Double,
        leadingCount: Int,
        trailingCount: Int,
        rowWidth: Double
    ) -> Bool {
        if case .performing = phase, openRow == id { return false }

        let start = openRow == id ? offset(for: id) : 0
        let total = start + translation
        let side: RowSwipeEdge = total >= 0 ? .leading : .trailing
        let count = side == .leading ? leadingCount : trailingCount
        guard count > 0 else {
            if openRow == id { close() }
            return false
        }

        if openRow != id {
            close()
            openRow = id
        }
        edge = side
        revealed = min(abs(total), max(rowWidth, Double(count) * buttonWidth))
        phase = .tracking
        onChange?(id)
        return true
    }

    /// Ends tracking of `id`: past `fullSwipeFraction` of the row width with a full-swipe action
    /// performs it; past half the buttons' width stays open; otherwise closes. Returns the
    /// action to perform for a full swipe, if any.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func release(
        _ id: ItemID,
        actionCount: Int,
        rowWidth: Double,
        allowsFullSwipe: Bool
    ) -> Bool {
        guard openRow == id, phase == .tracking else { return false }

        let buttons = Double(actionCount) * buttonWidth
        if allowsFullSwipe, revealed >= rowWidth * fullSwipeFraction {
            revealed = max(buttons, revealed)
            phase = .open
            onChange?(id)
            return true
        }

        if revealed >= buttons / 2 {
            revealed = buttons
            phase = .open
            onChange?(id)
        } else {
            close()
        }
        return false
    }

    /// Runs `action` for `id`. Blocked while another action of `id` runs; completion closes the
    /// row, failure keeps it open in `.failed` so a tap retries.
    ///
    /// Ownership: owns the task. Isolation: MainActor. Errors: via `.failed`. Cancellation:
    /// the task is not cancelled by closing; it is dropped on `cancelAll()`.
    @discardableResult
    public func perform(_ action: RowAction<ItemID>, for id: ItemID) -> Bool {
        guard running[id] == nil else { return false }

        if openRow == id {
            phase = .performing(actionID: action.id)
            onChange?(id)
        }
        running[id] = Task { @MainActor [weak self] in
            let result = await action.perform(id)
            self?.finish(id, action: action.id, result: result)
        }
        return true
    }

    /// Whether an action of `id` is running.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public func isPerforming(_ id: ItemID) -> Bool {
        running[id] != nil
    }

    /// Closes the open row without running anything.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: ends tracking.
    public func close() {
        guard let id = openRow else { return }

        openRow = nil
        revealed = 0
        phase = .open
        onChange?(id)
    }

    /// Cancels the interaction of a row that left the data set: the open row closes and its
    /// actions never move to a neighbour; an action already sent is not repeated.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: ends tracking.
    public func itemsRemoved(_ isPresent: (ItemID) -> Bool) {
        if let id = openRow, !isPresent(id) {
            close()
        }
    }

    /// Closes the open row and drops every running task (the table is being disposed).
    ///
    /// Ownership: releases tasks. Isolation: MainActor. Errors: none. Cancellation: this is the
    /// cancellation point.
    public func cancelAll() {
        for task in running.values {
            task.cancel()
        }
        running.removeAll()
        close()
    }

    private func finish(_ id: ItemID, action: String, result: RowActionResult) {
        running[id] = nil
        guard openRow == id else { return }

        switch result {
        case .completed:
            close()
        case .failed(let message):
            phase = .failed(actionID: action, message: message)
            onChange?(id)
        }
    }
}
