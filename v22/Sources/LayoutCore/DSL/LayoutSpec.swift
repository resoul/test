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
///     .gap(12)
///     .padding(16)
///
/// Ownership: a value; it borrows the elements it mentions. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public struct LayoutSpec: LayoutSpecConvertible {
    enum Content {
        case element(any LayoutElement)
        case container([LayoutSpec])
    }

    var content: Content
    var style: FlexStyle

    init(element: any LayoutElement) {
        content = .element(element)
        style = FlexStyle()
    }

    /// A flex container laying out `content` along `direction`.
    ///
    /// Ownership: a value borrowing the elements in `content`. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(_ direction: FlexDirection = .row, @LayoutBuilder _ content: () -> [LayoutSpec]) {
        self.content = .container(content())
        style = FlexStyle()
        style.direction = direction
    }

    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
    public var asLayoutSpec: LayoutSpec { self }

    var isElement: Bool {
        if case .element = content { return true }
        return false
    }
}

/// The flex container of the layout description: `FlexContainer(.row) { … }` builds a
/// `LayoutSpec`.
public typealias FlexContainer = LayoutSpec

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
