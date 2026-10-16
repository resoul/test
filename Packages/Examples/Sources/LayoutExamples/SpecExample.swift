import FlexEngine
import LayoutCore

/// Anything with a frame that a spec can place: here a plain object that remembers its frame.
/// Views take part the same way — the platform adapters make `UIView` and `NSView` elements.
@MainActor
public final class Box: LayoutElement {
    /// The size the box's content asks for.
    public let layoutContent: LeafContent?
    /// The frame from the last layout, or `nil` before one.
    public private(set) var frame: LayoutRect?
    /// Whether the last layout showed the box; `nil` until a spec that shows or hides
    /// elements placed it.
    public private(set) var isVisible: Bool?

    /// A box whose content is `width` × `height` points.
    public init(width: Double, height: Double) {
        layoutContent = .size(width: width, height: height)
    }

    public func applyLayoutFrame(_ frame: LayoutRect) {
        self.frame = frame
    }

    public func applyLayoutVisibility(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
}

/// The boxes of a card.
@MainActor
public struct Card {
    /// The picture.
    public let avatar = Box(width: 0, height: 0)
    /// The title.
    public let title = Box(width: 120, height: 20)
    /// The line under the title.
    public let subtitle = Box(width: 90, height: 16)
    /// The button.
    public let follow = Box(width: 70, height: 32)

    /// A card of fresh boxes.
    public init() {}

    /// A row on a wide screen; on a narrow one, the picture over the texts and the button.
    /// Spacing steps (`.s3`, `.s4`) and the breakpoint name (`.sm`) become points from the
    /// scales the layout is applied with.
    public func spec() -> LayoutSpec {
        Breakpoint(from: .sm) {
            FlexContainer(.row) {
                avatar.size(48)
                FlexContainer(.column) {
                    title
                    subtitle
                }
                .gap(.s2)
                .flex(grow: 1, shrink: 1)
                follow
            }
            .alignItems(.center)
            .gap(.s4)
            .padding(.s5)
        } otherwise: {
            FlexContainer(.column) {
                avatar.size(64)
                title
                subtitle
                follow
            }
            .alignItems(.start)
            .gap(.s3)
            .padding(.s5)
        }
    }
}

/// Lays the card out in `rect` in one call, on the main actor.
@MainActor
public func layoutCard(_ card: Card, in rect: LayoutRect) {
    card.spec().apply(in: rect)
}

/// Lays the card out with the engine's pass off the main actor: the spec is read on the main
/// actor (it asks the elements for their content), solved elsewhere, and its frames are
/// handed to the elements back on the main actor.
@MainActor
public func layoutCardInBackground(_ card: Card, in rect: LayoutRect) async throws {
    let prepared = card.spec().prepare()
    let input = prepared.input
    let size = rect.size
    let result = try await Task.detached {
        try FlexboxEngine.layout(input, size: size)
    }.value
    prepared.apply(result, in: rect)
}
