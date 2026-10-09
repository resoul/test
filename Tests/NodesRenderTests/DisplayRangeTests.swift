#if canImport(CoreText)
    import CoreGraphics
    import Foundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import Testing

    @testable import NodesRender

    /// A scroll of 40 lines of text, each about as tall as a line, in a host 100 points high.
    @MainActor
    private final class Article: Node {
        let lines: [Text]
        lazy var scroll = Scroll(.vertical, content: Body(lines))

        override init() {
            lines = (0..<40).map { Text("Line \($0)") }
            super.init()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll.flex(grow: 1) }
        }
    }

    @MainActor
    private final class Body: Node {
        let lines: [Text]

        init(_ lines: [Text]) {
            self.lines = lines
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for line in lines { line.flex(shrink: 0) }
            }
            .alignItems(.start)
        }
    }

    @MainActor
    private func setUp(
        range: LayerRenderer.DisplayRange?
    ) -> (article: Article, host: NodeHost, renderer: LayerRenderer) {
        let article = Article()
        let host = NodeHost(root: article, size: LayoutSize(width: 200, height: 100))
        host.layoutIfNeeded()
        let renderer = LayerRenderer()
        renderer.displayRange = range
        renderer.render(article, in: CALayer(), scale: 1)
        return (article, host, renderer)
    }

    /// The indexes of the lines whose layer holds a bitmap.
    @MainActor
    private func drawnLines(_ article: Article, _ renderer: LayerRenderer) -> [Int] {
        article.lines.indices.filter { renderer.layer(for: article.lines[$0])?.contents != nil }
    }

    @MainActor
    private func scrollTo(
        _ y: Double,
        _ article: Article,
        _ host: NodeHost,
        _ renderer: LayerRenderer
    ) {
        article.scroll.contentOffset = LayoutPoint(x: 0, y: y)
        renderer.renderScrolls([article.scroll])
    }

    @Test @MainActor
    func withoutARangeEverythingMountedIsDrawn() {
        let (article, host, renderer) = setUp(range: nil)

        #expect(drawnLines(article, renderer).count == 40)
        host.detach()
    }

    @Test @MainActor
    func withARangeOnlyTheContentNearTheScreenIsDrawn() {
        let (article, host, renderer) = setUp(range: .init(drawDistance: 1, releaseDistance: 2))

        let drawn = drawnLines(article, renderer)
        // A window length past the window's end, 100 points, and one more window: 200.
        let lastNear = article.lines.lastIndex { $0.frame.origin.y <= 200 }
        #expect(!drawn.isEmpty)
        #expect(drawn.first == 0)
        #expect(drawn.count < 40)
        #expect(drawn.last! <= lastNear!)
        #expect(drawn.count > 5, "the window alone shows five lines or more")
        host.detach()
    }

    @Test @MainActor
    func scrollingDrawsWhatComesNearAndReleasesWhatGoesFar() {
        let (article, host, renderer) = setUp(range: .init(drawDistance: 1, releaseDistance: 2))
        let before = drawnLines(article, renderer)
        #expect(before.contains(0))

        scrollTo(500, article, host, renderer)

        let after = drawnLines(article, renderer)
        // The window is 500..600; line 0 is five windows away.
        #expect(!after.contains(0))
        let shownLine = article.lines.firstIndex { $0.frame.origin.y >= 520 }!
        #expect(after.contains(shownLine))
        host.detach()
    }

    @Test @MainActor
    func contentBetweenTheTwoDistancesKeepsItsBitmapButIsNotMade() {
        let (article, host, renderer) = setUp(range: .init(drawDistance: 1, releaseDistance: 3))
        let line = 12  // about 240 down: 1.4 windows from the window at the top
        #expect(article.lines[line].frame.origin.y > 150)
        #expect(renderer.layer(for: article.lines[line])?.contents == nil, "not near enough")

        scrollTo(120, article, host, renderer)
        #expect(renderer.layer(for: article.lines[line])?.contents != nil, "now near")

        scrollTo(0, article, host, renderer)
        #expect(
            renderer.layer(for: article.lines[line])?.contents != nil,
            "between the two distances it is kept"
        )
        host.detach()
    }

    @Test @MainActor
    func releasedContentIsDrawnAgainTheSameWhenItComesBack() throws {
        let (article, host, renderer) = setUp(range: .init(drawDistance: 1, releaseDistance: 2))
        let first = try #require(renderer.layer(for: article.lines[0])?.contents) as! CGImage
        let original = first.dataProvider?.data as Data?

        scrollTo(500, article, host, renderer)
        #expect(renderer.layer(for: article.lines[0])?.contents == nil)
        scrollTo(0, article, host, renderer)

        let back = try #require(renderer.layer(for: article.lines[0])?.contents) as! CGImage
        #expect(back.dataProvider?.data as Data? == original)
        host.detach()
    }

    @Test @MainActor
    func aSmallMoveDoesNotReviewTheRange() {
        let (article, host, renderer) = setUp(range: .init(drawDistance: 1, releaseDistance: 2))
        let next = article.lines.firstIndex { renderer.layer(for: $0)?.contents == nil }!
        let line = article.lines[next]

        // The scroll is 100 long, so a review waits for a move of 25 points. After ten the line
        // is within reach of the window, but nobody has looked.
        scrollTo(10, article, host, renderer)
        scrollTo(20, article, host, renderer)
        #expect(line.screenfulsToScreen! <= 1)
        #expect(renderer.layer(for: line)?.contents == nil)

        scrollTo(60, article, host, renderer)
        #expect(renderer.layer(for: line)?.contents != nil)
        host.detach()
    }

    @Test @MainActor
    func trimmingMemoryKeepsWhatShowsAndReleasesTheRest() {
        let (article, host, renderer) = setUp(range: nil)
        #expect(drawnLines(article, renderer).count == 40)

        renderer.trimMemory()

        let kept = drawnLines(article, renderer)
        let showing = article.lines.indices.filter { article.lines[$0].screenfulsToScreen == 0 }
        #expect(kept == showing)
        #expect(!kept.isEmpty)
        #expect(kept.count < 40)
        host.detach()
    }

    @Test @MainActor
    func trimmedContentIsDrawnAgainAtTheNextRender() {
        let (article, host, renderer) = setUp(range: nil)
        renderer.trimMemory()
        article.lines[30].text = "Changed line"
        host.layoutIfNeeded()

        renderer.render(article, in: CALayer(), scale: 1)

        #expect(renderer.layer(for: article.lines[30])?.contents != nil)
        host.detach()
    }

    @Test @MainActor
    func nodesReportTheirDistanceInWindowLengths() {
        let (article, host, _) = setUp(range: nil)

        #expect(article.lines[0].screenfulsToScreen == 0)
        let far = article.lines.last!
        let expected = (far.frame.origin.y - 100) / 100
        #expect(abs((far.screenfulsToScreen ?? -1) - expected) < 0.001)
        host.detach()
    }
#endif
