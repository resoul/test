extension TextStyle {
    /// Whether two styles agree on every geometry-affecting field — everything except `color`,
    /// which never changes measured size (D52: a color-only style change is paint-only).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    fileprivate func hasEqualGeometry(to other: TextStyle) -> Bool {
        fontName == other.fontName && pointSize == other.pointSize && weight == other.weight
            && lineHeight == other.lineHeight && alignment == other.alignment
    }
}

/// A leaf node whose content is text (T04, D55): one canonical `TextDocument`, a paragraph-level
/// `TextStyle`, and the two independent overflow limiters `maxLines`/`truncation` (D56).
///
/// Measurement is not this class's job: `layoutContentMetrics(for:)` hands the solver a
/// `ContentMeasurer` (`TextContentMeasurer`, private below) that captures this call's inputs as
/// plain values and is measured later, at whatever constraint the solver actually resolves
/// (D49/T03) — this method itself ignores its own `constraint` parameter, unlike a node with a
/// truly fixed intrinsic size.
///
/// Accessibility defaults (T08, D57): `isElement`/`label`/`role` are filled from the
/// document's plain characters, on creation and on every text change, without overriding a
/// value the author set explicitly — see `syncAccessibilityDefaults()` below for how "author
/// wins" is tracked without a per-field flag on `AccessibilityProperties` itself.
///
/// Ownership: owns its `document`/`textStyle`/`maxLines`/`truncation` values directly, like any
/// other `Node` style field. Isolation: `MainActor`, like `Node`. Errors: none. Cancellation:
/// `dispose()` needs no override — this class starts no background work of its own; the
/// captured `TextContentMeasurer` is a plain value with no task, resource or `Node` reference to
/// cancel or release.
open class TextNode: Node {
    /// Convenience over `document` for an unstyled run of text — reading returns the document's
    /// plain characters; writing replaces the whole document with one run-free string, which is
    /// what `TextNode(text:)` builds initially.
    ///
    /// Ownership: returns a copy of the current characters; a write goes through `document`'s
    /// own no-op equality (unchanged text is a genuine no-op, not a fresh identical document).
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var text: String {
        get { document.plainCharacters }
        set { document = TextDocument(newValue) }
    }

    /// The canonical text model (D55) — a single `AttributedString`, not a `text`/
    /// `attributedText` pair. Equal documents are a no-op: no revision moves, no work is
    /// requested (T04 acceptance: "тот же текст → ноль работ").
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var document: TextDocument {
        didSet {
            guard document != oldValue else { return }
            syncAccessibilityDefaults()
            didChangeGeometryAffectingContent()
        }
    }

    /// The paragraph-level base style. A change that touches only `color` is paint-only (D52);
    /// any other field change affects measured size and is geometry-affecting.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var textStyle: TextStyle {
        didSet {
            guard textStyle != oldValue else { return }

            if textStyle.hasEqualGeometry(to: oldValue) {
                didChangeDisplayOnlyContent()
            } else {
                didChangeGeometryAffectingContent()
            }
        }
    }

    /// Maximum visible lines, or `nil` for no limit (D56).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var maxLines: Int? {
        didSet {
            guard maxLines != oldValue else { return }
            didChangeGeometryAffectingContent()
        }
    }

    /// How overflow is handled once `maxLines` or the height limit is reached (D56).
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var truncation: TextTruncation {
        didSet {
            guard truncation != oldValue else { return }
            didChangeGeometryAffectingContent()
        }
    }

    /// Number of times this node's own paint-only display state changed — a color-only
    /// `textStyle` write (ADR 0014's `DirtyReasons.display`). Independent of
    /// `geometryRevision`/`structureRevision`: a display-only change never advances either.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var displayRevision: UInt64 = 0

    /// The `isElement`/`label`/`role` this `TextNode` itself last wrote into `accessibility`
    /// (D57) — `nil` before the first sync. Compared against the live `accessibility` value in
    /// `syncAccessibilityDefaults()` to tell "the author never touched this field" (it still
    /// equals what we last wrote) from "the author overrode it" (it does not), one field at a
    /// time, without adding an author-tracking flag to `AccessibilityProperties` itself — that
    /// type is shared by every `Node` and has no notion of "default vs. authored".
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    private var lastAutoIsElement: Bool?
    private var lastAutoLabel: String??
    private var lastAutoRole: AccessibilityRole??

    /// Creates a text node from a plain string — no run overrides, styled entirely by
    /// `textStyle` (D55's convenience initializer).
    ///
    /// Ownership: the returned node owns its copied fields. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public convenience init(
        text: String,
        textStyle: TextStyle = TextStyle(),
        maxLines: Int? = nil,
        truncation: TextTruncation = .tail,
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.init(
            document: TextDocument(text),
            textStyle: textStyle,
            maxLines: maxLines,
            truncation: truncation,
            style: style,
            appearance: appearance,
            environment: environment
        )
    }

    /// Creates a text node from a fully-built document — the canonical path; `init(text:)` is a
    /// convenience over this one, not a second source of truth (D55, avoiding the W07-class
    /// defect of independent `text`/`attributedText` fields).
    ///
    /// Ownership: the returned node owns its copied fields. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init(
        document: TextDocument,
        textStyle: TextStyle = TextStyle(),
        maxLines: Int? = nil,
        truncation: TextTruncation = .tail,
        style: LayoutStyle = LayoutStyle(),
        appearance: VisualStyle = VisualStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.document = document
        self.textStyle = textStyle
        self.maxLines = maxLines
        self.truncation = truncation
        super.init(style: style, appearance: appearance, environment: environment)
        syncAccessibilityDefaults()
    }

    /// Hands the solver a `ContentMeasurer` capturing this call's inputs as plain values
    /// (D49) — `constraint` itself is unused here; the solver measures at the constraints it
    /// actually resolves (T03), not at whatever this method happened to receive.
    ///
    /// Ownership: the returned value owns copied fields and a non-retaining `ObjectIdentifier`
    /// of this node (stable across snapshots, per D49 — never a fresh identity per call), not a
    /// reference to `self`. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public override func layoutContentMetrics(for constraint: SizeConstraint)
        -> LayoutContentMetrics
    {
        let measurer = TextContentMeasurer(
            identity: ObjectIdentifier(self),
            revision: geometryRevision,
            document: document,
            textStyle: textStyle,
            maxLines: maxLines,
            truncation: truncation,
            direction: environment.layoutDirection,
            localeIdentifier: environment.localeIdentifier,
            renderer: environment.textRenderer
        )
        return LayoutContentMetrics(measurer: measurer)
    }

    private func didChangeGeometryAffectingContent() {
        markGeometryDirty(structural: false)
    }

    private func didChangeDisplayOnlyContent() {
        displayRevision &+= 1
        markDisplayDirty()
    }

    /// Fills `accessibility.isElement`/`label`/`role` from the document's plain characters
    /// (D57), field by field, without overwriting a field the author explicitly set. Called
    /// once from `init` (after `super.init`, so `id`/`environment` exist for `markSemanticsDirty`
    /// to reach) and again on every `document` change.
    ///
    /// "Author explicitly set" is read off the *shadow* values above, not off
    /// `AccessibilityProperties` itself (D57's "explicit override distinct from automatic
    /// value" — `AccessibilityProperties` carries no such distinction, and adding one there
    /// would leak a `TextNode`-only concern onto every `Node`): a field still equal to what
    /// this `TextNode` itself last wrote is untouched by the author and gets the new automatic
    /// value; a field that no longer matches was reassigned since. A shadow value is updated
    /// *only* inside the branch that actually auto-wrote it — left frozen at the last real
    /// automatic value otherwise, so an overridden field's live value keeps disagreeing with
    /// its frozen shadow on every later call and the override is never resynced away. (An
    /// earlier draft wrote every shadow unconditionally after the `if`s, which copied an
    /// author's override straight into the shadow it should have stayed distinguishable from —
    /// the very next text change then compared the live value to *that* copy, matched, and
    /// silently reasserted the automatic value over the author's explicit opt-out. Caught by a
    /// second-text-change regression test before this card was committed.) The one gap this
    /// approach still cannot close without a dedicated flag on `AccessibilityProperties`: an
    /// author write that happens to set a field to exactly the automatic value already shown
    /// reads as untouched and may be resynced on a later text change — T08's acceptance does
    /// not require closing that narrow coincidence, only that a genuine override survives.
    ///
    /// One assignment to `accessibility` covers all three fields that changed this call —
    /// `Node.accessibility`'s no-op equality (C09) then decides on its own whether anything
    /// actually moved, exactly like any other caller's write.
    private func syncAccessibilityDefaults() {
        let newLabel = text
        var updated = accessibility

        if lastAutoIsElement == nil || accessibility.isElement == lastAutoIsElement {
            updated.isElement = true
            lastAutoIsElement = true
        }
        if lastAutoLabel == nil || accessibility.label == (lastAutoLabel ?? nil) {
            updated.label = newLabel
            lastAutoLabel = newLabel
        }
        if lastAutoRole == nil || accessibility.role == (lastAutoRole ?? nil) {
            updated.role = .text
            lastAutoRole = .text
        }

        accessibility = updated
    }
}

/// `TextNode`'s `ContentMeasurer` — a plain, `Sendable` value capturing one snapshot's worth of
/// text input, with no reference to the `Node` it came from (D49/D58). `identity` is the
/// owning `TextNode`'s own `ObjectIdentifier`, stable across every snapshot this node ever
/// produces; `revision` is that node's `geometryRevision` at capture time, which only advances
/// when a geometry-affecting field actually changed (T04) — exactly the property `identity`/
/// `revision` equality is contractually required to track (D49).
///
/// Ownership: value type; owns copied fields, borrows nothing. Isolation: none — `Sendable`,
/// called from background solver work. Errors: see `measure(_:context:)`. Cancellation: see
/// `measure(_:context:)`.
private struct TextContentMeasurer: ContentMeasurer {
    let identity: ObjectIdentifier
    let revision: UInt64
    let document: TextDocument
    let textStyle: TextStyle
    let maxLines: Int?
    let truncation: TextTruncation
    let direction: LayoutDirection
    let localeIdentifier: String
    let renderer: (any TextRenderer)?

    private static let fallback = PortableTextMeasurer()

    func measure(_ constraint: SizeConstraint, context: LayoutContext) throws
        -> LayoutContentMetrics
    {
        let input = TextLayoutInput(
            document: document,
            style: textStyle,
            direction: direction,
            localeIdentifier: localeIdentifier,
            maxLines: maxLines,
            truncation: truncation
        )
        let metrics = try (renderer ?? Self.fallback).measure(
            input,
            constraint: constraint,
            context: context
        )
        return LayoutContentMetrics(intrinsic: metrics.size, firstBaseline: metrics.firstBaseline)
    }
}
