import Foundation

/// Something that can stand in a layout description: a `LayoutSpec`, or an element that
/// becomes one.
///
/// Ownership: conversion returns a value that borrows any elements. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public protocol LayoutSpecConvertible {
    /// This value as a spec.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    var asLayoutSpec: LayoutSpec { get }
}

/// A declarative description of how elements are laid out: a tree of flex containers whose
/// leaves are elements. Containers are only geometry — they create no views and no layers.
/// A spec is a value built anew for every layout pass; the elements it mentions keep their
/// identity because they are objects owned elsewhere.
///
///     FlexContainer(.row) {
///         avatar.size(48)
///         FlexContainer(.column) { title; subtitle }
///             .gap(4)
///             .flex(grow: 1)
///         follow
///     }
///     .alignItems(.center)
///     .gap(.s4)
///     .gap(.s6, from: .md)
///     .padding(16)
///
/// Every modifier is a change to the style, applied in the order written; a change with
/// `from:` applies only while the width the parent gives this item reaches that value.
///
/// Ownership: a value; it borrows the elements it mentions. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public struct LayoutSpec: LayoutSpecConvertible {
    enum Content {
        case element(any LayoutElement)
        case container([LayoutSpec])
        /// `wide` from `threshold` on, `narrow` below it — both stand in the parent's list.
        case alternatives(threshold: BreakpointWidth, wide: [LayoutSpec], narrow: [LayoutSpec])
    }

    struct StylePatch {
        let from: BreakpointWidth?
        let apply: @MainActor (inout FlexStyle, SpacingScale) -> Void
    }

    var content: Content
    var initial = FlexStyle()
    var patches: [StylePatch] = []
    /// The spec shows or hides its elements itself (`hidden`, `invisible`, `Breakpoint`), so
    /// applying it also sets their visibility. Elements of other specs keep theirs.
    var managesVisibility = false
    var isInvisible = false

    init(element: any LayoutElement) {
        content = .element(element)
    }

    /// A flex container laying out `content` along `direction`.
    ///
    /// Ownership: a value borrowing the elements in `content`. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(_ direction: FlexDirection = .row, @LayoutBuilder _ content: () -> [LayoutSpec]) {
        self.content = .container(content())
        initial.direction = direction
    }

    /// Structure that depends on width: `wide` when the width the parent gives this place
    /// reaches `threshold`, `narrow` otherwise. An element may appear in both branches: it
    /// is the same element, moved. When the width is not known yet (the parent is sizing
    /// itself to its content), `narrow` is used.
    ///
    ///     Breakpoint(from: .sm) {
    ///         FlexContainer(.row) { avatar.size(48); texts; follow }
    ///     } otherwise: {
    ///         FlexContainer(.column) { avatar.size(64); texts; follow }
    ///     }
    ///
    /// Ownership: a value borrowing the elements of both branches. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(
        from threshold: BreakpointWidth,
        @LayoutBuilder _ wide: () -> [LayoutSpec],
        @LayoutBuilder otherwise narrow: () -> [LayoutSpec]
    ) {
        content = .alternatives(threshold: threshold, wide: wide(), narrow: narrow())
        managesVisibility = true
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public var asLayoutSpec: LayoutSpec { self }

    var isElement: Bool {
        if case .element = content { return true }
        return false
    }

    /// The base style and the width variants, with spacing steps resolved by `scale`.
    func resolvedStyle(_ scale: SpacingScale) -> (base: FlexStyle, variants: [StyleVariant]) {
        var base = initial
        for patch in patches where patch.from == nil {
            patch.apply(&base, scale)
        }

        let thresholds = Set(patches.compactMap { $0.from?.points }).sorted()
        let variants = thresholds.map { threshold in
            var style = initial
            for patch in patches where (patch.from?.points ?? 0) <= threshold {
                patch.apply(&style, scale)
            }
            return StyleVariant(minWidth: threshold, style: style)
        }
        return (base, variants)
    }
}

/// The flex container of the layout description: `FlexContainer(.row) { … }` builds a
/// `LayoutSpec`.
public typealias FlexContainer = LayoutSpec

/// Structure that depends on width: `Breakpoint(from: .sm) { … } otherwise: { … }` builds a
/// `LayoutSpec`.
public typealias Breakpoint = LayoutSpec

/// Collects the items of a container: elements and specs, with `if`, `if let`, `switch`,
/// `for`, and optional elements (a `nil` element is skipped).
///
/// Ownership: returns values. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
@resultBuilder
public enum LayoutBuilder {
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildExpression(_ item: some LayoutSpecConvertible) -> [LayoutSpec] {
        [item.asLayoutSpec]
    }

    /// An optional element or spec contributes nothing when it is `nil`.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildExpression(_ item: (some LayoutSpecConvertible)?) -> [LayoutSpec] {
        item.map { [$0.asLayoutSpec] } ?? []
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildExpression(_ items: [LayoutSpec]) -> [LayoutSpec] {
        items
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildBlock(_ components: [LayoutSpec]...) -> [LayoutSpec] {
        components.flatMap { $0 }
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildOptional(_ component: [LayoutSpec]?) -> [LayoutSpec] {
        component ?? []
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildEither(first component: [LayoutSpec]) -> [LayoutSpec] {
        component
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildEither(second component: [LayoutSpec]) -> [LayoutSpec] {
        component
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public static func buildArray(_ components: [[LayoutSpec]]) -> [LayoutSpec] {
        components.flatMap { $0 }
    }
}
