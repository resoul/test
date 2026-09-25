/// Measures content whose height depends on the width it gets — text above all: it wraps
/// into more lines when narrower. Width is the only input; the content decides its height.
///
/// Ownership: implementations are values or immutable objects owned by the tree that holds
/// them. Isolation: called from the solving task, possibly off the main thread, so an
/// implementation must not touch UI objects — it measures from immutable data (for text: an
/// immutable attributed string and a thread-safe typesetter). Errors: none. Cancellation:
/// calls are short; the solver checks cancellation between them.
public protocol ContentMeasurer: Sendable {
    /// The narrowest width the content can take without overflowing (for text: its longest
    /// unbreakable word).
    ///
    /// Ownership: returns a value. Isolation: solving task. Errors: none. Cancellation: none.
    func minContentWidth() -> Double

    /// The width the content takes when nothing limits it (for text: without wrapping).
    ///
    /// Ownership: returns a value. Isolation: solving task. Errors: none. Cancellation: none.
    func maxContentWidth() -> Double

    /// The height of the content laid out in `width`.
    ///
    /// Ownership: returns a value. Isolation: solving task. Errors: none. Cancellation: none.
    func height(forWidth width: Double) -> Double

    /// The distance from the top of the content to the baseline of its first line, laid out
    /// in `width`, or `nil` when the content has no baseline — the bottom of the content is
    /// used then. The default is `nil`.
    ///
    /// Ownership: returns a value. Isolation: solving task. Errors: none. Cancellation: none.
    func firstBaseline(forWidth width: Double) -> Double?

    /// Whether the measurer only works on the main thread (it asks a view for its size).
    /// A layout with such content is solved on the main thread. The default is `false`.
    ///
    /// Ownership: returns a value. Isolation: any. Errors: none. Cancellation: none.
    var requiresMainThread: Bool { get }
}

extension ContentMeasurer {
    /// Ownership: returns a value. Isolation: solving task. Errors: none. Cancellation: none.
    public func firstBaseline(forWidth width: Double) -> Double? { nil }

    /// Ownership: returns a value. Isolation: any. Errors: none. Cancellation: none.
    public var requiresMainThread: Bool { false }
}

/// What a leaf shows, excluding its padding.
///
/// Ownership: value type; a measurer is shared, never mutated. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum LeafContent: Sendable {
    /// A fixed size, like an image.
    case size(LayoutSize)
    /// Content sized by a measurer, like text.
    case measured(any ContentMeasurer)

    /// A fixed size.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func size(width: Double, height: Double) -> LeafContent {
        .size(LayoutSize(width: width, height: height))
    }

    /// The first baseline of the content laid out in `width`: the measurer's, or the bottom
    /// of the content when it has none.
    func baseline(width: Double) -> Double {
        switch self {
        case let .size(size):
            return size.height
        case let .measured(measurer):
            return measurer.firstBaseline(forWidth: width) ?? measurer.height(forWidth: width)
        }
    }

    /// The narrowest width the content takes without overflowing.
    var minContentWidth: Double {
        switch self {
        case let .size(size): size.width
        case let .measured(measurer): measurer.minContentWidth()
        }
    }

    /// The content size under `width`: a known content width, or a constraint — min-content,
    /// max-content, or fit-content for a definite amount of space.
    func size(knownWidth: Double?, available: AvailableSpace) -> LayoutSize {
        switch self {
        case let .size(size):
            return size
        case let .measured(measurer):
            let width: Double
            if let knownWidth {
                width = knownWidth
            } else {
                switch available {
                case .minContent:
                    width = measurer.minContentWidth()
                case .maxContent:
                    width = measurer.maxContentWidth()
                case let .definite(space):
                    width = min(measurer.maxContentWidth(), max(measurer.minContentWidth(), space))
                }
            }

            return LayoutSize(width: width, height: measurer.height(forWidth: width))
        }
    }
}
