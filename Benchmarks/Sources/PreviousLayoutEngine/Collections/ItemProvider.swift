import Foundation

/// Lazily creates and updates the node shown for one item (P6.11, ADR 0030). Called only for
/// items inside the materialized window and only on the MainActor; a background worker never
/// receives a provider or its nodes. Making a node is not a load: it must not start requests.
///
/// `Content` binds the provider to one node type, so an update never casts. When a model
/// changes in a way the existing node cannot show, `canUpdate` returns `false` and the
/// container replaces the node instead of reusing it.
///
/// Ownership: the container retains its provider; a provider must not retain the container.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable — make/update are
/// synchronous.
@MainActor
public protocol ItemProvider<ItemID, Item> {
    /// Identity type of the items this provider shows.
    associatedtype ItemID: Hashable & Sendable
    /// Model type of the items this provider shows.
    associatedtype Item: Sendable & Equatable
    /// Node type created for each item.
    associatedtype Content: Node

    /// Creates the node for an item entering the window.
    ///
    /// Ownership: the container takes ownership of the returned node and disposes it when
    /// the item leaves the window. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func makeNode(for item: Item, id: ItemID) -> Content

    /// Shows a changed model on the node already created for `id`.
    ///
    /// Ownership: `node` stays container-owned. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func update(_ node: Content, with item: Item, id: ItemID)

    /// Whether `node` can show `item` through `update`; `false` replaces the node. Defaults to
    /// `true`.
    ///
    /// Ownership: `node` stays container-owned. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func canUpdate(_ node: Content, to item: Item) -> Bool
}

extension ItemProvider {
    /// Default: every node can show every model of its item.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func canUpdate(_ node: Content, to item: Item) -> Bool { true }
}

/// Closure form of `ItemProvider` — a convenience over the same materialization path, not a
/// second mechanism.
///
/// Ownership: retains both closures; they must not strongly capture the container.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public struct ClosureItemProvider<
    ItemID: Hashable & Sendable,
    Item: Sendable & Equatable,
    Content: Node
>:
    ItemProvider
{
    private let make: @MainActor (Item, ItemID) -> Content
    private let apply: @MainActor (Content, Item, ItemID) -> Void

    /// Creates a provider from make and update closures.
    ///
    /// Ownership: retains both closures. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public init(
        make: @escaping @MainActor (Item, ItemID) -> Content,
        update: @escaping @MainActor (Content, Item, ItemID) -> Void
    ) {
        self.make = make
        self.apply = update
    }

    /// Calls the make closure.
    ///
    /// Ownership: the container owns the returned node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func makeNode(for item: Item, id: ItemID) -> Content {
        make(item, id)
    }

    /// Calls the update closure.
    ///
    /// Ownership: `node` stays container-owned. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func update(_ node: Content, with item: Item, id: ItemID) {
        apply(node, item, id)
    }
}

/// Collection events for a class-bound coordinator (P6.11). Every method has an empty default;
/// a closure registered on the container for the same event takes precedence and the
/// delegate method is then not called.
///
/// Ownership: the container references its delegate weakly; the screen's owner retains it.
/// Isolation: MainActor. Errors: none. Cancellation: not applicable.
@MainActor
public protocol CollectionDelegate<ItemID>: AnyObject {
    /// Identity type of the items reported.
    associatedtype ItemID: Hashable & Sendable

    /// An item was selected.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func collectionDidSelect(_ id: ItemID)

    /// The visible items changed; coalesced to at most one call per committed window.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func collectionVisibleItemsDidChange(_ ids: [ItemID])

    /// The scroll phase changed; begin/end/cancel transitions are never coalesced away.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    func collectionScrollPhaseDidChange(_ phase: ScrollPhase)
}

extension CollectionDelegate {
    /// Default: ignores selection.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func collectionDidSelect(_ id: ItemID) {}

    /// Default: ignores visibility changes.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func collectionVisibleItemsDidChange(_ ids: [ItemID]) {}

    /// Default: ignores phase changes.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func collectionScrollPhaseDidChange(_ phase: ScrollPhase) {}
}

/// The single dispatcher behind closure and delegate APIs (P6.11): for each event a set
/// closure wins, otherwise the delegate is called; never both. Clearing the closure restores
/// the delegate fallback.
///
/// Ownership: retains closures, references the delegate weakly. Isolation: MainActor.
/// Errors: none. Cancellation: `removeAll()` drops every registration.
@MainActor
public final class CollectionEventDispatcher<ItemID: Hashable & Sendable> {
    /// The fallback receiver, held weakly.
    ///
    /// Ownership: weak. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public weak var delegate: (any CollectionDelegate<ItemID>)?

    /// Selection handler; overrides `collectionDidSelect`.
    ///
    /// Ownership: retained; must not strongly capture the container. Isolation: MainActor.
    /// Errors: none. Cancellation: assign `nil`.
    public var onSelect: (@MainActor (ItemID) -> Void)?

    /// Visible items handler; overrides `collectionVisibleItemsDidChange`.
    ///
    /// Ownership: retained; must not strongly capture the container. Isolation: MainActor.
    /// Errors: none. Cancellation: assign `nil`.
    public var onVisibleItemsChange: (@MainActor ([ItemID]) -> Void)?

    /// Scroll phase handler; overrides `collectionScrollPhaseDidChange`.
    ///
    /// Ownership: retained; must not strongly capture the container. Isolation: MainActor.
    /// Errors: none. Cancellation: assign `nil`.
    public var onScrollPhaseChange: (@MainActor (ScrollPhase) -> Void)?

    private var lastVisible: [ItemID]?
    private var lastPhase: ScrollPhase?

    /// Creates a dispatcher with no receivers.
    ///
    /// Ownership: the container owns it. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    public init() {}

    /// Delivers a selection to exactly one receiver.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func select(_ id: ItemID) {
        if let onSelect {
            onSelect(id)
        } else {
            delegate?.collectionDidSelect(id)
        }
    }

    /// Delivers visible items when they differ from the last delivered list.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func visibleItemsChanged(_ ids: [ItemID]) {
        guard ids != lastVisible else { return }

        lastVisible = ids
        if let onVisibleItemsChange {
            onVisibleItemsChange(ids)
        } else {
            delegate?.collectionVisibleItemsDidChange(ids)
        }
    }

    /// Delivers a scroll phase transition; a repeated equal phase is not re-sent.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func scrollPhaseChanged(_ phase: ScrollPhase) {
        guard phase != lastPhase else { return }

        lastPhase = phase
        if let onScrollPhaseChange {
            onScrollPhaseChange(phase)
        } else {
            delegate?.collectionScrollPhaseDidChange(phase)
        }
    }

    /// Drops all closures and the delegate reference.
    ///
    /// Ownership: releases every registration. Isolation: MainActor. Errors: none.
    /// Cancellation: this is the cancellation point.
    public func removeAll() {
        delegate = nil
        onSelect = nil
        onVisibleItemsChange = nil
        onScrollPhaseChange = nil
    }
}
