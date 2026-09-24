#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import NodesRender
    import QuartzCore
    import Testing

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
#endif

#if canImport(AppKit)
    import AppKit
    import NodesAppKit

    @Test @MainActor
    func aFlippedHostDrawsTextFlippedSoItShowsUpright() throws {
        let column = Column(Text("Hello"), height: 100)
        let view = NodeNSView(root: column)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        view.layout()

        let layer = try #require(view.renderedLayer(for: column.text))
        let image = layer.contents as! CGImage
        #expect(layer.contentsAreFlipped())
        let rows = inkRows(image)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0 >= image.height / 2 })
        view.host.detach()
    }
#endif
