import AsyncRay
import DataAsyncRay
import FlexEngine
import LayoutCore
import Nodes
import StateAsyncRay
import StateCore
import StorageCore
import ThemeCore

/// A row of a fixed height.
@MainActor
public final class RowNode: Node {
    /// The row's height, in points.
    public let height = State(44.0)

    public override var layoutContent: LeafContent? { .size(width: 0, height: height.value) }
}

/// A list whose density follows a stored preference — the packages together: the data
/// package stores the preference, the bridges stream it into a state, the node tree reads the
/// state, and the layout package lays the rows out with the theme's spacing.
@MainActor
public final class DensityListNode: Node {
    /// Whether rows are compact; bound to the stored preference.
    public let compact = State(false)
    /// The rows.
    public let rows = (0..<3).map { _ in RowNode() }
    private let subscriptions = SubscriptionBag()

    /// Follows `key` in `preferences` until the node goes.
    public func follow(_ key: PreferenceKey<Bool>, in preferences: some PreferenceStore) {
        preferences.valuesRay(for: key)
            .compactMap { try? $0.get() }
            .bind(to: compact)
            .store(in: subscriptions)
    }

    /// Row heights follow the density.
    public override func update() {
        for row in rows { row.height.value = compact.value ? 32 : 44 }
    }

    /// The rows in a column, closer together when compact.
    public override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            for row in rows { row }
        }
        .gap(compact.value ? .s1 : .s3)
        .padding(.s4)
    }
}

/// Lays the list out, switches the stored preference, and lays it out again.
///
/// - Returns: The height the rows take before and after the switch.
@MainActor
public func runDensityList() async throws -> (regular: Double, compact: Double) {
    let preferences = MemoryPreferences()
    let key = PreferenceKey("list.compact", default: false)
    let list = DensityListNode()
    let host = NodeHost(root: list, size: LayoutSize(width: 320, height: 480))
    list.follow(key, in: preferences)
    host.layoutIfNeeded()
    let regular = list.rows.last!.frame.maxY - list.rows.first!.frame.origin.y

    try await preferences.set(true, for: key)
    for _ in 0..<200 where !list.compact.value {
        try await Task.sleep(for: .milliseconds(5))
    }
    host.layoutIfNeeded()
    let compact = list.rows.last!.frame.maxY - list.rows.first!.frame.origin.y
    return (regular, compact)
}

extension LayoutRect {
    fileprivate var maxY: Double { origin.y + size.height }
}
