import Foundation
import FlexEngine
import LayoutCore
import ThemeCore

/// Constraints and environment captured on the main actor for one list item's preparation.
/// The snapshot contains no live nodes, views, or localizer callbacks.
public struct ItemPreparationContext: Sendable, Hashable {
    /// The axis along which the list places items.
    public let axis: ScrollAxis
    /// Space across the axis for one item, after lane spacing.
    public let crossAxisLength: Double
    /// The host size; resizing invalidates plans before new item frames are applied.
    public let viewportSize: LayoutSize
    /// Pixels per point used by the host.
    public let scale: Double
    /// The host's inline layout direction.
    public let direction: LayoutDirection
    /// The stack's resolved theme, including enclosing overrides.
    public let theme: ResolvedTheme
    /// The host's locale, without access to its live localizer.
    public let locale: Locale

    /// Returns the same environment with the space available to the item's inner content.
    /// Containers use this after reserving space for their own controls or decorations.
    /// Negative or non-finite space becomes zero.
    public func replacingCrossAxisLength(_ length: Double) -> ItemPreparationContext {
        ItemPreparationContext(
            axis: axis,
            crossAxisLength: length.isFinite ? max(0, length) : 0,
            viewportSize: viewportSize,
            scale: scale,
            direction: direction,
            theme: theme,
            locale: locale
        )
    }
}

/// A value prepared without live nodes, optionally carrying a measured item length.
public struct PreparedItem<Value: Sendable>: Sendable {
    /// Content or a layout plan that the main-actor node factory can use.
    public let value: Value
    /// Length along the list axis, used to refine offscreen estimates before creating nodes.
    /// `nil` leaves estimation to the list; actual mounted geometry remains authoritative.
    public let length: Double?

    /// Creates a prepared value; negative or non-finite lengths are treated as unknown.
    public init(_ value: Value, length: Double? = nil) {
        self.value = value
        self.length = length.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// What a list's main-actor factory can show for an item's current preparation key.
public enum PreparedItemState<Value: Sendable>: Sendable {
    /// Preparation is queued, running, or not yet admitted; show a lightweight placeholder.
    case pending
    /// A plan for the current revision, constraints, and environment is ready.
    case ready(PreparedItem<Value>)
    /// Preparation failed; show an error or placeholder and retry explicitly.
    case failed(any Error)
}

/// Per-list limits for model-driven preparation and retained plans.
/// Counts limit jobs and plans, not their byte size or resources retained by node factories.
public struct ItemPreparationPolicy: Sendable, Hashable {
    /// Maximum workers, including cancelled workers that have not returned yet.
    public let maximumConcurrentTasks: Int
    /// Maximum queued jobs in addition to running workers.
    public let maximumQueuedItems: Int
    /// Maximum tracked entries and retained plans. Excess demand stays pending until
    /// viewport admission changes; size this to cover the simultaneously visible items.
    public let maximumRetainedItems: Int
    /// Entry and retention distances used to prepare model items before nodes exist.
    public let range: ContentRangePolicy

    /// Creates a bounded policy. Worker and retention limits are at least one; queue size
    /// is at least zero. Visible items precede nearby and distant items in the queue.
    public init(
        maximumConcurrentTasks: Int = 2,
        maximumQueuedItems: Int = 16,
        maximumRetainedItems: Int = 64,
        range: ContentRangePolicy = ContentRangePolicy()
    ) {
        self.maximumConcurrentTasks = max(1, maximumConcurrentTasks)
        self.maximumQueuedItems = max(0, maximumQueuedItems)
        self.maximumRetainedItems = max(1, maximumRetainedItems)
        self.range = range
    }
}

/// Current counts in a list's preparation budget, for diagnostics.
public struct ItemPreparationProgress: Sendable, Equatable {
    /// Workers that have not returned, including cancelled workers.
    public let running: Int
    /// Admitted jobs waiting for a worker slot.
    public let queued: Int
    /// Model entries retained by the list, including pending and failed entries.
    public let retained: Int
}

struct ItemPreparationCandidate<Item: Identifiable> {
    let item: Item
    let demand: ContentDemand
}

@MainActor
protocol ItemPreparing<Item>: AnyObject {
    associatedtype Item: Identifiable
    var policy: ItemPreparationPolicy { get }
    var onChange: (@MainActor () -> Void)? { get set }
    var contextIsCurrent: (@MainActor (ItemPreparationContext) -> Bool)? { get set }
    var progress: ItemPreparationProgress { get }
    func node(for item: Item, context: ItemPreparationContext?) -> Node
    func update(_ candidates: [ItemPreparationCandidate<Item>], context: ItemPreparationContext)
    func itemsChanged(_ items: [Item])
    func demand(for id: Item.ID) -> ContentDemand
    func lengths(in context: ItemPreparationContext) -> [(Item.ID, Double)]
    func retry(_ id: Item.ID) -> Bool
    func stop()
    func finished() async
}

private struct ItemPreparationKey<ID: Hashable & Sendable, Revision: Hashable & Sendable>:
    Sendable, Hashable
{
    let id: ID
    let revision: Revision
    let context: ItemPreparationContext
}

@MainActor
final class PreparedItems<
    Item: Identifiable & Sendable,
    Revision: Hashable & Sendable,
    Value: Sendable
>: ItemPreparing where Item.ID: Sendable {
    private typealias Key = ItemPreparationKey<Item.ID, Revision>
    private typealias Ticket = PreparationTicket<Key>

    private struct Entry {
        var item: Item
        var lifecycle: ContentLifecycle<Key>
        var result: PreparedItem<Value>?
        var error: (any Error)?
    }

    private struct Job: Sendable {
        let item: Item
        let ticket: Ticket
    }

    private struct Running: Sendable {
        let work: Task<PreparedItem<Value>, any Error>
        let completion: Task<Void, Never>
    }

    let policy: ItemPreparationPolicy
    var onChange: (@MainActor () -> Void)?
    var contextIsCurrent: (@MainActor (ItemPreparationContext) -> Bool)?
    private let revision: @MainActor (Item) -> Revision
    private let prepare:
        @Sendable (Item, ItemPreparationContext) async throws -> PreparedItem<Value>
    private let content: @MainActor (Item, PreparedItemState<Value>) -> Node
    private var entries: [Item.ID: Entry] = [:]
    private var order: [Item.ID] = []
    private var queue: [Job] = []
    private var running: [Ticket: Running] = [:]
    private var active = false

    init(
        policy: ItemPreparationPolicy,
        key: @escaping @MainActor (Item) -> Revision,
        prepare:
            @escaping @Sendable (Item, ItemPreparationContext) async throws -> PreparedItem<Value>,
        content: @escaping @MainActor (Item, PreparedItemState<Value>) -> Node
    ) {
        self.policy = policy
        self.revision = key
        self.prepare = prepare
        self.content = content
    }

    deinit {
        for task in running.values { task.work.cancel() }
    }

    var progress: ItemPreparationProgress {
        ItemPreparationProgress(
            running: running.count,
            queued: queue.count,
            retained: entries.count
        )
    }

    func node(for item: Item, context: ItemPreparationContext?) -> Node {
        guard let context, let entry = entries[item.id],
            entry.lifecycle.key == Key(id: item.id, revision: revision(item), context: context)
        else { return content(item, .pending) }

        if let result = entry.result { return content(item, .ready(result)) }
        if let error = entry.error { return content(item, .failed(error)) }
        return content(item, .pending)
    }

    func update(_ candidates: [ItemPreparationCandidate<Item>], context: ItemPreparationContext) {
        active = true
        let admitted = candidates.prefix(policy.maximumRetainedItems)
        let retained = Set(admitted.map { $0.item.id })
        for id in Array(entries.keys) where !retained.contains(id) { remove(id) }
        order = []
        for candidate in admitted {
            let item = candidate.item
            guard !order.contains(item.id) else { continue }
            order.append(item.id)
            let key = Key(id: item.id, revision: revision(item), context: context)
            var entry = entries[item.id] ?? Entry(item: item, lifecycle: ContentLifecycle(key: key))
            if entry.lifecycle.key != key {
                cancel(entry.lifecycle.reset(for: key))
                entry.result = nil
                entry.error = nil
            }
            entry.item = item
            if let change = entry.lifecycle.updateDemand(candidate.demand) {
                cancel(change.cancelled)
            }
            entries[item.id] = entry
        }
        // Re-admit waiting jobs in the new viewport order. A newly visible item must not
        // sit behind a full queue of items that were nearby in the previous viewport.
        for job in queue {
            if var entry = entries[job.item.id] {
                entry.lifecycle.complete(job.ticket, with: .cancelled)
                entries[job.item.id] = entry
            }
        }
        queue = []
        pump()
    }

    func itemsChanged(_ items: [Item]) {
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in Array(entries.keys) {
            guard let item = current[id], let entry = entries[id],
                entry.lifecycle.key.revision == revision(item)
            else {
                remove(id)
                continue
            }
        }
        order.removeAll { entries[$0] == nil }
    }

    func demand(for id: Item.ID) -> ContentDemand { entries[id]?.lifecycle.demand ?? [] }

    func lengths(in context: ItemPreparationContext) -> [(Item.ID, Double)] {
        order.compactMap { id in
            guard let entry = entries[id], entry.lifecycle.key.context == context,
                let length = entry.result?.length
            else { return nil }
            return (id, length)
        }
    }

    func retry(_ id: Item.ID) -> Bool {
        guard var entry = entries[id], entry.error != nil else { return false }
        entry.error = nil
        entry.lifecycle.release(.measurement)
        entries[id] = entry
        pump()
        onChange?()
        return true
    }

    func stop() {
        active = false
        for id in Array(entries.keys) { remove(id) }
        order = []
        queue = []
    }

    func finished() async {
        while !running.isEmpty {
            let batch = running.values.map(\.completion)
            for task in batch { await task.value }
        }
    }

    private func remove(_ id: Item.ID) {
        guard var entry = entries.removeValue(forKey: id) else { return }
        cancel(entry.lifecycle.reset(for: entry.lifecycle.key))
    }

    private func cancel(_ tickets: [Ticket]) {
        let cancelled = Set(tickets)
        queue.removeAll { cancelled.contains($0.ticket) }
        for ticket in tickets { running[ticket]?.work.cancel() }
    }

    private func nextJob() -> Job? {
        for id in order {
            guard var entry = entries[id], let ticket = entry.lifecycle.begin(.measurement) else {
                continue
            }
            entries[id] = entry
            return Job(item: entry.item, ticket: ticket)
        }
        return nil
    }

    private func pump() {
        guard active else { return }
        while running.count < policy.maximumConcurrentTasks {
            guard let job = queue.isEmpty ? nextJob() : queue.removeFirst() else { break }
            start(job)
        }
        while queue.count < policy.maximumQueuedItems, let job = nextJob() { queue.append(job) }
    }

    private func start(_ job: Job) {
        let prepare = self.prepare
        let context = job.ticket.key.context
        let priority: TaskPriority =
            entries[job.item.id]?.lifecycle.demand.contains(.display) == true
            ? .userInitiated : .utility
        let work = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let result = try await prepare(job.item, context)
            try Task.checkCancellation()
            return result
        }
        let completion = Task { [weak self] in
            let result = await work.result
            self?.finish(job.ticket, result: result)
        }
        running[job.ticket] = Running(work: work, completion: completion)
    }

    private func finish(_ ticket: Ticket, result: Result<PreparedItem<Value>, any Error>) {
        running[ticket] = nil
        guard active else { return }
        guard var entry = entries[ticket.key.id], entry.lifecycle.isCurrent(ticket) else {
            pump()
            return
        }
        guard contextIsCurrent?(ticket.key.context) == true else {
            stop()
            onChange?()
            return
        }
        switch result {
        case let .success(value):
            entry.lifecycle.complete(ticket, with: .ready)
            entry.result = value
        case let .failure(error):
            entry.lifecycle.complete(ticket, with: .failed)
            entry.error = error
        }
        entries[ticket.key.id] = entry
        pump()
        onChange?()
    }
}
