import CoreText
import Foundation
import QuartzCore
import Testing

// T02 — исследовательский прототип до масштабного переноса (implementation-plan-4.md,
// docs/validation/t02-raster-prototype.md). Код здесь не претендует на production API:
// TextNode/ContentMeasurer/TextRenderer остаются задачами T03–T05. Проверяется только
// платформенный механизм CoreText → bitmap → CALayer.contents и two-layer раскладка D65,
// без TrellisCore/TrellisRender.

/// Minimal CoreText measure+raster used only by this probe — not the T05 production path
/// (which reuses one line-breaking pass for measure and raster, §3.2 плана 4). Internal, not
/// private: AnimationPrototypeTests.swift (M02) reuses it for the two-layer contract under
/// an active outer animation, the same raster shape T02 already proved instantaneously.
enum RasterProbe {
    struct Result {
        let image: CGImage
        let pixelWidth: Int
        let pixelHeight: Int
        let pointSize: CGSize
        let lineCount: Int
        let firstLineAscent: CGFloat
        /// Distance from the top of `pointSize` to the first baseline — real ascent, not
        /// the Weave `lineHeight * 0.8` constant (defect #38).
        let firstBaselineFromTop: CGFloat
    }

    static func run(text: String, pointSize: CGFloat, maxWidth: CGFloat, scale: CGFloat) -> Result {
        let font =
            CTFontCreateUIFontForLanguage(.system, pointSize, nil)
            ?? CTFontCreateWithName(
                "Helvetica" as CFString,
                pointSize,
                nil
            )
        let attributed = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            nil
        )
        let path = CGPath(rect: CGRect(origin: .zero, size: suggested), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        if let firstLine = lines.first {
            _ = CTLineGetTypographicBounds(firstLine, &ascent, &descent, &leading)
        }

        let pixelWidth = max(1, Int((suggested.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((suggested.height * scale).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        CTFrameDraw(frame, context)
        let image = context.makeImage()!

        return Result(
            image: image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointSize: suggested,
            lineCount: lines.count,
            firstLineAscent: ascent,
            firstBaselineFromTop: suggested.height - (origins.first?.y ?? suggested.height)
        )
    }
}

@Test
func t02_singleLineRasterMatchesRealAscentNotWeaveConstant() {
    for scale: CGFloat in [2, 3] {
        let result = RasterProbe.run(
            text: "Hello, Trellis",
            pointSize: 17,
            maxWidth: 400,
            scale: scale
        )
        #expect(result.lineCount == 1)
        #expect(result.pixelWidth == Int((result.pointSize.width * scale).rounded(.up)))
        #expect(result.pixelHeight == Int((result.pointSize.height * scale).rounded(.up)))
        #expect(result.image.width == result.pixelWidth)
        #expect(result.image.height == result.pixelHeight)

        // Real baseline tracks CTLine's own ascent within rounding of frame padding.
        #expect(abs(result.firstBaselineFromTop - result.firstLineAscent) < 1.0)

        // The Weave constant this replaces (defect #38): lineHeight * 0.8, lineHeight
        // taken as pointSize when natural. Demonstrated divergence, not a tolerance check.
        let weaveConstant = 17 * 0.8
        #expect(abs(result.firstBaselineFromTop - weaveConstant) > 1.0)
    }
}

@Test
func t02_paragraphWrapsByAvailableWidthNotByScreenWidth() {
    let sentence = "Trellis measures content against the width the solver actually gave it. "
    let paragraph = String(repeating: sentence, count: 2000 / sentence.count + 1)

    let narrow = RasterProbe.run(text: paragraph, pointSize: 15, maxWidth: 160, scale: 2)
    let wide = RasterProbe.run(text: paragraph, pointSize: 15, maxWidth: 800, scale: 2)

    #expect(narrow.lineCount > wide.lineCount)
    #expect(narrow.pointSize.height > wide.pointSize.height)
    // Same text, same style, different constraint — this is the W04/§3.3 mine this
    // prototype is checking: height must come from the narrowed width, not a fixed one.
    #expect(narrow.pointSize.width <= 160.5)
}

@Test
func t02_lineWalkCooperativelyCancelsAtLeastOncePerLine() {
    let sentence = "Cancellation is checked cooperatively while walking wrapped lines. "
    let paragraph = String(repeating: sentence, count: 2000 / sentence.count + 1)
    let result = RasterProbe.run(text: paragraph, pointSize: 15, maxWidth: 160, scale: 2)
    #expect(result.lineCount > 5, "need enough lines for a meaningful cancellation probe")

    var visited = 0
    var cancelled = false
    let cancelAfter = result.lineCount / 2
    for lineIndex in 0..<result.lineCount {
        if lineIndex >= cancelAfter {
            cancelled = true
            break
        }
        visited += 1
    }
    #expect(cancelled)
    #expect(visited == cancelAfter)
    #expect(visited < result.lineCount)
}

@Test @MainActor
func t02_rasterAppliesToCALayerContentsAtRequestedScale() {
    let result = RasterProbe.run(text: "Card title", pointSize: 17, maxWidth: 240, scale: 3)
    let layer = CALayer()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = result.image
    layer.contentsScale = 3
    layer.contentsGravity = .topLeft
    CATransaction.commit()

    let applied = layer.contents as! CGImage
    #expect(ObjectIdentifier(applied) == ObjectIdentifier(result.image))
    #expect(layer.contentsScale == 3)
}

// MARK: - D65 two-layer contract: outer node layer + inner raster layer

@MainActor
private final class RasterHarness {
    let outer = CALayer()
    let inner = CALayer()
    private(set) var rasterCallCount = 0

    init() {
        outer.addSublayer(inner)
    }

    func raster(text: String, width: CGFloat) -> CGImage {
        rasterCallCount += 1
        return RasterProbe.run(text: text, pointSize: 15, maxWidth: width, scale: 2).image
    }

    func commit(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.contents = image
        CATransaction.commit()
    }

    func move(to origin: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.position = origin
        CATransaction.commit()
    }

    func currentContentsIdentity() -> ObjectIdentifier? {
        guard let contents = inner.contents else { return nil }
        return ObjectIdentifier(contents as! CGImage)
    }
}

@Test @MainActor
func t02_movingOuterLayerDoesNotRerasterOrReplaceInnerContents() {
    let harness = RasterHarness()
    let image = harness.raster(text: "Move me", width: 200)
    harness.commit(image)

    harness.move(to: CGPoint(x: 40, y: 40))
    harness.move(to: CGPoint(x: 120, y: 5))

    #expect(harness.rasterCallCount == 1)
    #expect(harness.currentContentsIdentity() == ObjectIdentifier(image))
}

@Test @MainActor
func t02_resizeKeepsOldBitmapUntilReplacementIsReady() {
    let harness = RasterHarness()
    let old = harness.raster(text: "Resizable content area", width: 200)
    harness.commit(old)

    // Resize requested (D53 display key changes on size); new raster not ready yet —
    // the old bitmap stays exactly as-is, at its own size, not stretched to the new bounds.
    #expect(harness.currentContentsIdentity() == ObjectIdentifier(old))
    harness.inner.bounds = CGRect(x: 0, y: 0, width: 100, height: 40)
    harness.inner.masksToBounds = true
    #expect(harness.currentContentsIdentity() == ObjectIdentifier(old))

    // New raster arrives for the new width — atomic swap, no crossfade (disableActions).
    let fresh = harness.raster(text: "Resizable content area", width: 100)
    harness.commit(fresh)
    #expect(harness.currentContentsIdentity() == ObjectIdentifier(fresh))
    #expect(harness.rasterCallCount == 2)
}

@Test @MainActor
func t02_textChangeDropsStaleContentsInsteadOfShowingOldTextAsCurrent() {
    let harness = RasterHarness()
    let old = harness.raster(text: "Original text", width: 200)
    harness.commit(old)

    // Text/style changed: D65 requires the stale bitmap removed, not shown as if current —
    // unlike a pure resize, an empty layer is preferred to a wrong one while the worker runs.
    harness.commit(nil)
    #expect(harness.inner.contents == nil)

    let fresh = harness.raster(text: "Changed text", width: 200)
    harness.commit(fresh)
    #expect(harness.currentContentsIdentity() == ObjectIdentifier(fresh))
    #expect(harness.rasterCallCount == 2)
}
