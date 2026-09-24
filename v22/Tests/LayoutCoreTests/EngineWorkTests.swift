import Foundation
import Testing

@testable import LayoutCore

// How much work a pass does, counted by the solver itself: unlike time, the counts are the
// same on every machine, so a change that makes nested layouts do more work fails here.

private struct Tree {
    var nextID: UInt64 = 0

    mutating func id() -> LayoutID {
        nextID += 1
        return LayoutID(nextID)
    }

    /// `depth` nested columns, each holding four fixed leaves beside the next level.
    mutating func chain(depth: Int) -> LayoutNode {
        var column = FlexStyle()
        column.direction = .column
        column.padding = Edges(all: 1)
        var leaf = FlexStyle()
        leaf.width = 6
        leaf.height = 3

        var level = LayoutNode(
            id: id(),
            style: column,
            children: [LayoutNode(id: id(), style: leaf)]
        )
        for _ in 0..<depth {
            var children = (0..<4).map { _ in LayoutNode(id: id(), style: leaf) }
            children.append(level)
            level = LayoutNode(id: id(), style: column, children: children)
        }
        return level
    }

    /// A column of cards: avatar, a growing column of two paragraphs, a button.
    mutating func cards(_ count: Int) -> LayoutNode {
        var list = FlexStyle()
        list.direction = .column
        list.rowGap = 8
        list.padding = Edges(all: 16)
        var card = FlexStyle()
        card.columnGap = 12
        card.padding = Edges(all: 12)
        card.alignItems = .center
        var texts = FlexStyle()
        texts.direction = .column
        texts.rowGap = 4
        texts.grow = 1
        var avatar = FlexStyle()
        avatar.width = 48
        avatar.height = 48
        var button = FlexStyle()
        button.width = 72
        button.height = 32

        let children = (0..<count).map { _ in
            LayoutNode(
                id: id(),
                style: card,
                children: [
                    LayoutNode(id: id(), style: avatar),
                    LayoutNode(
                        id: id(),
                        style: texts,
                        children: [
                            LayoutNode(id: id(), content: .measured(Words([40, 50, 60]))),
                            LayoutNode(
                                id: id(),
                                content: .measured(Words(Array(repeating: 30, count: 8)))
                            ),
                        ]
                    ),
                    LayoutNode(id: id(), style: button),
                ]
            )
        }
        return LayoutNode(id: id(), style: list, children: children)
    }
}

private struct Words: ContentMeasurer {
    let words: [Double]

    init(_ words: [Double]) {
        self.words = words
    }

    func minContentWidth() -> Double { words.max() ?? 0 }

    func maxContentWidth() -> Double { words.reduce(0, +) }

    func height(forWidth width: Double) -> Double {
        var lines = 1
        var used = 0.0
        for word in words {
            if used > 0 && used + word > width {
                lines += 1
                used = word
            } else {
                used += word
            }
        }
        return Double(lines) * 20
    }
}

private func statistics(_ root: LayoutNode, width: Double = 800) throws -> SolveStatistics {
    try FlexboxEngine.layout(root, size: LayoutSize(width: width, height: 100_000)).statistics
}

@Test
func nestedColumnsRunEachContainerTwiceAndSizeEachLeafOnce() throws {
    var tree = Tree()
    let depth = 16
    let work = try statistics(tree.chain(depth: depth))
    let containers = depth + 1
    let leaves = 4 * depth + 1

    // One run for the content size its parent needs, one for its layout.
    #expect(work.containerRuns <= 2 * containers)
    #expect(work.leafSizes <= leaves)
}

@Test
func workGrowsLinearlyWithNesting() throws {
    var tree = Tree()
    let shallow = try statistics(tree.chain(depth: 50))
    let deep = try statistics(tree.chain(depth: 100))

    #expect(Double(deep.requests) <= 2.1 * Double(shallow.requests))
    #expect(Double(deep.containerRuns) <= 2.1 * Double(shallow.containerRuns))
}

@Test
func cardsDoABoundedAmountOfWorkEach() throws {
    var tree = Tree()
    let count = 10
    let work = try statistics(tree.cards(count), width: 390)

    // Two containers and four leaves per card. The row overflows, so the growing column
    // also needs its minimum size.
    #expect(work.containerRuns <= 10 * count + 1)
    #expect(work.leafSizes <= 16 * count)
}

@Test
func fortyNestedContainersFitInOneMebibyteOfStack() {
    // A phone's main thread has about 1 MiB of stack and the solver recurses once per
    // nesting level; this holds even for an unoptimized build, whose frames are largest.
    var tree = Tree()
    let root = tree.chain(depth: 40)
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        _ = try? FlexboxEngine.layout(root, size: LayoutSize(width: 800, height: 100_000))
        finished.signal()
    }
    thread.stackSize = 1 << 20
    thread.start()
    finished.wait()
}
