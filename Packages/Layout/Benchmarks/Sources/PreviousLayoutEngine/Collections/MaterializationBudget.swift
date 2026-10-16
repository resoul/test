import Foundation

/// Preparation priority of one materialization window inside its host (P6.9): the page the
/// user sees first, then neighbouring pages, then anything else.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum MaterializationPriority: Int, Sendable, Hashable, Comparable {
    /// The window of the visible page.
    case active = 0
    /// A window of an adjacent pager page.
    case adjacent = 1
    /// Any other window.
    case background = 2

    /// Orders by urgency: `.active` first.
    ///
    /// Ownership: none. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A window served by a `MaterializationBudget`. Internal: only `MaterializationWindow`
/// conforms.
@MainActor
protocol MaterializationBudgetClient: AnyObject {
    var budgetPriority: MaterializationPriority { get }
    var budgetLiveCount: Int { get }
    var budgetRequiredCount: Int { get }
    func budgetDidRefill()
}

/// One host's shared preparation budget for all its collection windows (R10, P6.9, ADR 0030).
/// It bounds two things: node creations per pass (MainActor work) and live item nodes across
/// all registered windows (memory). Visible items are always materialized, even beyond the
/// budget; only the display margin around them competes. Higher priority windows are served
/// first, equal priorities rotate each pass for fairness.
///
/// The live limit is enforced at pass boundaries: when a more urgent window grows, the less
/// urgent ones shed their margin at the next `beginPass()`. Separate hosts own separate budgets;
/// there is no process-wide limit.
///
/// Ownership: owned by the host integration; references windows weakly. Isolation: MainActor.
/// Errors: none. Cancellation: a disposed window unregisters itself; nothing is scheduled
/// asynchronously — the host calls `beginPass()` once per commit pass.
@MainActor
public final class MaterializationBudget {
    /// Node creations allowed per pass for display margins.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var creationsPerPass: Int

    /// Upper bound on live item nodes of all registered windows together, visible items
    /// excepted. Lowering it (for example on memory pressure) trims margins at the next pass.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var maximumLiveNodes: Int

    /// Creations still available in the current pass.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var creationsRemaining: Int

    /// Host correlation for diagnostics, `nil` before mount.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var host: UInt64?

    private struct Registration {
        weak var client: (any MaterializationBudgetClient)?
        let order: Int
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var pending: Set<ObjectIdentifier> = []
    private var nextOrder = 0
    private var rotation = 0

    /// Creates a budget.
    ///
    /// Ownership: the caller owns it. Isolation: MainActor. Errors: none — negative limits
    /// become zero. Cancellation: not applicable.
    public init(creationsPerPass: Int = 16, maximumLiveNodes: Int = 256, host: UInt64? = nil) {
        self.creationsPerPass = max(0, creationsPerPass)
        self.maximumLiveNodes = max(0, maximumLiveNodes)
        self.creationsRemaining = max(0, creationsPerPass)
        self.host = host
    }

    /// Live item nodes across registered windows.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var liveNodeCount: Int {
        clients.reduce(0) { $0 + $1.budgetLiveCount }
    }

    /// Number of windows that wait for creations.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var pendingCount: Int { pending.count }

    /// Starts a pass: refills creations and lets waiting or over-limit windows materialize,
    /// most urgent first, rotating equal priorities.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func beginPass() {
        creationsRemaining = creationsPerPass
        let ordered = rotatedClients()
        rotation &+= 1
        var served = 0
        for client in ordered {
            let key = ObjectIdentifier(client)
            let over = client.budgetLiveCount > liveAllowance(for: client)
            guard pending.contains(key) || over else { continue }

            pending.remove(key)
            client.budgetDidRefill()
            served += 1
        }
        guard served > 0 else { return }

        Log.on(
            .schedule,
            "budget-pass",
            host: host,
            "served=\(served) pending=\(pending.count) live=\(liveNodeCount) "
                + "limit=\(maximumLiveNodes) creationsLeft=\(creationsRemaining)"
        )
    }

    func register(_ client: any MaterializationBudgetClient) {
        let key = ObjectIdentifier(client)
        guard registrations[key] == nil else { return }

        registrations[key] = Registration(client: client, order: nextOrder)
        nextOrder += 1
    }

    func unregister(_ client: any MaterializationBudgetClient) {
        let key = ObjectIdentifier(client)
        registrations.removeValue(forKey: key)
        pending.remove(key)
    }

    /// Live nodes `client` may hold: the limit minus what equally or more urgent windows hold
    /// and minus the visible items of less urgent ones.
    func liveAllowance(for client: any MaterializationBudgetClient) -> Int {
        let priority = client.budgetPriority
        var used = 0
        for other in clients where other !== client {
            used +=
                other.budgetPriority <= priority ? other.budgetLiveCount : other.budgetRequiredCount
        }
        return max(0, maximumLiveNodes - used)
    }

    /// Takes up to `count` creations; returns how many were granted.
    func takeCreations(_ count: Int) -> Int {
        let granted = min(max(0, count), creationsRemaining)
        creationsRemaining -= granted
        return granted
    }

    /// Records creations that could not be refused (visible items).
    func chargeRequired(_ count: Int) {
        creationsRemaining = max(0, creationsRemaining - max(0, count))
    }

    func deferWork(for client: any MaterializationBudgetClient) {
        pending.insert(ObjectIdentifier(client))
    }

    private var clients: [any MaterializationBudgetClient] {
        registrations.values.sorted { $0.order < $1.order }.compactMap(\.client)
    }

    private func rotatedClients() -> [any MaterializationBudgetClient] {
        let all = clients
        let groups = Dictionary(grouping: all, by: \.budgetPriority)
        return groups.keys.sorted().flatMap { priority -> [any MaterializationBudgetClient] in
            let group = groups[priority] ?? []
            guard group.count > 1 else { return group }

            let shift = rotation % group.count
            return Array(group[shift...] + group[..<shift])
        }
    }
}
