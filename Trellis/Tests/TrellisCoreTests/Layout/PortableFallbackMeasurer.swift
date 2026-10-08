import os

@testable import TrellisCore

/// Deterministic, explicitly non-typographic `ContentMeasurer` for T03's own tests (D51,
/// defect #40) — a stand-in for exercising the solver's measurement plumbing, not a
/// substitute for real geometry. Real wrapping and baseline metrics are CoreText's job (T05);
/// comparing this model's numbers against CoreText's is not a meaningful test.
///
/// `callCount` is the only mutable state, behind `OSAllocatedUnfairLock` — a real
/// synchronization primitive, not `@unchecked Sendable`/`nonisolated(unsafe)` (AGENTS ban) —
/// so this type can genuinely conform to `Sendable` the way a solver-callable measurer must.
final class PortableFallbackMeasurer: ContentMeasurer, Sendable {
    private struct Counters {
        var callCount = 0
    }

    /// Fixed content this measurer reports on — a real `TextNode` (T04) would let this vary
    /// per instance while keeping `identity` stable; this fallback has no mutation story of
    /// its own, so a content change is modeled as a new instance instead.
    let text: String
    let pointSize: Double
    let revision: UInt64
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    /// Arbitrary, fixed ratios — not measured typography. Chosen only so the same text at the
    /// same `pointSize` always reports the same geometry, which is all these tests need.
    private static let charWidthRatio = 0.6
    private static let lineHeightRatio = 1.2

    var identity: ObjectIdentifier { ObjectIdentifier(self) }

    /// Number of completed `measure(_:context:)` calls — cancelled calls (thrown before
    /// completing) do not count. Used to prove the solver's cache calls a measurer at most
    /// once per unique constraint (T03 acceptance), not to drive any product behavior.
    var callCount: Int { counters.withLock { $0.callCount } }

    init(text: String, pointSize: Double = 17, revision: UInt64 = 0) {
        self.text = text
        self.pointSize = pointSize
        self.revision = revision
    }

    func measure(_ constraint: SizeConstraint, context: LayoutContext) throws
        -> LayoutContentMetrics
    {
        try context.checkCancellation()

        let charWidth = pointSize * Self.charWidthRatio
        let lineHeight = pointSize * Self.lineHeightRatio
        let baseline = lineHeight * 0.8

        guard !text.isEmpty else {
            counters.withLock { $0.callCount += 1 }
            return LayoutContentMetrics(
                intrinsic: MeasuredSize(width: 0, height: lineHeight),
                firstBaseline: baseline
            )
        }

        let naturalWidth = Double(text.count) * charWidth
        let (lineCount, reportedWidth): (Int, Double)
        switch constraint.width {
        case .unspecified:
            (lineCount, reportedWidth) = (1, naturalWidth)
        case let .atMost(bound):
            (lineCount, reportedWidth) = (
                wrappedLineCount(naturalWidth: naturalWidth, bound: bound, charWidth: charWidth),
                min(naturalWidth, bound)
            )
        case let .exact(bound):
            (lineCount, reportedWidth) = (
                wrappedLineCount(naturalWidth: naturalWidth, bound: bound, charWidth: charWidth),
                bound
            )
        }

        // Cooperative cancellation at least once per line (D58) — this loop is the whole
        // point of the checkpoint existing at all when `lineCount` is large.
        for line in 1..<lineCount { _ = line; try context.checkCancellation() }

        counters.withLock { $0.callCount += 1 }
        return LayoutContentMetrics(
            intrinsic: MeasuredSize(width: reportedWidth, height: Double(lineCount) * lineHeight),
            firstBaseline: baseline
        )
    }

    private func wrappedLineCount(naturalWidth: Double, bound: Double, charWidth: Double) -> Int {
        guard naturalWidth > bound else { return 1 }
        let charsPerLine = max(1, Int(bound / charWidth))
        return Int((Double(text.count) / Double(charsPerLine)).rounded(.up))
    }
}
