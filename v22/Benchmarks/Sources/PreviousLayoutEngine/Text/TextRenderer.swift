/// Measures a `TextLayoutInput` into `TextMetrics` — the environment-sourced backend `TextNode`
/// uses (D51), instead of a global registry (unlike Weave's `TextLayoutBackendRegistry`, W05).
///
/// This protocol carries only measurement for now. Rasterization (`DisplayArtifact`, T06) is
/// added as a further requirement once that type exists (T05/T06) rather than stubbed here —
/// `CoreTextRenderer` is the first and, until then, only conformer, so widening it in the same
/// development sequence is not a compatibility break for anyone. See
/// `docs/validation/t04-text-node.md` for why this narrows D51's original combined sketch.
///
/// Ownership: implementers are typically small value types or long-lived references owned by
/// whichever host installs them via `TextRendererKey`. Isolation: none — `Sendable` so
/// `TextNode`'s snapshot-time `ContentMeasurer` can call it from background solver work.
/// Errors: `measure(_:context:)` throws `LayoutCancellationError.cancelled` when `context`
/// reports cancellation. Cancellation: implementers check cooperatively at least once per line
/// for multi-line content (D58).
public protocol TextRenderer: Sendable {
    /// Measures `input` against `constraint` — the actual space the solver resolved this text
    /// node's content area to (D49/§3.1), wrapping and truncating per `input.maxLines`/
    /// `input.truncation`. `constraint` is not part of `TextLayoutInput` itself because it
    /// varies per call at the same input — the solver measures a leaf at more than one
    /// constraint in one pass (basis, exact-main, exact-both fallback; T03).
    ///
    /// Ownership: the result is a value, owned by the caller. Isolation: none — safe to call
    /// from any thread the solver runs on. Errors: throws `LayoutCancellationError.cancelled`
    /// if `context` reports cancellation before or during measurement. Cancellation: checked
    /// cooperatively inside multi-line content; a cancelled call returns no partial result.
    func measure(
        _ input: TextLayoutInput,
        constraint: SizeConstraint,
        context: LayoutContext
    ) throws -> TextMetrics
}

/// The `TextRenderer` a host installs at `attach` (T09), or `nil` before any host has (D51).
/// `TextNode` treats `nil` as "no host renderer yet" and falls back to `PortableTextMeasurer`
/// (explicitly not real typography, D51/#40) rather than failing measurement outright — see
/// `docs/validation/t04-text-node.md` for why a mounted-but-misconfigured host is not yet
/// distinguished from a genuinely headless one; T09 is expected to close that gap once a host
/// has a signal to distinguish the two.
///
/// Ownership: not applicable — a key type is never instantiated. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum TextRendererKey: EnvironmentKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue: (any TextRenderer)? = nil
}

/// BCP-47-ish locale identifier for text measurement and rasterization — a plain environment
/// value until a real localization story exists (mirrors `LayoutDirectionKey`'s own note).
///
/// Ownership: not applicable. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LocaleKey: EnvironmentKey {
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue = "en"
}

extension EnvironmentValues {
    /// The `TextRenderer` in effect for this scope, or `nil` before any host has installed one.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var textRenderer: (any TextRenderer)? {
        get { self[TextRendererKey.self] }
        set { self[TextRendererKey.self] = newValue }
    }

    /// The locale identifier in effect for this scope.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var localeIdentifier: String {
        get { self[LocaleKey.self] }
        set { self[LocaleKey.self] = newValue }
    }
}

extension Node {
    /// Sets this node's `TextRenderer`, for `self` and every descendant that does not set its
    /// own (T09) — a convenience over `setEnvironment(_:to:)` for this well-known key, typically
    /// called once by a host on the root at `attach`. `nil` restores the headless fallback
    /// (`PortableTextMeasurer`, D51) for this subtree.
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setTextRenderer(_ renderer: (any TextRenderer)?) {
        setEnvironment(TextRendererKey.self, to: renderer)
    }

    /// Sets this node's locale identifier, for `self` and every descendant that does not set its
    /// own (T09) — a convenience over `setEnvironment(_:to:)` for this well-known key, typically
    /// called once by a host on the root at `attach` and again whenever the host's locale
    /// changes. Bumps this scope's environment revision unconditionally, like
    /// `setLayoutDirection`/`setSafeAreaInsets` — the same "a host calls this only when its own
    /// state actually changed" contract, not a per-call equality check here.
    ///
    /// Ownership: the scope owns the stored value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setLocaleIdentifier(_ identifier: String) {
        setEnvironment(LocaleKey.self, to: identifier)
    }
}
