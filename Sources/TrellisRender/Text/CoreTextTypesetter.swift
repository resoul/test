import CoreGraphics
import CoreText
import Foundation
import TrellisCore

/// Failure creating the backing `CGContext`/`CGImage` for a raster pass — a platform-level
/// allocation failure, not a content or cancellation error.
///
/// Ownership: the value is copied. Isolation: none. Errors: represents this failure only.
/// Cancellation: not applicable.
enum DisplayRasterError: Error, Sendable {
    case contextUnavailable
    case imageUnavailable
}

// Shared line-breaking pass behind `CoreTextRenderer.measure` — kept as one internal entry point
// so T06's rasterizer can call the same wrapping/truncation decision instead of re-deriving it
// (the plan's "единая логика line breaks... для measure и raster", closing the class of defect
// #37 where Weave's draw path truncated differently than its measure path).
enum CoreTextTypesetter {
    /// A width large enough that CoreText never wraps against it — used for `.unspecified`,
    /// mirroring how `CTFramesetterSuggestFrameSizeWithConstraints` is normally driven with a
    /// generous-but-finite bound rather than `.greatestFiniteMagnitude` (which some CoreText
    /// versions do not handle well inside a `CGPath` rect).
    private static let unboundedWidth: CGFloat = 1_000_000

    private static let weightTraitValues: [TextWeight: CGFloat] = [
        .ultraLight: -0.8,
        .thin: -0.6,
        .light: -0.4,
        .regular: 0,
        .medium: 0.23,
        .semibold: 0.3,
        .bold: 0.4,
        .heavy: 0.56,
        .black: 0.62,
    ]

    static func measure(
        input: TextLayoutInput,
        constraint: SizeConstraint,
        context: LayoutContext
    ) throws -> TextMetrics {
        let widthConstraint = resolvedWidthConstraint(constraint.width)

        guard !input.document.plainCharacters.isEmpty else {
            return emptyMetrics(input: input, constraint: constraint)
        }

        let attributed = try makeAttributedString(input: input, resolvedColor: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: widthConstraint, height: .greatestFiniteMagnitude),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else {
            return emptyMetrics(input: input, constraint: constraint)
        }

        var ascents = [CGFloat](repeating: 0, count: lines.count)
        var lineHeights = [Double](repeating: 0, count: lines.count)
        var lineWidths = [Double](repeating: 0, count: lines.count)
        for (index, line) in lines.enumerated() {
            if index % 8 == 0 { try context.checkCancellation() }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            ascents[index] = ascent
            lineHeights[index] =
                input.style.lineHeight > 0
                ? input.style.lineHeight : Double(ascent + descent + leading)
            lineWidths[index] = Double(width)
        }

        var visibleLineCount = lines.count
        var didTruncate = false

        if let maxLines = input.maxLines, maxLines < visibleLineCount {
            visibleLineCount = max(1, maxLines)
            didTruncate = true
        }

        if let maxHeight = constraint.height.knownValue {
            var cumulative: Double = 0
            var heightLimitedCount = 0
            for height in lineHeights {
                let next = cumulative + height
                if heightLimitedCount > 0 && next > maxHeight { break }
                cumulative = next
                heightLimitedCount += 1
            }
            heightLimitedCount = max(1, heightLimitedCount)
            if heightLimitedCount < visibleLineCount {
                visibleLineCount = heightLimitedCount
                didTruncate = true
            }
        }

        let visibleWidth = lineWidths[0..<visibleLineCount].max() ?? 0

        let reportedWidth: Double
        switch constraint.width {
        case .exact(let bound): reportedWidth = bound
        case .atMost, .unspecified: reportedWidth = visibleWidth
        }
        // `truncation` (`clip` vs `tail`) changes what a rasterizer (T06) draws on the last
        // visible line, never the measured box: D56 only ties `didTruncate` to whether content
        // was cut, not to how the cut is drawn.
        _ = input.truncation

        let height = lineHeights[0..<visibleLineCount].reduce(0, +)
        return TextMetrics(
            size: MeasuredSize(width: reportedWidth, height: height),
            firstBaseline: Double(ascents[0]),
            lineCount: visibleLineCount,
            didTruncate: didTruncate
        )
    }

    /// Rasterizes `request` into a bitmap sized exactly to `request.size` — the box the solver
    /// already settled on, not a constraint to measure against. Builds the frame bounded by
    /// that exact box (unlike `measure`'s unbounded natural-height probe) so CoreText itself
    /// decides how many lines fit; `input.maxLines` is applied on top when it cuts sooner than
    /// the box does. When more text remains past what is drawn and `truncation == .tail`, the
    /// last visible line is replaced with a real width-measured ellipsis line
    /// (`CTLineCreateTruncatedLine`), finally closing defect #37 on the draw side (T05 closed
    /// its measurement half only).
    static func rasterize(
        request: TextDisplayRequest,
        context: LayoutContext
    ) throws -> DisplayArtifact {
        try context.checkCancellation()
        let scale = request.scale
        let pixelWidth = max(1, Int((request.size.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((request.size.height * scale).rounded(.up)))

        guard request.size.width > 0, request.size.height > 0,
            !request.input.document.plainCharacters.isEmpty
        else {
            return DisplayArtifact(
                image: try emptyImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: scale
            )
        }

        let attributed = try makeAttributedString(
            input: request.input,
            resolvedColor: request.resolvedColor
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Defect #47/#50: `CTFrameGetLines`'s own height-based line-fitting inside
        // `CTFramesetterCreateFrame` is not a reliable way to ask "how many lines does
        // `measure()`'s own box hold" — a box exactly `request.size.height` tall (the sum of
        // `measure()`'s own per-line heights for the visible line count) sometimes fits *fewer*
        // lines than that sum actually accounts for (defect #47: at some point sizes a
        // single-line box came back with zero lines at all; defect #50, found building the
        // Playground S27 disclosure scene: a `maxLines: 2` box exactly two line-heights tall came
        // back with only one, silently dropping the second real line behind an ellipsis one line
        // early). A flat fitting margin (#47's original fix) only ever closes the single-line gap
        // — there is no fixed margin is guaranteed enough for every line count, so probing and
        // drawing are now two different frames instead of patching one shared box height again:
        //
        // `probeFrame` is unbounded in height (safe here — unlike `unboundedWidth`'s comment
        // about *width*, `measure()` already relies on `.greatestFiniteMagnitude` height on this
        // SDK) — it reports every natural line with no height-driven cutoff, used only for line
        // content/ranges/typographic bounds and the truncation decision below, never for pixel
        // positions (a frame this tall places line origins astronomically far from the small
        // bitmap's own coordinate space — the numeric reason positions cannot come from it).
        let probePath = CGPath(
            rect: CGRect(x: 0, y: 0, width: request.size.width, height: .greatestFiniteMagnitude),
            transform: nil
        )
        let probeFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            probePath,
            nil
        )
        guard var lines = CTFrameGetLines(probeFrame) as? [CTLine], !lines.isEmpty else {
            return DisplayArtifact(
                image: try emptyImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: scale
            )
        }

        var visibleCount = lines.count
        if let maxLines = request.input.maxLines, maxLines < visibleCount {
            visibleCount = max(1, maxLines)
        }
        visibleCount = min(
            visibleCount,
            heightLimitedLineCount(
                lines,
                upTo: visibleCount,
                maxHeight: request.size.height,
                style: request.input.style
            )
        )
        try context.checkCancellation()

        let lastRange = CTLineGetStringRange(lines[visibleCount - 1])
        let hasMoreText = (lastRange.location + lastRange.length) < attributed.length

        if hasMoreText, request.input.truncation == .tail {
            let font = makeFont(
                style: request.input.style,
                localeIdentifier: request.input.localeIdentifier
            )
            lines[visibleCount - 1] = truncatedLastLine(
                attributed: attributed,
                lastLine: lines[visibleCount - 1],
                width: CGFloat(request.size.width),
                font: font
            )
        }

        // `fittingFrame`: same width (so wrapping and each line's alignment offset match
        // `probeFrame` exactly — word breaks are width-driven, never height-driven), but a
        // finite, generously-tall box so `CTFrameGetLines` reliably returns at least
        // `visibleCount` lines with real, numerically-usable origins (unlike `probeFrame`'s
        // unbounded one). Its own line *count* is never trusted — only `probeFrame`'s is — this
        // frame exists purely to ask CoreText where a top-aligned line at a given index would
        // land, then that Y is shifted back into `request.size.height`'s own small coordinate
        // space (`fittingHeight - request.size.height`), the same box `measure()` promised.
        let fittingHeight = request.size.height + 256
        let fittingPath = CGPath(
            rect: CGRect(x: 0, y: 0, width: request.size.width, height: fittingHeight),
            transform: nil
        )
        let fittingFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            fittingPath,
            nil
        )
        guard let fittingLines = CTFrameGetLines(fittingFrame) as? [CTLine],
            fittingLines.count >= visibleCount
        else {
            return DisplayArtifact(
                image: try emptyImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: scale
            )
        }
        var origins = [CGPoint](repeating: .zero, count: fittingLines.count)
        CTFrameGetLineOrigins(fittingFrame, CFRange(location: 0, length: 0), &origins)
        let yShift = CGFloat(fittingHeight - request.size.height)

        guard
            let cgContext = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw DisplayRasterError.contextUnavailable }
        cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        cgContext.setAllowsAntialiasing(true)

        for index in 0..<visibleCount {
            try context.checkCancellation()
            cgContext.textPosition = CGPoint(x: origins[index].x, y: origins[index].y - yShift)
            CTLineDraw(lines[index], cgContext)
        }

        guard let image = cgContext.makeImage() else { throw DisplayRasterError.imageUnavailable }
        return DisplayArtifact(
            image: image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: scale
        )
    }

    /// Builds the real ellipsis-truncated version of the last visible line: a `CTLine` spanning
    /// from that line's start to the end of the whole document (so `CTLineCreateTruncatedLine`
    /// knows how much content remains to elide), not a character-count guess (the W01/#37
    /// defect this replaces on the draw side).
    private static func truncatedLastLine(
        attributed: NSAttributedString,
        lastLine: CTLine,
        width: CGFloat,
        font: CTFont
    ) -> CTLine {
        let range = CTLineGetStringRange(lastLine)
        let remainderLength = attributed.length - range.location
        guard remainderLength > 0 else { return lastLine }

        let remainder = attributed.attributedSubstring(
            from: NSRange(location: range.location, length: remainderLength)
        )
        let remainderLine = CTLineCreateWithAttributedString(remainder)
        let ellipsis = NSAttributedString(
            string: "\u{2026}",
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let ellipsisLine = CTLineCreateWithAttributedString(ellipsis)
        return CTLineCreateTruncatedLine(remainderLine, Double(width), .end, ellipsisLine)
            ?? lastLine
    }

    /// Mirrors `measure()`'s own cumulative-height limiter (D56's second, independent limiter,
    /// lines 100–114 above): how many of `lines[0..<upTo]` actually fit within `maxHeight`, using
    /// each line's own typographic height (or `style.lineHeight` when set, exactly like
    /// `measure()`). Always at least 1 — an empty visible range is never useful (D56: "пустая
    /// строка — одна строка"), and `request.size.height` here always comes from a `measure()`
    /// result that itself never reports zero visible lines.
    ///
    /// `tolerance` absorbs the case `request.size.height` (`maxHeight`) *is* the sum of these
    /// same lines' own heights, computed by an earlier, separate `measure()` call against a
    /// separate `CTFrame` — `CTLineGetTypographicBounds` on two independently created frames for
    /// the same string is not guaranteed bit-identical, and without slack a cumulative sum that
    /// lands a hair above `maxHeight` purely from that noise would drop the very last line
    /// `measure()` already promised fits (found while fixing defect #50 — this cutoff must only
    /// fire for a real, independently-imposed height constraint, not float noise from redoing
    /// the same arithmetic). One tolerance for the whole cumulative sum, not per-line, is enough:
    /// a genuine tighter height constraint (the D56 case this exists for) misses by much more
    /// than rounding ever could.
    private static func heightLimitedLineCount(
        _ lines: [CTLine],
        upTo: Int,
        maxHeight: Double,
        style: TextStyle,
        tolerance: Double = 0.5
    ) -> Int {
        var cumulative: Double = 0
        var count = 0
        for line in lines[0..<upTo] {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let height =
                style.lineHeight > 0 ? style.lineHeight : Double(ascent + descent + leading)
            let next = cumulative + height
            if count > 0 && next > maxHeight + tolerance { break }
            cumulative = next
            count += 1
        }
        return max(1, count)
    }

    private static func emptyImage(pixelWidth: Int, pixelHeight: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage()
        else { throw DisplayRasterError.contextUnavailable }
        return image
    }

    private static func resolvedWidthConstraint(_ axis: SizeConstraintAxis) -> CGFloat {
        switch axis {
        case .unspecified: return unboundedWidth
        case let .atMost(bound): return CGFloat(bound)
        case let .exact(bound): return CGFloat(bound)
        }
    }

    private static func emptyMetrics(input: TextLayoutInput, constraint: SizeConstraint)
        -> TextMetrics
    {
        let font = makeFont(style: input.style, localeIdentifier: input.localeIdentifier)
        let lineHeight =
            input.style.lineHeight > 0
            ? input.style.lineHeight
            : Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let width: Double
        switch constraint.width {
        case .exact(let bound): width = bound
        case .atMost, .unspecified: width = 0
        }
        return TextMetrics(
            size: MeasuredSize(width: width, height: lineHeight),
            firstBaseline: Double(CTFontGetAscent(font)),
            lineCount: 1,
            didTruncate: false
        )
    }

    /// Builds the `NSAttributedString` `CTFramesetter` measures and draws from — the one place
    /// font/paragraph/language attributes are assembled, shared by `measure` and `rasterize` so
    /// the two can never see a different attributed string for the same `input` (the class of
    /// defect #37: a draw path that diverges from what was measured). `resolvedColor` is `nil`
    /// for a measure-only call (D55: color never affects typographic bounds, so skipping it
    /// avoids a wasted `CGColor` per run) and set for a raster call, where run-level
    /// `trellisText.color` overrides it same as font/size/weight do.
    private static func makeAttributedString(input: TextLayoutInput, resolvedColor: ThemeColor?)
        throws -> NSAttributedString
    {
        let plain = input.document.plainCharacters
        let mutable = NSMutableAttributedString(string: plain)
        let fullRange = NSRange(location: 0, length: mutable.length)

        for run in input.document.runs {
            let nsRange = NSRange(run.range, in: input.document)
            guard nsRange.length > 0 else { continue }
            let runStyle = resolvedRunStyle(base: input.style, run: run)
            let font = makeFont(style: runStyle, localeIdentifier: input.localeIdentifier)
            mutable.addAttribute(
                kCTFontAttributeName as NSAttributedString.Key,
                value: font,
                range: nsRange
            )
            if let resolvedColor {
                let color = run[TextColorAttribute.self] ?? runStyle.color ?? resolvedColor
                mutable.addAttribute(
                    kCTForegroundColorAttributeName as NSAttributedString.Key,
                    value: cgColor(color),
                    range: nsRange
                )
            }
        }
        // Runs never overriding the font still need one — `addAttribute` above only covers
        // ranges seen in `runs`, which already spans the whole document (Foundation always
        // yields at least one run covering everything), so this is a defensive fallback for an
        // attribute-less empty run set rather than an expected path.
        if input.document.runs.isEmpty {
            let font = makeFont(style: input.style, localeIdentifier: input.localeIdentifier)
            mutable.addAttribute(
                kCTFontAttributeName as NSAttributedString.Key,
                value: font,
                range: fullRange
            )
            if let resolvedColor {
                mutable.addAttribute(
                    kCTForegroundColorAttributeName as NSAttributedString.Key,
                    value: cgColor(input.style.color ?? resolvedColor),
                    range: fullRange
                )
            }
        }

        let paragraph = makeParagraphStyle(style: input.style, direction: input.direction)
        mutable.addAttribute(
            kCTParagraphStyleAttributeName as NSAttributedString.Key,
            value: paragraph,
            range: fullRange
        )
        mutable.addAttribute(
            kCTLanguageAttributeName as NSAttributedString.Key,
            value: input.localeIdentifier as CFString,
            range: fullRange
        )
        return mutable
    }

    private static func resolvedRunStyle(
        base: TextStyle,
        run: AttributedString.Runs.Element
    ) -> TextStyle {
        var style = base
        if let fontName = run[TextFontNameAttribute.self] { style.fontName = fontName }
        if let pointSize = run[TextPointSizeAttribute.self] { style.pointSize = pointSize }
        if let weight = run[TextWeightAttribute.self] { style.weight = weight }
        return style
    }

    private static func makeFont(style: TextStyle, localeIdentifier: String) -> CTFont {
        let size = CGFloat(style.pointSize)
        let baseDescriptor: CTFontDescriptor
        if style.fontName == "system" {
            let systemFont =
                CTFontCreateUIFontForLanguage(.system, size, localeIdentifier as CFString)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            baseDescriptor = CTFontCopyFontDescriptor(systemFont)
        } else {
            baseDescriptor = CTFontDescriptorCreateWithNameAndSize(style.fontName as CFString, size)
        }
        let weightValue = weightTraitValues[style.weight] ?? 0
        let traits: CFDictionary = [kCTFontWeightTrait: weightValue] as CFDictionary
        let weighted = CTFontDescriptorCreateCopyWithAttributes(
            baseDescriptor,
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(weighted, size, nil)
    }

    /// Backs `CTParagraphStyleSetting.value` pointers with heap storage that outlives the array
    /// literal building them (a bare `&localVar` is only valid for the duration of the one
    /// initializer call it is passed into, which the compiler now flags — this box owns each
    /// value until `CTParagraphStyleCreate` has copied it out and the box itself is released).
    private final class ParagraphSettingStorage {
        private var pointers: [UnsafeMutableRawPointer] = []

        func store<T>(_ value: T) -> UnsafeRawPointer {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
            pointer.initialize(to: value)
            pointers.append(UnsafeMutableRawPointer(pointer))
            return UnsafeRawPointer(pointer)
        }

        deinit {
            for pointer in pointers { pointer.deallocate() }
        }
    }

    private static func makeParagraphStyle(style: TextStyle, direction: LayoutDirection)
        -> CTParagraphStyle
    {
        let storage = ParagraphSettingStorage()
        let alignment = ctAlignment(for: style.alignment, direction: direction)
        let lineBreakMode = CTLineBreakMode.byWordWrapping
        let writingDirection: CTWritingDirection =
            direction == .rightToLeft ? .rightToLeft : .leftToRight
        var settings = [
            CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: storage.store(alignment)
            ),
            CTParagraphStyleSetting(
                spec: .lineBreakMode,
                valueSize: MemoryLayout<CTLineBreakMode>.size,
                value: storage.store(lineBreakMode)
            ),
            CTParagraphStyleSetting(
                spec: .baseWritingDirection,
                valueSize: MemoryLayout<CTWritingDirection>.size,
                value: storage.store(writingDirection)
            ),
        ]
        if style.lineHeight > 0 {
            let lineHeight = CGFloat(style.lineHeight)
            settings.append(
                CTParagraphStyleSetting(
                    spec: .minimumLineHeight,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: storage.store(lineHeight)
                )
            )
            settings.append(
                CTParagraphStyleSetting(
                    spec: .maximumLineHeight,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: storage.store(lineHeight)
                )
            )
        }
        let result = CTParagraphStyleCreate(&settings, settings.count)
        _ = storage
        return result
    }

    private static func cgColor(_ color: ThemeColor) -> CGColor {
        CGColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    private static func ctAlignment(for alignment: TextAlignment, direction: LayoutDirection)
        -> CTTextAlignment
    {
        switch (alignment, direction) {
        case (.center, _): return .center
        case (.leading, .leftToRight), (.trailing, .rightToLeft): return .left
        case (.trailing, .leftToRight), (.leading, .rightToLeft): return .right
        }
    }
}
