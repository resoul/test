#if canImport(CoreText)
    import CoreGraphics
    import Foundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import RichTextCore
    import Testing

    @testable import NodesRender

    @MainActor
    private final class Page: Node {
        let text: Text
        let other: Text
        var showsText = true

        init(_ text: Text, other: Text = Text("Second")) {
            self.text = text
            self.other = other
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                if showsText { text }
                other
            }
            .alignItems(.start)
        }
    }

    /// A drawing that cannot leave the main thread: it has no snapshot.
    @MainActor
    private final class MainOnly: Node, LayerDrawing {
        var drawingRevision: UInt64 { 1 }
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 40, height: 20)) }

        func draw(in context: CGContext, size: CGSize) {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor
    private final class Stack: Node {
        let drawing = MainOnly()

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { drawing }.alignItems(.start)
        }
    }

    @MainActor
    private func host(_ root: Node, width: Double = 200) -> NodeHost {
        let host = NodeHost(root: root, size: LayoutSize(width: width, height: 400))
        host.layoutIfNeeded()
        return host
    }

    private func bytes(of layer: CALayer?) -> Data? {
        guard let contents = layer?.contents else { return nil }

        return (contents as! CGImage).dataProvider?.data as Data?
    }

    @Test @MainActor
    func inAsynchronousModeTheLayerIsEmptyUntilTheBitmapArrives() async throws {
        let page = Page(Text("Hello world"))
        let host = host(page)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous

        renderer.render(page, in: CALayer(), scale: 2)

        #expect(renderer.layer(for: page.text)?.contents == nil)
        #expect(renderer.pendingDrawCount == 2)

        await renderer.drawingsFinished()

        #expect(renderer.pendingDrawCount == 0)
        #expect(bytes(of: renderer.layer(for: page.text)) != nil)
        host.detach()
    }

    @Test @MainActor
    func theBackgroundBitmapOfPlainTextIsTheOneTheMainThreadDraws() async throws {
        let make: @MainActor () -> Text = { Text("The quick brown fox jumps over the lazy dog") }
        let page = Page(make())
        let host = host(page, width: 120)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        renderer.render(page, in: CALayer(), scale: 2)
        await renderer.drawingsFinished()

        let reference = try #require(synchronousBytesAt(width: 120, make))

        #expect(try #require(bytes(of: renderer.layer(for: page.text))) == reference)
        host.detach()
    }

    /// The pixels of `make()` drawn on the main thread in a host of `width`.
    @MainActor
    private func synchronousBytesAt(width: Double, _ make: @MainActor () -> Text) -> Data? {
        let page = Page(make())
        let host = host(page, width: width)
        defer { host.detach() }
        let renderer = LayerRenderer()
        renderer.render(page, in: CALayer(), scale: 2)
        return bytes(of: renderer.layer(for: page.text))
    }

    @Test @MainActor
    func theBackgroundBitmapOfCutTextWithAMessageIsTheOneTheMainThreadDraws() async throws {
        var style = TextStyle()
        style.maxLines = 1
        style.fitScaleFactors = [1, 0.9]
        let make: @MainActor () -> Text = {
            let text = Text("The quick brown fox jumps over the lazy dog", style: style)
            text.truncationMessage = "More"
            return text
        }
        let reference = try #require(synchronousBytesAt(width: 160, make))
        let page = Page(make())
        let host = host(page, width: 160)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        renderer.render(page, in: CALayer(), scale: 2)

        await renderer.drawingsFinished()

        #expect(try #require(bytes(of: renderer.layer(for: page.text))) == reference)
        host.detach()
    }

    @Test @MainActor
    func theBackgroundBitmapOfRichTextIsTheOneTheMainThreadDraws() async throws {
        let site = URL(string: "https://example.test")!
        let make: @MainActor () -> Text = {
            Text(
                rich: RichText(
                    blocks: [
                        .paragraph([Run("Read "), Run("the page", link: site), Run(" for more")]),
                        .code("let x = 1", language: nil),
                    ]
                )
            )
        }
        let reference = try #require(synchronousBytesAt(width: 180, make))
        let page = Page(make())
        let host = host(page, width: 180)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        renderer.render(page, in: CALayer(), scale: 2)

        await renderer.drawingsFinished()

        #expect(try #require(bytes(of: renderer.layer(for: page.text))) == reference)
        host.detach()
    }

    @Test @MainActor
    func aTextChangedWhileItsBitmapIsOnItsWayShowsOnlyTheNewest() async throws {
        let page = Page(Text("First text"))
        let host = host(page)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        let container = CALayer()
        renderer.render(page, in: container, scale: 2)

        page.text.text = "Second text, longer than the first"
        host.layoutIfNeeded()
        renderer.render(page, in: container, scale: 2)
        await renderer.drawingsFinished()

        let reference = try #require(
            synchronousBytesAt(width: 200) { Text("Second text, longer than the first") }
        )
        #expect(try #require(bytes(of: renderer.layer(for: page.text))) == reference)
        host.detach()
    }

    @Test @MainActor
    func theLayerKeepsWhatItShowedUntilTheNewBitmapArrives() async throws {
        let page = Page(Text("Before"))
        let host = host(page)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        let container = CALayer()
        renderer.render(page, in: container, scale: 2)
        await renderer.drawingsFinished()
        let before = try #require(renderer.layer(for: page.text)?.contents)

        page.text.text = "After, which is different"
        host.layoutIfNeeded()
        renderer.render(page, in: container, scale: 2)

        #expect(renderer.layer(for: page.text)?.contents as AnyObject === before as AnyObject)
        await renderer.drawingsFinished()
        #expect(renderer.layer(for: page.text)?.contents as AnyObject !== before as AnyObject)
        host.detach()
    }

    @Test @MainActor
    func aNodeThatLeavesWhileItsBitmapIsOnItsWayLeavesNothingPending() async {
        let page = Page(Text("Hello"))
        let host = host(page)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous
        let container = CALayer()
        renderer.render(page, in: container, scale: 2)
        #expect(renderer.pendingDrawCount == 2)

        page.showsText = false
        page.setNeedsLayout()
        host.layoutIfNeeded()
        renderer.render(page, in: container, scale: 2)
        await renderer.drawingsFinished()

        #expect(renderer.pendingDrawCount == 0)
        #expect(renderer.layer(for: page.text) == nil)
        host.detach()
    }

    @Test @MainActor
    func aDrawingWithoutASnapshotIsDrawnOnTheMainThreadEvenInAsynchronousMode() {
        let stack = Stack()
        let host = host(stack)
        let renderer = LayerRenderer()
        renderer.drawingMode = .asynchronous

        renderer.render(stack, in: CALayer(), scale: 1)

        #expect(renderer.pendingDrawCount == 0)
        #expect(renderer.layer(for: stack.drawing)?.contents != nil)
        host.detach()
    }

    @Test @MainActor
    func theModeCanChangeBetweenRenders() async {
        let page = Page(Text("Hello"))
        let host = host(page)
        let renderer = LayerRenderer()
        let container = CALayer()
        renderer.drawingMode = .asynchronous
        renderer.render(page, in: container, scale: 1)

        page.text.text = "Changed"
        host.layoutIfNeeded()
        renderer.drawingMode = .synchronous
        renderer.render(page, in: container, scale: 1)

        #expect(renderer.pendingDrawCount == 1, "the other text is still on its way")
        #expect(renderer.layer(for: page.text)?.contents != nil)
        await renderer.drawingsFinished()
        host.detach()
    }
#endif
