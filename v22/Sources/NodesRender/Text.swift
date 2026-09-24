#if canImport(CoreText)
    import CoreText
    import Foundation
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
            /// At the start of the writing direction.
            case leading
            case center
            /// At the right edge. (Right-to-left text: the same, for now.)
            case right
        }

        /// A font by its PostScript name; `nil` for the system font.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var fontName: String?
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var size: Double = 17
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var color: Color = .black
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public var alignment: Alignment = .leading

        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public init(fontName: String? = nil, size: Double = 17, color: Color = .black) {
            self.fontName = fontName
            self.size = size
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

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public private(set) var drawingRevision: UInt64 = 0

        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init(_ text: String = "", style: TextStyle = TextStyle()) {
            self.text = text
            self.style = style
            super.init()
        }

        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: none.
        public override var layoutContent: LeafContent? {
            .measured(TextMeasurer(text: text, style: style))
        }

        /// Ownership: draws into `context`. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func draw(in context: CGContext, size: CGSize) {
            TextLayout(text: text, style: style).draw(in: context, size: size)
        }

        private func contentChanged() {
            drawingRevision &+= 1
            setNeedsLayout()
        }
    }

    /// Measures text for the layout engine. It keeps only values, so it can measure on any
    /// thread; fonts and strings are built for each measurement by `TextLayout`, the same
    /// code that draws, so what is measured is what is drawn.
    struct TextMeasurer: ContentMeasurer {
        let text: String
        let style: TextStyle

        func minContentWidth() -> Double {
            let layout = TextLayout(text: text, style: style)
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            return words.map { layout.lineWidth(String($0)) }.max() ?? 0
        }

        func maxContentWidth() -> Double {
            let layout = TextLayout(text: text, style: style)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.map { layout.lineWidth(String($0)) }.max() ?? 0
        }

        func height(forWidth width: Double) -> Double {
            TextLayout(text: text, style: style).height(forWidth: width)
        }

        func firstBaseline(forWidth width: Double) -> Double? {
            text.isEmpty ? nil : TextLayout(text: text, style: style).ascent
        }
    }

    /// Text set in one font and paragraph style — the single place that builds the attributed
    /// string, for measuring and for drawing alike.
    struct TextLayout {
        let string: CFAttributedString
        let font: CTFont
        private let attributes: CFDictionary

        init(text: String, style: TextStyle) {
            let size = CGFloat(style.size)
            font =
                style.fontName.map { CTFontCreateWithName($0 as CFString, size, nil) }
                ?? CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)

            var alignment: CTTextAlignment =
                switch style.alignment {
                case .leading: .natural
                case .center: .center
                case .right: .right
                }
            let paragraph = withUnsafeMutableBytes(of: &alignment) { bytes in
                var setting = CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: bytes.baseAddress!
                )
                return CTParagraphStyleCreate(&setting, 1)
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

        var ascent: Double { Double(CTFontGetAscent(font)) }

        /// Width of `line` set on one line, rounded up so that the text laid out at this
        /// width does not wrap.
        func lineWidth(_ line: String) -> Double {
            let single = CFAttributedStringCreate(nil, line as CFString, attributes)
            let ctLine = CTLineCreateWithAttributedString(single!)
            return ceil(Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        }

        func height(forWidth width: Double) -> Double {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: 0),
                nil,
                CGSize(width: CGFloat(width), height: .greatestFiniteMagnitude),
                nil
            )
            return ceil(Double(size.height))
        }

        func draw(in context: CGContext, size: CGSize) {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
        }
    }
#endif
