#if canImport(QuartzCore) && canImport(CoreText)
    import LayoutCore
    import Nodes
    import QuartzCore
    import StateCore
    import Testing

    @testable import NodesRender

    @MainActor
    private final class Box: Node {
        let size: LayoutSize

        init(_ width: Double, _ height: Double, tappable: Bool = false) {
            size = LayoutSize(width: width, height: height)
            super.init()
            if tappable { onTap = {} }
        }

        override var layoutContent: LeafContent? { .size(size) }
    }

    /// A row of `count` narrow, tall siblings: the shape where labels crowd each other.
    @MainActor
    private final class Narrow: Node {
        let boxes: [Box]

        init(count: Int, width: Double = 12) {
            boxes = (0..<count).map { _ in Box(width, 60) }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                for box in boxes { box }
            }
            .alignItems(.start)
        }
    }

    @MainActor
    private func host(_ root: Node, width: Double = 200, height: Double = 80) -> NodeHost {
        let host = NodeHost(root: root, size: LayoutSize(width: width, height: height))
        host.layoutIfNeeded()
        return host
    }

    private struct Shown {
        let text: String
        /// In the coordinates of the overlay's container.
        let frame: CGRect
    }

    /// The outlines the overlay made in `layer`, and the labels it shows.
    @MainActor
    private func overlay(in layer: CALayer) -> (outlines: [CALayer], shown: [Shown]) {
        let container = (layer.sublayers ?? []).first { $0.name == "debug-overlay" }
        let outlines = (container?.sublayers ?? []).filter { $0.name == "debug-outline" }
        var shown: [Shown] = []
        for outline in outlines {
            for label in outline.sublayers ?? [] where !label.isHidden {
                shown.append(
                    Shown(
                        text: label.name ?? "",
                        frame: label.frame.offsetBy(dx: outline.frame.minX, dy: outline.frame.minY)
                    )
                )
            }
        }
        return (outlines, shown)
    }

    private func noneOverlap(_ labels: [Shown]) -> Bool {
        for (index, label) in labels.enumerated() {
            for other in labels[(index + 1)...] where label.frame.intersects(other.frame) {
                return false
            }
        }
        return true
    }

    @Test @MainActor
    func theOverlayDrawsAnOutlineForEveryNodeThatShows() {
        let row = Narrow(count: 4)
        let host = host(row)
        let layer = CALayer()
        let debug = DebugOverlay()
        host.showsDebugOverlay = true

        debug.update(for: host, in: layer, scale: 2)

        let (outlines, _) = overlay(in: layer)
        #expect(outlines.count == 5)
        #expect(debug.outlinedCount == 5)
        #expect(outlines.first { $0.frame == CGRect(x: 0, y: 0, width: 12, height: 60) } != nil)
        #expect(layer.sublayers?.last === debug.mountedContainer)
        host.detach()
    }

    @Test @MainActor
    func switchingTheFlagOffTakesEverythingAway() {
        let row = Narrow(count: 3)
        let host = host(row)
        let layer = CALayer()
        let debug = DebugOverlay()
        host.showsDebugOverlay = true
        debug.update(for: host, in: layer, scale: 1)
        #expect(debug.outlinedCount == 4)

        host.showsDebugOverlay = false
        debug.update(for: host, in: layer, scale: 1)

        #expect(debug.outlinedCount == 0)
        #expect(debug.mountedContainer == nil)
        #expect(layer.sublayers?.isEmpty ?? true)
        host.detach()
    }

    @Test @MainActor
    func theOverlayStaysTheLastLayerAndAddsNoneOfItsOwnToTheTree() {
        let row = Narrow(count: 2)
        let host = host(row)
        let layer = CALayer()
        let renderer = LayerRenderer()
        let debug = DebugOverlay()
        host.showsDebugOverlay = true
        renderer.render(row, in: layer)
        debug.update(for: host, in: layer, scale: 1)

        // The tree is drawn again, after the overlay was made: the overlay goes back on top.
        renderer.render(row, in: layer)
        debug.update(for: host, in: layer, scale: 1)

        #expect(layer.sublayers?.count == 2)
        #expect(layer.sublayers?.last === debug.mountedContainer)
        #expect(renderer.layer(for: row)?.sublayers?.count == 2, "the nodes' layers are untouched")
        host.detach()
    }

    @Test(arguments: [1.0, 2.0]) @MainActor
    func shownLabelsNeverOverlapNorLeaveTheCanvas(scale: Double) {
        let row = Narrow(count: 8)
        let host = host(row)
        let layer = CALayer()
        let debug = DebugOverlay()
        // Reading-order labels have a fixed short width, so the fit does not depend on how many
        // nodes other tests have made.
        debug.labelStyle = .treeOrder
        host.showsDebugOverlay = true

        debug.update(for: host, in: layer, scale: scale)

        let (outlines, shown) = overlay(in: layer)
        #expect(outlines.count == 9)
        #expect(noneOverlap(shown))
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 80)
        #expect(shown.allSatisfy { canvas.contains($0.frame) })
        #expect(shown.count == 9)
        host.detach()
    }

    @Test @MainActor
    func aLabelWithoutRoomIsHiddenAndItsOutlineStays() {
        let row = Narrow(count: 20, width: 4)
        let host = host(row, width: 90, height: 30)
        let layer = CALayer()
        let debug = DebugOverlay()
        host.showsDebugOverlay = true

        debug.update(for: host, in: layer, scale: 2)

        let (outlines, shown) = overlay(in: layer)
        #expect(outlines.count == 21)
        #expect(shown.count < 21)
        #expect(!shown.isEmpty)
        #expect(noneOverlap(shown))
    }

    @Test @MainActor
    func theLabelsFollowTheLabelStyle() {
        let row = Narrow(count: 2)
        let host = host(row)
        let layer = CALayer()
        let debug = DebugOverlay()
        host.showsDebugOverlay = true

        // The text is an image, so its words are not readable from the layer; what a style
        // changes is the label's width, and so which labels fit. The sizes of the full texts show.
        debug.labelStyle = .treeOrder
        debug.update(for: host, in: layer, scale: 1)
        let short = overlay(in: layer).shown.map { $0.frame.width }.max() ?? 0
        debug.labelStyle = .typeName
        debug.update(for: host, in: layer, scale: 1)
        let named = overlay(in: layer).shown.map { $0.frame.width }.max() ?? 0

        #expect(named > short, "a type name with a size is longer than a position with one")
        host.detach()
    }

    @Test @MainActor
    func theOutlinesFollowAScrollAndNodesThatLeftAreRemoved() {
        final class Rows: Node {
            let rows = (0..<10).map { _ in Box(50, 30) }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) {
                    for row in rows { row }
                }
                .alignItems(.start)
            }
        }
        let rows = Rows()
        let scroll = Scroll(.vertical, content: rows)
        let host = host(scroll, width: 100, height: 100)
        let layer = CALayer()
        let debug = DebugOverlay()
        host.showsDebugOverlay = true
        debug.update(for: host, in: layer, scale: 1)
        let before = overlay(in: layer).outlines.count

        scroll.contentOffset = LayoutPoint(x: 0, y: 200)
        debug.update(for: host, in: layer, scale: 1)
        let after = overlay(in: layer).outlines

        // Rows above the window have gone out of the canvas and lost their outlines; the rest
        // moved with the scroll. (The scroll's content, 300 points tall, still meets the canvas.)
        let rowSize = CGSize(width: 50, height: 30)
        let shownRows = after.filter { $0.frame.size == rowSize }
        #expect(before > shownRows.count)
        #expect(shownRows.count == 4, "rows 6 to 9 meet the 100-point window at offset 200")
        #expect(shownRows.allSatisfy { $0.frame.maxY > 0 })
        #expect(after.contains { $0.frame == CGRect(x: 0, y: 70, width: 50, height: 30) })
        host.detach()
    }

    // MARK: Where the labels go

    @Test
    func theLabelLayoutIsDeterministicAndKeepsLabelsInsideTheCanvas() {
        typealias Candidate = DebugOverlayLabelLayout.Candidate
        let canvas = CGSize(width: 100, height: 40)
        let candidates = [
            // A container at the canvas origin: there is no row above it.
            Candidate(
                outline: CGRect(x: 0, y: 0, width: 100, height: 40),
                depth: 0,
                order: 0,
                fullText: "#1 100×40",
                shortText: "#1"
            ),
            // A narrow node at the right edge: its full text would leave the canvas from every
            // position, so only the short text can be shown.
            Candidate(
                outline: CGRect(x: 90, y: 0, width: 10, height: 40),
                depth: 1,
                order: 1,
                fullText: "#2 10×40 with a long label",
                shortText: "#2"
            ),
        ]

        let first = DebugOverlayLabelLayout.place(candidates, canvas: canvas, fontSize: 9)
        let second = DebugOverlayLabelLayout.place(candidates, canvas: canvas, fontSize: 9)

        #expect(first == second)
        let bounds = CGRect(origin: .zero, size: canvas)
        #expect(first.compactMap { $0 }.allSatisfy { bounds.contains($0.frame) })
        #expect(first[1]?.text == "#2")
        #expect(first[0]?.text == "#1 100×40")
        #expect(first[0]?.frame.minY == 0)
    }

    @Test
    func aChildAndParentWithTheSameFrameGetSeparateLabelsAndTheChildKeepsTheCorner() {
        typealias Candidate = DebugOverlayLabelLayout.Candidate
        let frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        let placed = DebugOverlayLabelLayout.place(
            [
                Candidate(
                    outline: frame,
                    depth: 0,
                    order: 0,
                    fullText: "parent 120×60",
                    shortText: "parent"
                ),
                Candidate(
                    outline: frame,
                    depth: 1,
                    order: 1,
                    fullText: "child 120×60",
                    shortText: "child"
                ),
            ],
            canvas: CGSize(width: 120, height: 60),
            fontSize: 9
        )

        let parent = placed[0]
        let child = placed[1]
        #expect(child?.frame.minY == 0)
        #expect(parent?.frame.minY == child?.frame.maxY)
        #expect(child?.frame.intersects(parent?.frame ?? .null) == false)
    }

    @Test
    func equalDepthLabelsAreTakenInReadingOrder() {
        typealias Candidate = DebugOverlayLabelLayout.Candidate
        // Two outlines at the same corner: the first in reading order gets it.
        let frame = CGRect(x: 0, y: 0, width: 50, height: 9)
        let candidate = { (order: Int) in
            Candidate(
                outline: frame,
                depth: 1,
                order: order,
                fullText: "n\(order)",
                shortText: "n\(order)"
            )
        }

        let placed = DebugOverlayLabelLayout.place(
            [candidate(0), candidate(1)],
            canvas: CGSize(width: 50, height: 30),
            fontSize: 9
        )

        // The first takes the top-left corner; the second goes to a corner that is free.
        #expect(placed[0]?.frame.origin == .zero)
        #expect(placed[1]?.frame != placed[0]?.frame)
        #expect(placed[1]?.frame.intersects(placed[0]?.frame ?? .null) == false)
    }
#endif
