#if canImport(CoreText)
    import CoreText
    import Foundation
    import os
    import LayoutCore
    import Nodes
    import RichTextCore
    import ThemeCore
    import QuartzCore

    /// How text looks.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct TextStyle: Sendable, Hashable {
        /// Horizontal placement of the lines.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public enum Alignment: Sendable, Hashable {
            /// At the start of the layout: the right edge when the host lays out right to
            /// left; otherwise the start of the text's own writing direction (the left edge
            /// for Latin text, the right one for Arabic).
            case leading
            case center
            /// At the right edge, in either direction.
            case right
        }

        /// Stroke weight of the system font.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public typealias Weight = FontWeight

        /// A font of the theme: when set, the font's name, size, weight and line spacing come
        /// from the theme of the text's node, at the reader's text size, instead of the
        /// style's own.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var role: FontRole?
        /// A font by its PostScript name; `nil` for the system font in `weight`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var fontName: String?
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var size: Double = 17
        /// Weight of the system font; a named font has its own.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var weight: Weight = .regular
        /// The color of the text; `nil` for the theme's color for `colorRole`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var color: Color?
        /// The theme's color the text takes when it has no `color` of its own.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var colorRole: ColorRole = .primaryText
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var alignment: Alignment = .leading
        /// Extra space between lines, in points.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var lineSpacing: Double = 0
        /// At most this many lines; the last one shown ends with "…" when the text goes on.
        /// `nil` for no limit.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var maxLines: Int?
        /// Whether the size and line spacing grow and shrink with the reader's text size, as
        /// the theme's fonts do. Turn it off for text that must keep its size — a label on a
        /// box of fixed size.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var scalesWithText = true

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(
            fontName: String? = nil,
            size: Double = 17,
            weight: Weight = .regular,
            color: Color? = nil,
            colorRole: ColorRole = .primaryText
        ) {
            self.fontName = fontName
            self.size = size
            self.weight = weight
            self.color = color
            self.colorRole = colorRole
        }

        /// Text in the theme's font for `role`, in `color` — the theme's color for
        /// `colorRole` when `nil`.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(_ role: FontRole, color: Color? = nil, colorRole: ColorRole = .primaryText) {
            self.role = role
            self.color = color
            self.colorRole = colorRole
        }

        /// The style with the theme's values in: the font of `role`, if any, at the reader's
        /// text size unless `scalesWithText` is off, and the color.
        ///
        /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public func resolved(in theme: ResolvedTheme) -> TextStyle {
            var style = self
            var font = ThemeFont(
                name: fontName,
                size: size,
                weight: weight,
                lineSpacing: lineSpacing
            )
            if let role {
                font = theme.theme.typography[role]
                style.role = nil
            }
            if scalesWithText {
                font = font.scaled(by: theme.conditions.textScale)
            }
            style.fontName = font.name
            style.size = font.size
            style.weight = font.weight
            style.lineSpacing = font.lineSpacing
            style.color = color ?? theme.color(colorRole)
            return style
        }
    }

    extension FontWeight {
        /// The Core Text weight trait, from -1 (thinnest) to 1 (heaviest).
        var trait: Double {
            switch self {
            case .regular: 0
            case .medium: 0.23
            case .semibold: 0.3
            case .bold: 0.4
            }
        }
    }

    /// A node showing text, wrapped to the width its layout gives it.
    ///
    ///     let title = Text("Hello", style: TextStyle(size: 22))
    ///     title.text = user.name        // lays the tree out again
    ///
    /// Ownership: the creator owns it. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public final class Text: Node, LayerDrawing {
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var text: String {
            didSet { if text != oldValue { contentChanged() } }
        }

        /// Styled text shown instead of `text`, or `nil` to show `text`. Its blocks are set one
        /// under another, in the node's style with the marks of each run on top: bold, italic,
        /// a monospaced font, strikethrough, underline and links, which show in the theme's
        /// accent color and underlined. A quote gets a bar beside it and code a plate behind
        /// it; code lines that do not fit wrap at any character rather than being cut. With
        /// `maxLines`, the lines are counted over all blocks.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var rich: RichText? {
            didSet { if rich != oldValue { contentChanged() } }
        }

        /// Called with the link the reader taps in `rich`. Without it, links look like links
        /// and do nothing.
        ///
        /// Each link is also an action of the text for assistive technologies, named by the
        /// link's words — so the text is read once and the links are its actions, not extra
        /// elements — which means `accessibilityActions` of a text that shows links belongs to
        /// the text. The remote's select button opens a link when the text has only one; a
        /// text with several is not offered to it.
        ///
        /// Ownership: the node keeps the closure; it must not keep the node. Isolation:
        /// MainActor. Errors: none. Cancellation: not applicable.
        public var onLink: (@MainActor (URL) -> Void)? {
            didSet { linksChanged() }
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var style: TextStyle {
            didSet { if style != oldValue { restyle() } }
        }

        /// `style` with the values of the node's theme in: what is measured and drawn.
        private(set) var shown: TextStyle

        /// Grows with the text and the style, and changes with the host's direction, which
        /// moves `leading` text to the other edge.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var drawingRevision: UInt64 { revision &* 2 &+ (isRightToLeft ? 1 : 0) }

        private var revision: UInt64 = 0

        /// What the text measured at, kept across layouts until the text or its style
        /// changes: the engine asks the same questions on every pass.
        private var measurements = TextMeasurements()

        private var isRightToLeft: Bool { host?.direction == .rightToLeft }

        /// What the blocks of `rich` measured at; kept across edits, since a block that was
        /// not touched is found again by its content.
        private let richMeasurements = RichTextMeasurements()

        /// Block layouts made for drawing and for finding links, by what they depend on. They
        /// are the layouts the measurer's numbers come from, made again here with colors.
        private var richLayouts: [RichLayoutKey: RichBlockLayout] = [:]

        private struct RichLayoutKey: Hashable {
            let block: RichText.Block
            let width: Double
            let metrics: RichMetrics
            let colors: RichColors
        }

        /// The color links and quote bars take from the theme.
        private var shownAccent = Theme.standard.resolved(for: .standard).color(.accent)

        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(_ text: String = "", style: TextStyle = TextStyle()) {
            self.text = text
            self.style = style
            shown = style.resolved(in: Theme.standard.resolved(for: .standard))
            super.init()
        }

        /// Shows styled text; see `rich`.
        ///
        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public convenience init(rich: RichText, style: TextStyle = TextStyle()) {
            self.init(rich.plainText, style: style)
            self.rich = rich
            linksChanged()
        }

        /// Follows the node's theme: its fonts and colors, at the reader's text size.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
        public override func update() {
            restyle()
        }

        /// Takes the theme's values into the shown style: a new font lays the text out
        /// again, a new color only draws it again.
        private func restyle() {
            let accent = theme.color(.accent)
            if accent != shownAccent {
                shownAccent = accent
                if rich != nil {
                    revision &+= 1
                    host?.setNeedsRender()
                }
            }
            let now = style.resolved(in: theme)
            guard now != shown else { return }

            var sameMetrics = now
            sameMetrics.color = shown.color
            let onlyColor = sameMetrics == shown
            shown = now
            if onlyColor {
                revision &+= 1
                host?.setNeedsRender()
            } else {
                contentChanged()
            }
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var layoutContent: LeafContent? {
            if let rich {
                return .measured(
                    RichTextMeasurer(
                        text: rich,
                        metrics: RichMetrics(shown, rightToLeft: isRightToLeft),
                        maxLines: shown.maxLines.map { max(1, $0) },
                        measurements: richMeasurements
                    )
                )
            }
            return .measured(TextMeasurer(text: text, style: shown, measurements: measurements))
        }

        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func draw(in context: CGContext, size: CGSize) {
            if rich != nil {
                richLayout(width: Double(size.width))?
                    .draw(in: context, size: size, colors: richColors)
                return
            }
            TextLayout(text: text, style: shown, rightToLeft: isRightToLeft)
                .draw(in: context, size: size)
        }

        private var richColors: RichColors {
            RichColors(
                text: shown.color ?? Color(red: 0, green: 0, blue: 0),
                link: shownAccent,
                bar: shownAccent
            )
        }

        /// The rich text laid out at `width`: the one layout that draws it and tells which link
        /// a point is on.
        private func richLayout(width: Double) -> RichPlacedLayout? {
            guard let rich else { return nil }

            let metrics = RichMetrics(shown, rightToLeft: isRightToLeft)
            let colors = richColors
            if richLayouts.count > 256 { richLayouts = [:] }
            let blocks = rich.blocks.map { block -> RichBlockLayout in
                let key = RichLayoutKey(
                    block: block,
                    width: width,
                    metrics: metrics,
                    colors: colors
                )
                if let known = richLayouts[key] { return known }

                let made = RichBlockLayout(block, width: width, metrics: metrics, colors: colors)
                richLayouts[key] = made
                return made
            }
            return RichPlacedLayout(
                blocks: blocks,
                width: width,
                metrics: metrics,
                maxLines: shown.maxLines.map { max(1, $0) }
            )
        }

        /// The links of `rich`: the words of each and where it leads. Neighbouring runs that
        /// share a link — a link with a bold word in it — are one link.
        var links: [(text: String, url: URL)] {
            guard let rich else { return [] }

            var found: [(text: String, url: URL)] = []
            for block in rich.blocks {
                var last: URL?
                for run in block.runs {
                    guard let url = run.link else {
                        last = nil
                        continue
                    }
                    if url == last, !found.isEmpty {
                        found[found.count - 1].text += run.text
                    } else {
                        found.append((run.text, url))
                    }
                    last = url
                }
            }
            return found
        }

        /// A tap on a link opens it; a tap elsewhere is left to what is behind the text.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override func takesPress(at point: LayoutPoint) -> Bool {
            guard onLink != nil, rich != nil,
                let layout = richLayout(width: frame.size.width)
            else { return false }

            return layout.link(at: CGPoint(x: point.x, y: point.y)) != nil
        }

        /// The hand, while the pointer is over a link of a text that opens links itself.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var pointerStyle: PointerStyle {
            onTap == nil && onLink != nil ? .pointingHand : .arrow
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override var isTappable: Bool {
            onTap != nil || (onLink != nil && links.count == 1)
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override func tapped(at point: LayoutPoint?) {
            if onTap == nil, let onLink {
                if let point {
                    if let url = richLayout(width: frame.size.width)?
                        .link(at: CGPoint(x: point.x, y: point.y))
                    {
                        onLink(url)
                    }
                } else if links.count == 1 {
                    onLink(links[0].url)
                }
                return
            }
            super.tapped(at: point)
        }

        /// The links become the actions of the text, one each. Actions the caller set on a text
        /// with no links are left alone.
        private func linksChanged() {
            let found = onLink == nil ? [] : links
            guard !found.isEmpty || ownsLinkActions else { return }

            ownsLinkActions = !found.isEmpty
            accessibilityActions = found.map { link in
                let words =
                    link.text.count > 40 ? String(link.text.prefix(40)) + "\u{2026}" : link.text
                let url = link.url
                return AccessibilityAction(name: "Open link \(words)") { [weak self] in
                    guard let onLink = self?.onLink else { return false }

                    onLink(url)
                    return true
                }
            }
        }

        private var ownsLinkActions = false

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var accessibilityContentLabel: String? { rich?.plainText ?? text }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var accessibilityContentTraits: AccessibilityTraits { .staticText }

        private func contentChanged() {
            revision &+= 1
            measurements = TextMeasurements()
            linksChanged()
            setNeedsLayout()
        }
    }

    /// Measures text for the layout engine, on any thread. Strings are built by
    /// `TextLayout`, the same code that draws, so what is measured is what is drawn; what it
    /// measured goes to `measurements`, which the node keeps for its text and style.
    struct TextMeasurer: ContentMeasurer {
        let text: String
        let style: TextStyle
        let measurements: TextMeasurements

        func minContentWidth() -> Double {
            measurements.value(\.minContentWidth) {
                let layout = TextLayout(text: text, style: style)
                let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                return words.map { layout.lineWidth(String($0)) }.max() ?? 0
            }
        }

        func maxContentWidth() -> Double {
            measurements.value(\.maxContentWidth) {
                let layout = TextLayout(text: text, style: style)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                return lines.map { layout.lineWidth(String($0)) }.max() ?? 0
            }
        }

        func height(forWidth width: Double) -> Double {
            measurements.height(forWidth: width) {
                TextLayout(text: text, style: style).height(forWidth: width)
            }
        }

        func firstBaseline(forWidth width: Double) -> Double? {
            guard !text.isEmpty else { return nil }

            return measurements.value(\.ascent) {
                Double(CTFontGetAscent(TextLayout.font(for: style)))
            }
        }
    }

    /// The sizes one text in one style measured at — shared by the measurers of a node's
    /// layouts, which may run on the solver's thread while the main thread prepares the next.
    final class TextMeasurements: Sendable {
        struct Values: Sendable {
            var minContentWidth: Double?
            var maxContentWidth: Double?
            var ascent: Double?
            var heights: [Double: Double] = [:]
        }

        /// Widths a height is kept for; a window resized by dragging asks for a new one on
        /// every frame.
        private static let keptHeights = 32

        private let values = OSAllocatedUnfairLock(initialState: Values())

        /// The value at `key`, measured by `measure` the first time.
        func value(
            _ key: WritableKeyPath<Values, Double?> & Sendable,
            measure: () -> Double
        ) -> Double {
            if let known = values.withLock({ $0[keyPath: key] }) { return known }

            let measured = measure()
            values.withLock { $0[keyPath: key] = measured }
            return measured
        }

        func height(forWidth width: Double, measure: () -> Double) -> Double {
            if let known = values.withLock({ $0.heights[width] }) { return known }

            let measured = measure()
            values.withLock { values in
                if values.heights.count >= TextMeasurements.keptHeights {
                    values.heights = [:]
                }
                values.heights[width] = measured
            }
            return measured
        }
    }

    /// Text set in one font and paragraph style — the single place that builds the attributed
    /// string, for measuring and for drawing alike.
    struct TextLayout {
        let string: CFAttributedString
        let font: CTFont
        let maxLines: Int?
        private let attributes: CFDictionary

        /// `rightToLeft` is the layout's direction; it moves `leading` text to the right edge.
        /// Alignment does not change where lines break, so measuring leaves it out.
        init(text: String, style: TextStyle, rightToLeft: Bool = false) {
            font = TextLayout.font(for: style)
            maxLines = style.maxLines.map { max(1, $0) }

            let alignment: CTTextAlignment =
                switch style.alignment {
                case .leading: rightToLeft ? .right : .natural
                case .center: .center
                case .right: .right
                }
            let spacing = CGFloat(max(0, style.lineSpacing))
            let paragraph = withUnsafeBytes(of: alignment) { alignmentBytes in
                withUnsafeBytes(of: spacing) { spacingBytes in
                    var settings = [
                        CTParagraphStyleSetting(
                            spec: .alignment,
                            valueSize: MemoryLayout<CTTextAlignment>.size,
                            value: alignmentBytes.baseAddress!
                        ),
                        CTParagraphStyleSetting(
                            spec: .lineSpacingAdjustment,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: spacingBytes.baseAddress!
                        ),
                    ]
                    let count = settings.count
                    return CTParagraphStyleCreate(&settings, count)
                }
            }
            let color = CGColor(
                red: CGFloat((style.color ?? .black).red),
                green: CGFloat((style.color ?? .black).green),
                blue: CGFloat((style.color ?? .black).blue),
                alpha: CGFloat((style.color ?? .black).alpha)
            )
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
                kCTParagraphStyleAttributeName: paragraph,
            ]
            let dictionary = attributes as CFDictionary
            self.attributes = dictionary
            string = CFAttributedStringCreate(nil, text as CFString, dictionary)
        }

        /// Fonts made for styles on one thread: making one — a weight above all, matched by a
        /// descriptor — costs more than setting a line in it. Each thread keeps its own, so no
        /// font crosses threads.
        private final class FontCache {
            var fonts: [FontKey: CTFont] = [:]
        }

        private struct FontKey: Hashable {
            let name: String?
            let size: Double
            let weight: TextStyle.Weight
        }

        private static let fontCacheKey = "TextLayout.fonts"

        /// The named font, or the system font in the style's weight.
        static func font(for style: TextStyle) -> CTFont {
            let storage = Thread.current.threadDictionary
            let cache: FontCache
            if let existing = storage[fontCacheKey] as? FontCache {
                cache = existing
            } else {
                cache = FontCache()
                storage[fontCacheKey] = cache
            }
            let key = FontKey(name: style.fontName, size: style.size, weight: style.weight)
            if let font = cache.fonts[key] { return font }

            let font = makeFont(for: style)
            cache.fonts[key] = font
            return font
        }

        private static func makeFont(for style: TextStyle) -> CTFont {
            let size = CGFloat(style.size)
            if let name = style.fontName {
                return CTFontCreateWithName(name as CFString, size, nil)
            }

            let system =
                CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            guard style.weight != .regular else { return system }

            // The same family, matched by weight.
            let traits: [CFString: Any] = [kCTFontWeightTrait: style.weight.trait]
            let attributes: [CFString: Any] = [
                kCTFontFamilyNameAttribute: CTFontCopyFamilyName(system),
                kCTFontTraitsAttribute: traits,
            ]
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }

        var ascent: Double { Double(CTFontGetAscent(font)) }

        /// Width of `line` set on one line, rounded up so that the text laid out at this
        /// width does not wrap.
        func lineWidth(_ line: String) -> Double {
            let single = CFAttributedStringCreate(nil, line as CFString, attributes)
            let ctLine = CTLineCreateWithAttributedString(single!)
            return ceil(Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        }

        func height(forWidth width: Double) -> Double {
            let set = lines(forWidth: width)
            return ceil(Double(set.height))
        }

        func draw(in context: CGContext, size: CGSize) {
            let set = lines(forWidth: Double(size.width))
            context.textMatrix = .identity
            // Origins are in a box `set.boxHeight` tall; this one is `size.height` tall.
            let shift = set.boxHeight - size.height
            for index in set.lines.indices {
                var line = set.lines[index]
                if index == set.lines.count - 1, set.isTruncated {
                    line = truncated(from: line, width: size.width)
                }
                context.textPosition = CGPoint(
                    x: set.origins[index].x,
                    y: set.origins[index].y - shift
                )
                CTLineDraw(line, context)
            }
        }

        /// The lines of the text wrapped at `width`, at most `maxLines` of them, with their
        /// origins in a box `boxHeight` tall, and the height they take from its top.
        private func lines(forWidth width: Double) -> (
            lines: [CTLine], origins: [CGPoint], boxHeight: CGFloat, height: CGFloat,
            isTruncated: Bool
        ) {
            let boxHeight: CGFloat = 1_000_000
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(
                rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: boxHeight),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            var all = CTFrameGetLines(frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: all.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

            var isTruncated = false
            if let maxLines, all.count > maxLines {
                all = Array(all.prefix(maxLines))
                origins = Array(origins.prefix(maxLines))
                isTruncated = true
            }
            guard let last = all.last, let lastOrigin = origins.last else {
                return ([], [], boxHeight, 0, false)
            }

            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(last, nil, &descent, &leading)
            let height = boxHeight - (lastOrigin.y - descent - leading)
            return (all, origins, boxHeight, height, isTruncated)
        }

        /// The rest of the text from the start of `line`, cut to `width` with "…" at the end.
        private func truncated(from line: CTLine, width: CGFloat) -> CTLine {
            let start = CTLineGetStringRange(line).location
            let rest = CFAttributedStringCreateWithSubstring(
                nil,
                string,
                CFRange(location: start, length: CFAttributedStringGetLength(string) - start)
            )
            let restLine = CTLineCreateWithAttributedString(rest!)
            let ellipsis = CFAttributedStringCreate(nil, "\u{2026}" as CFString, attributes)
            let token = CTLineCreateWithAttributedString(ellipsis!)
            return CTLineCreateTruncatedLine(restLine, Double(width), .end, token) ?? line
        }
    }
#endif
