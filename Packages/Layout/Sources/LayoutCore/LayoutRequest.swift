import FlexEngine
import Foundation

/// A layout snapshot and fixed constraints that can be handed to a solver task.
///
/// The request keeps the input values and their content measurers, without the prepared
/// layout's mapping to live elements. It does not schedule work or observe later changes
/// to those elements. Prepare a new layout when the content or its environment changes.
public struct LayoutRequest: Sendable {
    /// The size the solver must use for this request.
    public let size: LayoutSize

    /// Whether the snapshot contains a measurer that must run on the main actor.
    public let requiresMainThread: Bool

    private let input: LayoutNode
    private let preparationID: UUID

    init(input: LayoutNode, size: LayoutSize, requiresMainThread: Bool, preparationID: UUID) {
        self.input = input
        self.size = size
        self.requiresMainThread = requiresMainThread
        self.preparationID = preparationID
    }

    /// Solves the snapshot on the calling task without touching live layout elements.
    ///
    /// This method never schedules another task. Use it from the caller's bounded executor.
    /// A request requiring the main actor is rejected before any content is measured;
    /// use ``solveOnMainActor(context:)`` for that request, even when already on main.
    ///
    /// - Parameter context: Cancellation, tracing, and the stack budget for this execution.
    ///   Task cancellation is observed by default; a supplied context controls cancellation
    ///   instead. Set its stack budget to suit the executor's thread when needed.
    /// - Returns: A result bound to this preparation and size, without applying any frames.
    /// - Throws: ``LayoutRequestError/requiresMainThread`` for main-only content,
    ///   or the solver's cancellation and stack-budget errors. A cancelled pass returns
    ///   no computation. Cancellation does not interrupt an already running measurer.
    public func solve(context: LayoutContext = .currentTask) throws -> ComputedLayout {
        guard !requiresMainThread else { throw LayoutRequestError.requiresMainThread }
        return try compute(context: context)
    }

    /// Solves the snapshot synchronously on the main actor, including main-only content.
    ///
    /// Nothing is applied to live elements. The context controls cancellation and tracing;
    /// by default cancellation follows the current task. A cancelled or stack-limited pass
    /// throws without returning a computation.
    @MainActor
    public func solveOnMainActor(context: LayoutContext = .currentTask) throws -> ComputedLayout {
        try compute(context: context)
    }

    private func compute(context: LayoutContext) throws -> ComputedLayout {
        ComputedLayout(
            result: try FlexboxEngine.layout(input, size: size, context: context),
            size: size,
            preparationID: preparationID
        )
    }
}

/// The complete result of one request, bound to its prepared snapshot and constraints.
///
/// Send this value back to the main actor and apply it through the current
/// ``PreparedLayout``. It keeps frame values and diagnostics, not live elements.
public struct ComputedLayout: Sendable {
    /// The solver's frames and diagnostics for this computation.
    public let result: LayoutResult

    /// The constraints used to calculate the frames.
    public let size: LayoutSize

    let preparationID: UUID
}

/// A request cannot be solved by the chosen execution path.
public enum LayoutRequestError: Error, Sendable {
    /// The snapshot requires ``LayoutRequest/solveOnMainActor(context:)``.
    case requiresMainThread
}
