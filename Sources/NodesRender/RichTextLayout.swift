#if canImport(CoreText)
    import CoreGraphics
    import CoreText
    import Foundation
    import RichTextCore
    import ThemeCore
    import os

    /// The sizes of a rich text's blocks that follow from the size of the text: spacing between
    /// blocks, the bar of a quote, the padding of code. Measuring and drawing both take them from
    /// here.
    struct RichMetrics: Sendable, Hashable {
        let fontName: String?
        let size: Double
        let weight: TextStyle.Weight
        let lineSpacing: Double
        let alignment: TextStyle.Alignment
        let rightToLeft: Bool

        init(_ style: TextStyle, rightToLeft: Bool = false) {
            fontName = style.fontName
            size = style.size
            weight = style.weight
            lineSpacing = style.lineSpacing
            alignment = style.alignment
            self.rightToLeft = rightToLeft
        }

        /// The part of the metrics that decides where lines break: what the cache of sizes is
        /// keyed by. Alignment and direction only move lines, so they are left out.
        var breaking: RichMetrics {
            RichMetrics(
                fontName: fontName,
                size: size,
                weight: weight,
                lineSpacing: lineSpacing,
                alignment: .leading,
                rightToLeft: false
            )
        }

        private init(
            fontName: String?,
            size: Double,
            weight: TextStyle.Weight,
            lineSpacing: Double,
            alignment: TextStyle.Alignment,
            rightToLeft: Bool
        ) {
            self.fontName = fontName
            self.size = size
            self.weight = weight
            self.lineSpacing = lineSpacing
            self.alignment = alignment
            self.rightToLeft = rightToLeft
        }

        var textStyle: TextStyle {
            var style = TextStyle(fontName: fontName, size: size, weight: weight)
            style.lineSpacing = lineSpacing
            return style
        }

        /// The space between one block and the next.
        var blockSpacing: Double { (size * 0.6).rounded() }
        var quoteBarWidth: Double { 3 }
        var quoteGap: Double { (size * 0.6).rounded() }
        var codePadding: Double { (size * 0.5).rounded() }
        /// Code is set a little smaller than the text around it, as a monospaced font looks larger.
        var codeSize: Double { (size * 0.9 * 2).rounded() / 2 }
    }

    /// The colors a rich text is drawn in. They are part of the attributed string, so a block's
    /// layout for one set is not used for another; sizes do not depend on them.
    struct RichColors: Sendable, Hashable {
        var text: Color
        var link: Color
        /// The quote's bar.
        var bar: Color

        static let measuring = RichColors(
            text: Color(red: 0, green: 0, blue: 0),
            link: Color(red: 0, green: 0, blue: 0),
            bar: Color(red: 0, green: 0, blue: 0)
        )
    }

    /// The numbers of a block laid out at one width, without anything that draws: what the
    /// engine needs to measure, kept across layouts by the node's cache.
    struct BlockGeometry: Sendable {
        var insets: Insets
        /// Where each line ends, from the top of the block's text.
        var lineBottoms: [Double]
        /// How tall the text of an empty block is: one line of its font.
        var emptyHeight: Double
        /// From the top of the text to the first baseline.
        var firstBaseline: Double

        struct Insets: Sendable, Hashable {
            var left = 0.0
            var top = 0.0
            var right = 0.0
            var bottom = 0.0
        }

        /// The height of the block when `lines` of its lines show (all when `nil`), with its
        /// insets. A block with no lines is one line high.
        func height(showing lines: Int?) -> Double {
            let count = min(lines ?? lineBottoms.count, lineBottoms.count)
            let text = count == 0 ? emptyHeight : ceil(lineBottoms[count - 1])
            return insets.top + text + insets.bottom
        }
    }

    /// One block of a rich text laid out at one width: its geometry, and the lines and marks
    /// that draw and answer where a point falls. Measuring, drawing and finding a link at a
    /// point all read one of these, so they cannot disagree.
    struct RichBlockLayout {
        struct Line {
            let line: CTLine
            /// Where the line starts, from the left of the block's text.
            let x: Double
            /// From the top of the block's text.
            let baseline: Double
            let ascent: Double
            let descent: Double
            let range: CFRange
        }

        enum Decoration {
            case underline
            case strike
            /// Behind monospaced text inside a line.
            case background
            /// The place a tap opens a link from; the whole height of the line.
            case link(URL)
        }

        struct Mark {
            /// In the block's coordinates, from its top left corner, y down.
            let rect: CGRect
            let decoration: Decoration
        }

        let block: RichText.Block
        let geometry: BlockGeometry
        let lines: [Line]
        let marks: [Mark]
        let string: CFAttributedString
        /// The text's width; a line is cut to it with "…" when the block is cut.
        let textWidth: Double

        // MARK: Building

        /// The fonts one block is set in, made once per layout.
        private final class Fonts {
            let metrics: RichMetrics
            let base: CTFont
            private var made: [UInt8: CTFont] = [:]

            init(_ metrics: RichMetrics) {
                self.metrics = metrics
                base = TextLayout.font(for: metrics.textStyle)
            }

            var mono: CTFont { font(for: .mono) }

            func font(for marks: Marks) -> CTFont {
                if let known = made[marks.rawValue] { return known }

                var font = base
                if marks.contains(.mono) {
                    let size = CGFloat(metrics.codeSize)
                    font =
                        CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
                        ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
                }
                var traits: CTFontSymbolicTraits = []
                if marks.contains(.bold) { traits.insert(.traitBold) }
                if marks.contains(.italic) { traits.insert(.traitItalic) }
                if !traits.isEmpty,
                    let styled = CTFontCreateCopyWithSymbolicTraits(
                        font,
                        CTFontGetSize(font),
                        nil,
                        traits,
                        traits
                    )
                {
                    font = styled
                }
                made[marks.rawValue] = font
                return font
            }
        }

        private static func cgColor(_ color: Color) -> CGColor {
            CGColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
        }

        /// The insets of a kind of block and the width left for its text.
        static func insets(of block: RichText.Block, _ metrics: RichMetrics) -> BlockGeometry.Insets
        {
            switch block {
            case .paragraph: BlockGeometry.Insets()
            case .quote:
                BlockGeometry.Insets(left: metrics.quoteBarWidth + metrics.quoteGap)
            case .code:
                BlockGeometry.Insets(
                    left: metrics.codePadding,
                    top: metrics.codePadding,
                    right: metrics.codePadding,
                    bottom: metrics.codePadding
                )
            }
        }

        /// The attributed string of a block and the range each of its runs takes in it, in UTF-16
        /// units, as Core Text counts. A link is text in the link's color; the rest of what a
        /// mark asks for is drawn from the marks.
        private static func attributed(
            _ block: RichText.Block,
            fonts: Fonts,
            colors: RichColors
        ) -> (CFAttributedString, [(CFRange, Run)]) {
            let metrics = fonts.metrics
            let alignment: CTTextAlignment =
                switch metrics.alignment {
                case .leading: metrics.rightToLeft ? .right : .natural
                case .center: .center
                case .right: .right
                }
            var lineBreak = CTLineBreakMode.byWordWrapping
            if case .code = block { lineBreak = .byCharWrapping }
            let spacing = CGFloat(max(0, metrics.lineSpacing))
            let paragraph = withUnsafeBytes(of: alignment) { alignmentBytes in
                withUnsafeBytes(of: spacing) { spacingBytes in
                    withUnsafeBytes(of: lineBreak) { breakBytes in
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
                            CTParagraphStyleSetting(
                                spec: .lineBreakMode,
                                valueSize: MemoryLayout<CTLineBreakMode>.size,
                                value: breakBytes.baseAddress!
                            ),
                        ]
                        let count = settings.count
                        return CTParagraphStyleCreate(&settings, count)
                    }
                }
            }

            let string = CFAttributedStringCreateMutable(nil, 0)!
            var placed: [(CFRange, Run)] = []
            var runs: [Run]
            switch block {
            case .paragraph(let value), .quote(let value): runs = value
            case .code(let text, _): runs = [Run(text, marks: .mono)]
            }
            for run in runs {
                let start = CFAttributedStringGetLength(string)
                CFAttributedStringReplaceString(
                    string,
                    CFRange(location: start, length: 0),
                    run.text as CFString
                )
                let range = CFRange(location: start, length: run.text.utf16.count)
                let color = run.link == nil ? colors.text : colors.link
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: fonts.font(for: run.marks),
                    kCTForegroundColorAttributeName: cgColor(color),
                    kCTParagraphStyleAttributeName: paragraph,
                ]
                CFAttributedStringSetAttributes(string, range, attributes as CFDictionary, false)
                placed.append((range, run))
            }
            return (string, placed)
        }

        /// Lays `block` out with its text `width` wide inside its insets. `colors` only color the
        /// text; everything else is the same whatever they are.
        init(_ block: RichText.Block, width: Double, metrics: RichMetrics, colors: RichColors) {
            let fonts = Fonts(metrics)
            let insets = RichBlockLayout.insets(of: block, metrics)
            let textWidth = max(1, width - insets.left - insets.right)
            let (string, placed) = RichBlockLayout.attributed(block, fonts: fonts, colors: colors)

            let boxHeight: CGFloat = 1_000_000
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                CGPath(
                    rect: CGRect(x: 0, y: 0, width: CGFloat(textWidth), height: boxHeight),
                    transform: nil
                ),
                nil
            )
            let ctLines = CTFrameGetLines(frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: ctLines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

            var lines: [Line] = []
            var bottoms: [Double] = []
            for (index, line) in ctLines.enumerated() {
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let baseline = Double(boxHeight - origins[index].y)
                lines.append(
                    Line(
                        line: line,
                        x: Double(origins[index].x),
                        baseline: baseline,
                        ascent: Double(ascent),
                        descent: Double(descent),
                        range: CTLineGetStringRange(line)
                    )
                )
                bottoms.append(baseline + Double(descent) + Double(leading))
            }

            let isCode: Bool
            if case .code = block { isCode = true } else { isCode = false }
            let font = isCode ? fonts.mono : fonts.base
            let emptyHeight = Double(
                CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
            )
            let firstBaseline = lines.first?.baseline ?? Double(CTFontGetAscent(font))

            self.block = block
            self.textWidth = textWidth
            self.string = string
            self.lines = lines
            geometry = BlockGeometry(
                insets: insets,
                lineBottoms: bottoms,
                emptyHeight: emptyHeight,
                firstBaseline: firstBaseline + insets.top
            )
            marks = RichBlockLayout.marks(
                lines: lines,
                placed: placed,
                xHeight: Double(CTFontGetXHeight(fonts.base)),
                size: metrics.size,
                inCode: isCode
            )
        }

        /// The rectangles of underlines, strikethroughs, monospaced backgrounds and links: one
        /// per line a marked run reaches.
        private static func marks(
            lines: [Line],
            placed: [(CFRange, Run)],
            xHeight: Double,
            size: Double,
            inCode: Bool
        ) -> [Mark] {
            var marks: [Mark] = []
            let thickness = max(1, (size / 16).rounded())
            for (range, run) in placed
            where run.link != nil || !run.marks.isDisjoint(with: [.underline, .strike, .mono]) {
                for line in lines {
                    let start = max(range.location, line.range.location)
                    let end = min(
                        range.location + range.length,
                        line.range.location + line.range.length
                    )
                    guard start < end else { continue }

                    let from = line.x + Double(CTLineGetOffsetForStringIndex(line.line, start, nil))
                    let to = line.x + Double(CTLineGetOffsetForStringIndex(line.line, end, nil))
                    guard to > from else { continue }

                    let box = CGRect(
                        x: from,
                        y: line.baseline - line.ascent,
                        width: to - from,
                        height: line.ascent + line.descent
                    )
                    if run.marks.contains(.mono), !inCode {
                        marks.append(Mark(rect: box, decoration: .background))
                    }
                    if run.marks.contains(.underline) || run.link != nil {
                        let y = line.baseline + max(1, line.descent * 0.35)
                        marks.append(
                            Mark(
                                rect: CGRect(x: from, y: y, width: to - from, height: thickness),
                                decoration: .underline
                            )
                        )
                    }
                    if run.marks.contains(.strike) {
                        let y = line.baseline - xHeight * 0.5 - thickness / 2
                        marks.append(
                            Mark(
                                rect: CGRect(x: from, y: y, width: to - from, height: thickness),
                                decoration: .strike
                            )
                        )
                    }
                    if let link = run.link {
                        marks.append(Mark(rect: box, decoration: .link(link)))
                    }
                }
            }
            return marks
        }

        // MARK: Widths

        /// The width the block takes on one line per line break of its own, and the width of its
        /// longest word, each with the insets. They do not depend on the width offered.
        static func intrinsicWidths(_ block: RichText.Block, metrics: RichMetrics) -> (
            min: Double, max: Double
        ) {
            let fonts = Fonts(metrics)
            let insets = insets(of: block, metrics)
            let (string, _) = attributed(block, fonts: fonts, colors: .measuring)
            let text = block.text
            let length = CFAttributedStringGetLength(string)
            guard length > 0 else {
                return (insets.left + insets.right, insets.left + insets.right)
            }

            func width(of range: CFRange) -> Double {
                let piece = CFAttributedStringCreateWithSubstring(nil, string, range)!
                let line = CTLineCreateWithAttributedString(piece)
                return ceil(Double(CTLineGetTypographicBounds(line, nil, nil, nil)))
            }

            // Positions of the breaks in UTF-16 units: a line break ends a line, a space ends a word.
            var widest = 0.0
            var longestWord = 0.0
            var lineStart = 0
            var wordStart = 0
            var offset = 0
            let isCode: Bool
            if case .code = block { isCode = true } else { isCode = false }
            for character in text {
                let next = offset + character.utf16.count
                if character == "\n" {
                    widest = max(
                        widest,
                        width(of: CFRange(location: lineStart, length: offset - lineStart))
                    )
                    lineStart = next
                }
                if character.isWhitespace || character.isNewline {
                    if offset > wordStart {
                        longestWord = max(
                            longestWord,
                            width(of: CFRange(location: wordStart, length: offset - wordStart))
                        )
                    }
                    wordStart = next
                } else if isCode {
                    // Code breaks between any two characters: the narrowest it can be is one.
                    longestWord = max(
                        longestWord,
                        width(of: CFRange(location: offset, length: character.utf16.count))
                    )
                }
                offset = next
            }
            if length > lineStart {
                widest = max(
                    widest,
                    width(of: CFRange(location: lineStart, length: length - lineStart))
                )
            }
            if !isCode, length > wordStart {
                longestWord = max(
                    longestWord,
                    width(of: CFRange(location: wordStart, length: length - wordStart))
                )
            }
            let sides = insets.left + insets.right
            return (longestWord + sides, widest + sides)
        }
    }

    /// What a rich text's blocks measured at, kept by the node across layouts and edits. Keys
    /// hold the content, so a block that an edit did not touch is measured once; the entries may
    /// be made on the solver's thread while the main thread draws.
    final class RichTextMeasurements: Sendable {
        private struct GeometryKey: Hashable {
            let block: RichText.Block
            let width: Double
            let metrics: RichMetrics
        }

        private struct WidthKey: Hashable {
            let block: RichText.Block
            let metrics: RichMetrics
        }

        private struct Stored {
            var geometry: [GeometryKey: BlockGeometry] = [:]
            var widths: [WidthKey: (min: Double, max: Double)] = [:]
        }

        /// Entries kept before the oldest go: a window resized by dragging asks for a new width
        /// on every frame.
        private static let kept = 512

        private let stored = OSAllocatedUnfairLock(initialState: Stored())

        func geometry(_ block: RichText.Block, width: Double, metrics: RichMetrics) -> BlockGeometry
        {
            let key = GeometryKey(block: block, width: width, metrics: metrics.breaking)
            if let known = stored.withLock({ $0.geometry[key] }) { return known }

            let made = RichBlockLayout(
                block,
                width: width,
                metrics: metrics.breaking,
                colors: .measuring
            )
            .geometry
            stored.withLock { stored in
                if stored.geometry.count >= RichTextMeasurements.kept { stored.geometry = [:] }
                stored.geometry[key] = made
            }
            return made
        }

        func widths(_ block: RichText.Block, metrics: RichMetrics) -> (min: Double, max: Double) {
            let key = WidthKey(block: block, metrics: metrics.breaking)
            if let known = stored.withLock({ $0.widths[key] }) { return known }

            let made = RichBlockLayout.intrinsicWidths(block, metrics: metrics.breaking)
            stored.withLock { stored in
                if stored.widths.count >= RichTextMeasurements.kept { stored.widths = [:] }
                stored.widths[key] = made
            }
            return made
        }
    }

    /// Where the blocks of a rich text go, from the geometry of each: the same numbers measure
    /// the text and place what is drawn.
    struct RichStack {
        /// The top of each block, from the top of the text.
        var tops: [Double]
        /// How many lines of each block show; `nil` for all of them. Fewer when the text is cut
        /// to `maxLines`; then blocks after the last shown one have none.
        var shown: [Int?]
        var height: Double

        init(_ geometries: [BlockGeometry], spacing: Double, maxLines: Int?) {
            var tops: [Double] = []
            var shown: [Int?] = []
            var remaining = maxLines
            var y = 0.0
            for (index, geometry) in geometries.enumerated() {
                if let left = remaining, left <= 0 { break }

                var lines: Int?
                if let left = remaining {
                    if geometry.lineBottoms.count > left { lines = left }
                    remaining = left - max(1, min(geometry.lineBottoms.count, left))
                }
                if index > 0 { y += spacing }
                tops.append(y)
                shown.append(lines)
                y += geometry.height(showing: lines)
            }
            self.tops = tops
            self.shown = shown
            height = y
        }
    }
#endif
