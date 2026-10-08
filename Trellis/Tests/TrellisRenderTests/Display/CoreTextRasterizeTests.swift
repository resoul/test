import CoreGraphics
import Foundation
import Testing
import TrellisCore

@testable import TrellisRender

// T06 — the draw side of CoreTextRenderer (measurement was T05). Reuses the same
// makeAttributedString/makeFont/makeParagraphStyle helpers measure() uses (implementation-plan-4
// §T05/T06: "единая логика line breaks ... для measure и raster").

private func request(
    text: String,
    style: TextStyle = TextStyle(),
    size: MeasuredSize,
    maxLines: Int? = nil,
    truncation: TextTruncation = .tail,
    scale: Double = 2
) -> TextDisplayRequest {
    TextDisplayRequest(
        input: TextLayoutInput(
            document: TextDocument(text),
            style: style,
            direction: .leftToRight,
            localeIdentifier: "en",
            maxLines: maxLines,
            truncation: truncation
        ),
        size: size,
        resolvedColor: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1),
        scale: scale
    )
}

@Test
func t06_rasterProducesAnImageAtTheRequestedPixelSize() throws {
    let renderer = CoreTextRenderer()
    let artifact = try renderer.rasterize(
        request(text: "Card title", size: MeasuredSize(width: 120, height: 24), scale: 3),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == Int((120.0 * 3).rounded(.up)))
    #expect(artifact.pixelHeight == Int((24.0 * 3).rounded(.up)))
    #expect(artifact.image.width == artifact.pixelWidth)
    #expect(artifact.image.height == artifact.pixelHeight)
    #expect(artifact.scale == 3)
}

@Test
func t06_emptyStringRastersToABlankImageWithoutFailing() throws {
    let renderer = CoreTextRenderer()
    let artifact = try renderer.rasterize(
        request(text: "", size: MeasuredSize(width: 100, height: 20)),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == 200)
    #expect(artifact.pixelHeight == 40)
}

@Test
func t06_zeroSizeRastersToAOnePixelImageWithoutFailing() throws {
    let renderer = CoreTextRenderer()
    let artifact = try renderer.rasterize(
        request(text: "Some text", size: MeasuredSize(width: 0, height: 0)),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == 1)
    #expect(artifact.pixelHeight == 1)
}

/// Bytes in the artifact's own backing store that are not all-zero — a wholly blank RGBA
/// bitmap (nothing drawn, including no alpha) is every byte `0`. Not a pixel-perfect glyph
/// check (T05/T06 already cover shape/metrics); this only tells "something was actually
/// drawn" from "the image is blank", the distinction defect #47 needed and no existing test
/// made — every prior raster test here only checked `pixelWidth`/`pixelHeight`.
private func nonZeroByteCount(_ image: CGImage) -> Int {
    guard let data = image.dataProvider?.data as Data? else { return 0 }
    return data.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
}

@Test
func t06_measuredHeightIsAlwaysSufficientToRasterAtLeastOneVisibleLine() throws {
    // Defect #47 (docs/defects.md): `rasterize()` used to build its `CTFramesetterCreateFrame`
    // path at exactly `request.size.height` — precisely what `measure()` reports for one
    // line's own `ascent + descent + leading`. At some point sizes `CTFrameGetLines` on a box
    // that tight came back completely empty (not one line short — zero), so `rasterize()` took
    // its "nothing fits" branch and produced a fully blank image for genuinely non-empty text,
    // with no error anywhere. Found building T12's S26 scene (13pt/32pt captions rendered as
    // nothing); scanning 6...60pt found only those two sizes broken on the pinned toolchain —
    // this test scans the same range so a regression anywhere in it is caught, not just at the
    // two sizes that happened to fail this time.
    let renderer = CoreTextRenderer()
    for pointSize in stride(from: 6.0, through: 60.0, by: 1.0) {
        let style = TextStyle(
            pointSize: pointSize,
            color: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let input = TextLayoutInput(
            document: TextDocument("Card 1"),
            style: style,
            direction: .leftToRight,
            localeIdentifier: "en",
            maxLines: nil,
            truncation: .tail
        )
        let metrics = try renderer.measure(
            input,
            constraint: SizeConstraint(width: .unspecified, height: .unspecified),
            context: .noCancellation
        )
        let artifact = try renderer.rasterize(
            TextDisplayRequest(
                input: input,
                size: metrics.size,
                resolvedColor: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1),
                scale: 2
            ),
            context: .noCancellation
        )
        #expect(
            nonZeroByteCount(artifact.image) > 0,
            "pointSize \(pointSize) rasterized a blank image for non-empty text"
        )
    }
}

@Test
func t06_maxLinesTruncationDrawsWithoutFailingAndKeepsTheRequestedBoxSize() throws {
    let renderer = CoreTextRenderer()
    let text = String(repeating: "wrap this across several lines please ", count: 20)
    let artifact = try renderer.rasterize(
        request(
            text: text,
            size: MeasuredSize(width: 150, height: 60),
            maxLines: 2,
            truncation: .tail,
            scale: 2
        ),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == 300)
    #expect(artifact.pixelHeight == 120)
}

@Test
func t06_clipTruncationDrawsWithoutFailingAndKeepsTheRequestedBoxSize() throws {
    let renderer = CoreTextRenderer()
    let text = String(repeating: "wrap this across several lines please ", count: 20)
    let artifact = try renderer.rasterize(
        request(
            text: text,
            size: MeasuredSize(width: 150, height: 60),
            maxLines: 2,
            truncation: .clip,
            scale: 2
        ),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == 300)
    #expect(artifact.pixelHeight == 120)
}

@Test
func t06_runLevelColorOverrideDoesNotCrashRasterization() throws {
    let renderer = CoreTextRenderer()
    var document = TextDocument("plain ")
    var colored = AttributedString("colored")
    colored.trellisText.color = ThemeColor(red: 1, green: 0, blue: 0, alpha: 1)
    document.append(colored)

    let artifact = try renderer.rasterize(
        TextDisplayRequest(
            input: TextLayoutInput(
                document: document,
                style: TextStyle(),
                direction: .leftToRight,
                localeIdentifier: "en",
                maxLines: nil,
                truncation: .tail
            ),
            size: MeasuredSize(width: 150, height: 24),
            resolvedColor: ThemeColor(red: 0, green: 0, blue: 0, alpha: 1),
            scale: 2
        ),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == 300)
}

@Test
func t06_cancelledContextThrowsBeforeRasterizing() {
    let renderer = CoreTextRenderer()
    let cancelled = LayoutContext(cancellationCheck: { true })
    #expect(throws: LayoutCancellationError.self) {
        try renderer.rasterize(
            request(text: "irrelevant", size: MeasuredSize(width: 100, height: 20)),
            context: cancelled
        )
    }
}

@Test
func t06_rightToLeftRastersWithoutFailing() throws {
    let renderer = CoreTextRenderer()
    let artifact = try renderer.rasterize(
        request(text: "שלום עולם", size: MeasuredSize(width: 150, height: 24), scale: 1),
        context: .noCancellation
    )
    #expect(artifact.pixelWidth == 150)
}
