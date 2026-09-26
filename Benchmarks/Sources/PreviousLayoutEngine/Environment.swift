/// A typed slot in `EnvironmentValues`, identified by the key type itself rather than a string.
///
/// Ownership: keys are never instantiated — only `Self.Type` is used as a dictionary key, and
/// metatypes are inherently Sendable. Isolation: none. Errors: none. Cancellation: not applicable.
public protocol EnvironmentKey {
    associatedtype Value: Sendable

    /// The value in effect when nothing along the scope chain has overridden this key.
    static var defaultValue: Value { get }

    /// Whether a change of this key can change measured geometry. Defaults to `true`; a
    /// paint-only key (for example `ThemeKey`, D52) returns `false`, so its changes advance
    /// `EnvironmentSnapshot.revision` but not `layoutRevision` (R10, P6.9).
    static var affectsLayout: Bool { get }
}

extension EnvironmentKey {
    /// Default: conservatively geometry-affecting.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static var affectsLayout: Bool { true }
}

/// Sparse, type-safe bag of values inherited down a node tree — only explicitly-set keys are
/// stored; reading an unset key returns `Key.defaultValue`.
///
/// Ownership: the value owns copied entries. Isolation: none — plain immutable-per-copy value
/// semantics, safe to read from anywhere. Errors: none. Cancellation: not applicable.
public struct EnvironmentValues: Sendable {
    private var storage: [ObjectIdentifier: any Sendable] = [:]

    /// Creates an empty bag — every key reads as its own default.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Reads or overrides one key's value.
    ///
    /// Ownership: returns a value; a write replaces any prior entry for this key. Isolation:
    /// none. Errors: none — a corrupted or missing entry falls back to `Key.defaultValue`
    /// rather than trapping. Cancellation: not applicable.
    public subscript<Key: EnvironmentKey>(key: Key.Type) -> Key.Value {
        get { storage[ObjectIdentifier(key)] as? Key.Value ?? Key.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }

    /// Overlays `other`'s explicitly-set entries on top of `self`, `other` winning on conflicts.
    ///
    /// Ownership: returns a new value; neither input is mutated. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    func merged(with other: EnvironmentValues) -> EnvironmentValues {
        var result = self
        result.storage.merge(other.storage) { _, overriding in overriding }
        return result
    }
}

extension EnvironmentValues {
    /// The logical direction resolved leading/trailing edges use, defaulting to left-to-right.
    ///
    /// This stage has no locale-driven auto-detection (unlike Weave's `LayoutDirectionResolver`)
    /// — it is a plain settable value until a real localization story exists.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var layoutDirection: LayoutDirection {
        get { self[LayoutDirectionKey.self] }
        set { self[LayoutDirectionKey.self] = newValue }
    }

    /// Host-provided safe-area insets, in the same logical (leading/trailing) terms as
    /// `LayoutStyle.padding` — RTL resolution happens once, later, via `resolved(for:)`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var safeAreaInsets: DirectionalEdgeInsets {
        get { self[SafeAreaInsetsKey.self] }
        set { self[SafeAreaInsetsKey.self] = newValue }
    }

    /// Effective inherited theme snapshot.
    ///
    /// Ownership: returns or stores a value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

private enum LayoutDirectionKey: EnvironmentKey {
    static let defaultValue = LayoutDirection.leftToRight
}

private enum SafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue = DirectionalEdgeInsets()
}

/// Inherited theme used to resolve semantic `Fill.theme` colors.
///
/// Ownership: the key supplies an immutable default. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum ThemeKey: EnvironmentKey {
    /// Theme holds colors only (D52): a change repaints but never re-measures.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let affectsLayout = false

    /// Default neutral theme when no scope overrides it.
    ///
    /// Ownership: immutable shared value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static let defaultValue = Theme.defaultValue
}

extension Node {
    /// Sets this node's layout direction override, for `self` and every descendant that does
    /// not set its own. A convenience over `setEnvironment(_:to:)` for this well-known key,
    /// which stays private to this file — most call sites want a name, not a key type.
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setLayoutDirection(_ direction: LayoutDirection) {
        setEnvironment(LayoutDirectionKey.self, to: direction)
    }

    /// Sets this node's safe-area insets, in logical (leading/trailing) terms — RTL resolution
    /// happens later, via `resolved(for:)`. A convenience over `setEnvironment(_:to:)` for this
    /// well-known key, typically called once by a host on the root (C17/C18).
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setSafeAreaInsets(_ insets: DirectionalEdgeInsets) {
        setEnvironment(SafeAreaInsetsKey.self, to: insets)
    }
}

/// Immutable, frozen combination of resolved environment values and how many scope changes
/// (own or inherited) produced them.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentSnapshot: Sendable {
    /// Resolved values: this scope's overrides layered on top of its inherited chain.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let values: EnvironmentValues

    /// Increases whenever this scope or any ancestor changes. Stamps come from one clock
    /// shared by all scopes (defect #81), so an ancestor change always yields a new maximum;
    /// only meaningful as "has this same tree's environment changed since I last looked".
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let revision: UInt64

    /// Like `revision`, but advanced only by keys whose `affectsLayout` is `true` and by
    /// reparenting. Measurement caches key on it; a paint-only change leaves it unchanged.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let layoutRevision: UInt64

    /// Creates a snapshot from already-resolved values and revisions. `layoutRevision`
    /// defaults to `revision` — every change treated as geometry-affecting.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(values: EnvironmentValues, revision: UInt64, layoutRevision: UInt64? = nil) {
        self.values = values
        self.revision = revision
        self.layoutRevision = layoutRevision ?? revision
    }
}

/// Which logical edges a safe-area boundary excludes when folding insets into its own padding.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct SafeAreaEdges: OptionSet, Sendable, Hashable {
    /// The underlying bitmask.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rawValue: UInt8

    /// Creates an edge set from a raw bitmask.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The top edge.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let top = SafeAreaEdges(rawValue: 1 << 0)

    /// The leading edge — left in LTR, right in RTL.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let leading = SafeAreaEdges(rawValue: 1 << 1)

    /// The bottom edge.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let bottom = SafeAreaEdges(rawValue: 1 << 2)

    /// The trailing edge — right in LTR, left in RTL.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let trailing = SafeAreaEdges(rawValue: 1 << 3)

    /// No edges — safe area folds in fully, nothing excluded.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let none: SafeAreaEdges = []

    /// Every edge — safe area is fully excluded.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let all: SafeAreaEdges = [.top, .leading, .bottom, .trailing]
}

/// MainActor-owned node in the environment inheritance tree, independent of the `Node` tree's
/// own parent/child structure but kept in sync with it (`Node.addSubnode`/`removeFromSupernode`
/// reparent the matching scope).
///
/// Ownership: holds its parent weakly, mirroring `Node`'s own weak-parent/strong-children shape
/// (D02) — a scope subtree never keeps an ancestor scope alive. Isolation: MainActor. Errors:
/// none. Cancellation: not applicable.
@MainActor
public final class EnvironmentScope {
    private weak var parent: EnvironmentScope?
    private var overrides = EnvironmentValues()
    private var revision: UInt64 = 0
    private var layoutRevision: UInt64 = 0

    /// One clock for every scope, so a change anywhere gets a stamp greater than every earlier
    /// one. `snapshot` combines revisions with `max`; with per-scope counters an ancestor's
    /// change could stay below a descendant's own count and leave its revision unchanged
    /// (defect #81).
    private static var clock: UInt64 = 0

    private static func tick() -> UInt64 {
        clock &+= 1
        return clock
    }

    /// Creates a scope, optionally chained under an existing parent scope.
    ///
    /// Ownership: holds `parent` weakly. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(parent: EnvironmentScope? = nil) {
        self.parent = parent
    }

    /// Resolves this scope's effective values and revision by walking the live parent chain.
    /// Never cached: there is nothing to invalidate, because every read reflects the tree as
    /// it is right now.
    ///
    /// Ownership: returns a new value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var snapshot: EnvironmentSnapshot {
        guard let parent else {
            return EnvironmentSnapshot(
                values: overrides,
                revision: revision,
                layoutRevision: layoutRevision
            )
        }
        let inherited = parent.snapshot
        return EnvironmentSnapshot(
            values: inherited.values.merged(with: overrides),
            revision: max(revision, inherited.revision),
            layoutRevision: max(layoutRevision, inherited.layoutRevision)
        )
    }

    /// Overrides one key on this scope, advancing its revision.
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func set<Key: EnvironmentKey>(_ key: Key.Type, to value: Key.Value) {
        overrides[key] = value
        revision = Self.tick()
        if Key.affectsLayout {
            layoutRevision = revision
        }
    }

    /// Re-chains this scope under a different parent (or detaches it with `nil`), advancing its
    /// revision so the very next `snapshot` read reflects the new inherited chain.
    ///
    /// Ownership: holds the new parent weakly. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func reparent(to newParent: EnvironmentScope?) {
        parent = newParent
        revision = Self.tick()
        layoutRevision = revision
    }
}
