#if canImport(CoreText)
    import CoreText
    import Foundation
    import os
    import LayoutCore
    import Nodes
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
        public enum Weight: Sendable, Hashable {
            case regular
            case medium
            case semibold
            case bold

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
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var color: Color = .black
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

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(
            fontName: String? = nil,
            size: Double = 17,
            weight: Weight = .regular,
            color: Color = .black
        ) {
            self.fontName = fontName
            self.size = size
            self.weight = weight
            self.color = color
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

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var style: TextStyle {
            didSet { if style != oldValue { contentChanged() } }
        }

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

        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(_ text: String = "", style: TextStyle = TextStyle()) {
            self.text = text
            self.style = style
            super.init()
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var layoutContent: LeafContent? {
            .measured(TextMeasurer(text: text, style: style, measurements: measurements))
        }

        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func draw(in context: CGContext, size: CGSize) {
            TextLayout(text: text, style: style, rightToLeft: isRightToLeft)
                .draw(in: context, size: size)
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var accessibilityContentLabel: String? { text }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var accessibilityContentTraits: AccessibilityTraits { .staticText }

        private func contentChanged() {
            revision &+= 1
            measurements = TextMeasurements()
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
                red: CGFloat(style.color.red),
                green: CGFloat(style.color.green),
                blue: CGFloat(style.color.blue),
                alpha: CGFloat(style.color.alpha)
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
