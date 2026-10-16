import FlexEngine

/// Text measured as if every character were 8 points wide and every line 20 points high:
/// it wraps at character boundaries into as many lines as the width needs.
public struct FixedWidthText: ContentMeasurer {
    /// The text to measure.
    public let text: String

    /// Text to measure.
    public init(_ text: String) {
        self.text = text
    }

    public func minContentWidth() -> Double { 8 }

    public func maxContentWidth() -> Double { Double(text.count) * 8 }

    public func height(forWidth width: Double) -> Double {
        let perLine = max(1, Int(width / 8))
        let lines = (text.count + perLine - 1) / perLine
        return Double(max(1, lines)) * 20
    }
}

/// The ids of the profile row's nodes, so the caller can find their frames in the result.
public enum ProfileRowID {
    /// The row itself.
    public static let row = LayoutID(0)
    /// A 48 × 48 picture on the left.
    public static let avatar = LayoutID(1)
    /// The name, which takes the width left over and wraps when it is short of room.
    public static let name = LayoutID(2)
    /// A 70 × 32 button on the right.
    public static let button = LayoutID(3)
}

/// A profile row laid out by the engine alone — no views, no main actor: an avatar, a name
/// that takes the rest of the width and a button, centered across the row, 12 points apart,
/// inside 16 points of padding.
///
/// - Parameters:
///   - name: The name the middle item shows.
///   - width: The width of the row; the height is 80 points.
/// - Returns: Every node's frame, in the row's coordinates.
/// - Throws: `LayoutCancelled` when `context` reports cancellation.
public func layoutProfileRow(
    name: String,
    width: Double,
    context: LayoutContext = LayoutContext()
) throws -> LayoutResult {
    var row = FlexStyle()
    row.direction = .row
    row.alignItems = .center
    row.columnGap = 12
    row.padding = Edges(all: 16)

    var flexible = FlexStyle()
    flexible.grow = 1
    flexible.shrink = 1

    let tree = LayoutNode(
        id: ProfileRowID.row,
        style: row,
        children: [
            LayoutNode(id: ProfileRowID.avatar, content: .size(width: 48, height: 48)),
            LayoutNode(
                id: ProfileRowID.name,
                style: flexible,
                content: .measured(FixedWidthText(name))
            ),
            LayoutNode(id: ProfileRowID.button, content: .size(width: 70, height: 32)),
        ]
    )
    return try FlexboxEngine.layout(
        tree,
        size: LayoutSize(width: width, height: 80),
        context: context
    )
}

/// The same row solved off the main actor: a nonisolated async function runs on the
/// concurrent executor even when the main actor calls it. Cancelling the calling task
/// cancels the pass, which then throws `LayoutCancelled` and returns nothing.
public func layoutProfileRowInBackground(name: String, width: Double) async throws -> LayoutResult {
    try layoutProfileRow(name: name, width: width, context: .currentTask)
}
