/// Whether the system's reduced-motion accessibility setting is in effect (D67) — a plain
/// environment value until a host installs the real system value, mirroring
/// `LocaleKey`/`TextRendererKey`'s own note about this stage having no auto-detection of its
/// own.
///
/// Ownership: not applicable — a key type is never instantiated. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum ReduceMotionKey: EnvironmentKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the mounted tree should resolve every `Node.animate` intent to `.none` instead
    /// of its requested timing (D67). Read live at commit time by the renderer that turns an
    /// `AnimationIntent` into an explicit `CABasicAnimation` — setting this value does not, by
    /// itself, touch any animation already in flight; a host that flips it while something is
    /// mid-transition is responsible for also finishing that transition immediately (D67's
    /// "включение во время движения немедленно завершает собственные активные переходы").
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var reduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

extension Node {
    /// Sets this node's Reduce Motion override, for `self` and every descendant that does not
    /// set its own (D67) — a convenience over `setEnvironment(_:to:)` for this well-known key,
    /// typically called once by a host on the root at `attach` and again whenever the host's
    /// system setting changes. Bumps this scope's environment revision unconditionally, like
    /// `setLocaleIdentifier`/`setLayoutDirection` — the same "a host calls this only when its
    /// own state actually changed" contract, not a per-call equality check here.
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setReduceMotion(_ isEnabled: Bool) {
        setEnvironment(ReduceMotionKey.self, to: isEnabled)
    }
}
