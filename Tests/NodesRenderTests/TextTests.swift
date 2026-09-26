#if canImport(CoreText)
    import CoreText
    import Foundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import Testing

    @testable import NodesRender

    @MainActor
    private final class Column: Node {
        let text: Text
        let boxHeight: Double?

        init(_ text: Text, height: Double? = nil) {
            self.text = text
            boxHeight = height
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                if let boxHeight { text.height(.points(boxHeight)) } else { text }
            }
            .alignItems(.start)
        }
    }

    /// Text in a fixed 200-point box, wider than the text.
    @MainActor
    private final class Box: Node {
        let text: Text

        init(_ text: Text) {
            self.text = text
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { text.width(.points(200)) }.alignItems(.start)
        }
    }

    /// Rows of `image`, top to bottom, that have any ink.
    private func inkRows(_ image: CGImage) -> [Int] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).filter { row in
            (0..<width).contains { pixels[(row * width + $0) * 4 + 3] > 0 }
        }
    }

    @Test @MainActor
    func textTakesItsWidthOnOneLineAndWrapsWhenNarrow() {
        let wide = Column(Text("Hello world"))
        let wideHost = NodeHost(root: wide, size: LayoutSize(width: 1000, height: 500))
        wideHost.layoutIfNeeded()
        let narrow = Column(Text("Hello world"))
        let narrowHost = NodeHost(root: narrow, size: LayoutSize(width: 50, height: 500))
        narrowHost.layoutIfNeeded()

        let line = wide.text.frame.size
        #expect(line.width > 50)
        #expect(line.height > 0)
        #expect(narrow.text.frame.size.height > line.height * 1.5)
        wideHost.detach()
        narrowHost.detach()
    }

    @Test @MainActor
    func changingTheTextLaysTheTreeOutAgain() {
        let column = Column(Text("Hi"))
        let host = NodeHost(root: column, size: LayoutSize(width: 1000, height: 500))
        host.layoutIfNeeded()
        let before = column.text.frame.size.width

        column.text.text = "Hello, world"
        host.layoutIfNeeded()

        #expect(host.passes == 2)
        #expect(column.text.frame.size.width > before)
        host.detach()
    }

    /// Columns of `image`, left to right, that have any ink.
    private func inkColumns(_ image: CGImage) -> [Int] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<width).filter { column in
            (0..<height).contains { pixels[($0 * width + column) * 4 + 3] > 0 }
        }
    }

    @Test @MainActor
    func changedTextFadesInWhenTheChangeIsAnimated() throws {
        let column = Column(Text("Hello"))
        let host = NodeHost(root: column, size: LayoutSize(width: 300, height: 100))
        let renderer = LayerRenderer()
        let container = CALayer()
        // Checked before Core Animation commits: outside a window a commit drops animations.
        CATransaction.begin()
        defer {
            host.detach()
            CATransaction.commit()
        }
        func render() {
            host.layoutIfNeeded()
            renderer.render(column, in: container, animation: host.renderAnimation)
            host.didRender()
        }
        render()
        let layer = try #require(renderer.layer(for: column.text))
        let before = try #require(layer.contents)

        withAnimation {
            column.text.text = "Hello there"
        }
        render()
        let fade = try #require(layer.animation(forKey: "contents") as? CABasicAnimation)
        #expect(fade.fromValue as AnyObject === before as AnyObject)
        #expect(fade.toValue as AnyObject === layer.contents as AnyObject)
        #expect(fade.duration == 0.25)

        // Without an animation the new text shows at once.
        column.text.text = "Hi"
        render()
        #expect(layer.animation(forKey: "contents") == nil)
    }

    @Test @MainActor
    func leadingTextStartsAtTheRightInARightToLeftLayout() throws {
        let text = Text("Hi")
        let box = Box(text)
        let host = NodeHost(root: box, size: LayoutSize(width: 300, height: 100))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        let root = CALayer()
        renderer.render(box, in: root, scale: 1)
        let leftToRight = inkColumns(try #require(renderer.layer(for: text)?.contents) as! CGImage)
        #expect(try #require(leftToRight.max()) < 100)

        // The host turns right to left: the same frame, drawn again at the other edge.
        host.direction = .rightToLeft
        host.layoutIfNeeded()
        renderer.render(box, in: root, scale: 1)
        let rightToLeft = inkColumns(try #require(renderer.layer(for: text)?.contents) as! CGImage)
        #expect(try #require(rightToLeft.min()) > 100)
        host.detach()
    }

    @Test @MainActor
    func textIsDrawnAtTheScaleAndUprightInAPlainLayer() throws {
        let column = Column(Text("Hello"), height: 100)
        let host = NodeHost(root: column, size: LayoutSize(width: 300, height: 300))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.render(column, in: CALayer(), scale: 2)

        let layer = try #require(renderer.layer(for: column.text))
        let contents = try #require(layer.contents)
        let image = contents as! CGImage
        #expect(image.height == 200)
        #expect(image.width == Int((column.text.frame.size.width * 2).rounded(.up)))
        // One line at the top of a 100-point box.
        let rows = inkRows(image)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0 < 100 })
        host.detach()
    }

    /// The frame `text` gets in a column `width` wide.
    @MainActor
    private func frame(of text: Text, width: Double) -> LayoutRect {
        let column = Column(text)
        let host = NodeHost(root: column, size: LayoutSize(width: width, height: 2000))
        host.layoutIfNeeded()
        defer { host.detach() }
        return text.frame
    }

    private let paragraph =
        "The engine lays out a whole tree of nodes in one pass, measuring text as it goes."

    @Test @MainActor
    func boldTextIsWiderThanRegular() {
        let regular = frame(of: Text("Hello world"), width: 1000)
        let bold = frame(of: Text("Hello world", style: TextStyle(weight: .bold)), width: 1000)

        #expect(bold.size.width > regular.size.width)
    }

    @Test @MainActor
    func lineSpacingSpreadsWrappedLines() {
        var spaced = TextStyle()
        spaced.lineSpacing = 10
        let tight = frame(of: Text("Hello world"), width: 60)
        let loose = frame(of: Text("Hello world", style: spaced), width: 60)

        #expect(loose.size.height >= tight.size.height + 9)
    }

    @Test @MainActor
    func maxLinesKeepsOnlyTheFirstLines() {
        var one = TextStyle()
        one.maxLines = 1
        var two = TextStyle()
        two.maxLines = 2
        let all = frame(of: Text(paragraph), width: 120)
        let first = frame(of: Text(paragraph, style: one), width: 120)
        let firstTwo = frame(of: Text(paragraph, style: two), width: 120)

        #expect(first.size.height < firstTwo.size.height)
        #expect(firstTwo.size.height < all.size.height)
        #expect(abs(firstTwo.size.height - 2 * first.size.height) <= 2)
    }

    @Test @MainActor
    func truncatedTextIsDrawn() throws {
        var one = TextStyle()
        one.maxLines = 1
        let column = Column(Text(paragraph, style: one))
        let host = NodeHost(root: column, size: LayoutSize(width: 120, height: 300))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.render(column, in: CALayer(), scale: 2)

        let layer = try #require(renderer.layer(for: column.text))
        let image = layer.contents as! CGImage
        #expect(!inkRows(image).isEmpty)
        host.detach()
    }

    // MARK: - Measuring once

    /// The measurements a text gives the engine in its layouts.
    @MainActor
    private func measurements(of text: Text) -> TextMeasurements? {
        guard case .measured(let measurer)? = text.layoutContent else { return nil }

        return (measurer as? TextMeasurer)?.measurements
    }

    @Test @MainActor
    func aTextKeepsItsMeasurementsUntilItsTextOrStyleChanges() throws {
        let text = Text("Hello world")
        let first = try #require(measurements(of: text))

        #expect(measurements(of: text) === first)
        text.text = "Hello there"
        let second = try #require(measurements(of: text))
        #expect(second !== first)
        text.style = TextStyle(size: 30)
        #expect(measurements(of: text) !== second)
    }

    @Test @MainActor
    func aTextWhoseStyleChangedIsMeasuredInTheNewStyle() {
        let column = Column(Text("Hello world"))
        let host = NodeHost(root: column, size: LayoutSize(width: 1000, height: 500))
        host.layoutIfNeeded()
        let before = column.text.frame.size

        column.text.style = TextStyle(size: 34)
        host.layoutIfNeeded()

        #expect(column.text.frame.size.width > before.width * 1.5)
        #expect(column.text.frame.size.height > before.height * 1.5)
        host.detach()
    }

    @Test
    func measurementsMeasureEachValueOnce() {
        let measurements = TextMeasurements()
        var measured = 0
        let measure = { () -> Double in
            measured += 1
            return 42
        }

        #expect(measurements.value(\.maxContentWidth, measure: measure) == 42)
        #expect(measurements.value(\.maxContentWidth, measure: measure) == 42)
        #expect(measured == 1)
        #expect(measurements.value(\.minContentWidth, measure: measure) == 42)
        #expect(measured == 2)

        #expect(measurements.height(forWidth: 100, measure: measure) == 42)
        #expect(measurements.height(forWidth: 100, measure: measure) == 42)
        #expect(measurements.height(forWidth: 120, measure: measure) == 42)
        #expect(measured == 4)
        // Heights for many widths are kept only for the latest ones.
        for width in 0..<40 {
            _ = measurements.height(forWidth: Double(1000 + width), measure: measure)
        }
        #expect(measured == 44)
        #expect(measurements.height(forWidth: 1039, measure: measure) == 42)
        #expect(measured == 44)
        // The first widths are no longer kept.
        #expect(measurements.height(forWidth: 100, measure: measure) == 42)
        #expect(measured == 45)
    }

    @Test
    func aThreadMakesTheFontOfAStyleOnce() async {
        let regular = TextLayout.font(for: TextStyle(size: 15))
        let bold = TextLayout.font(for: TextStyle(size: 15, weight: .bold))

        #expect(TextLayout.font(for: TextStyle(size: 15)) === regular)
        #expect(TextLayout.font(for: TextStyle(size: 15, weight: .bold)) === bold)
        #expect(bold !== regular)
        #expect(TextLayout.font(for: TextStyle(size: 16)) !== regular)
        // Another thread makes its own, the same font.
        let name = await Task.detached {
            CTFontCopyPostScriptName(TextLayout.font(for: TextStyle(size: 15, weight: .bold)))
                as String
        }.value
        #expect(name == CTFontCopyPostScriptName(bold) as String)
    }

#endif

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import NodesAppKit

    @Test @MainActor
    func aFlippedHostDrawsTextUpright() throws {
        let column = Column(Text("Hello"), height: 100)
        let view = NodeNSView(root: column)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        view.layout()

        let layer = try #require(view.renderedLayer(for: column.text))
        let image = layer.contents as! CGImage
        // The image is shown as it is: one upright line at the top of a 100-point box.
        let rows = inkRows(image)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0 < image.height / 2 })
        view.host.detach()
    }
#endif
