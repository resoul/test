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

/// Runs `body` on a thread of its own with `stackSize` bytes of stack. The solver recurses
/// once per nesting level, and the test runner's threads may have as little as 512 KiB —
/// too little for deep trees in an unoptimized build.
private func onThread<Result: Sendable>(
    stackSize: Int = 8 << 20,
    _ body: @escaping @Sendable () throws -> Result
) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Swift.Result { try body() }) }
        thread.stackSize = stackSize
        thread.start()
    }
}

private func statistics(_ root: LayoutNode, width: Double = 800) async throws -> SolveStatistics {
    try await onThread {
        try FlexboxEngine.layout(root, size: LayoutSize(width: width, height: 100_000)).statistics
    }
}

@Test
func nestedColumnsRunEachContainerTwiceAndSizeEachLeafOnce() async throws {
    var tree = Tree()
    let depth = 16
    let work = try await statistics(tree.chain(depth: depth))
    let containers = depth + 1
    let leaves = 4 * depth + 1

    // One run for the content size its parent needs, one for its layout.
    #expect(work.containerRuns <= 2 * containers)
    #expect(work.leafSizes <= leaves)
}

@Test
func workGrowsLinearlyWithNesting() async throws {
    var tree = Tree()
    let shallow = try await statistics(tree.chain(depth: 50))
    let deep = try await statistics(tree.chain(depth: 100))

    #expect(Double(deep.requests) <= 2.1 * Double(shallow.requests))
    #expect(Double(deep.containerRuns) <= 2.1 * Double(shallow.containerRuns))
}

@Test
func cardsDoABoundedAmountOfWorkEach() async throws {
    var tree = Tree()
    let count = 10
    let work = try await statistics(tree.cards(count), width: 390)

    // Two containers and four leaves per card. The row overflows, so the growing column
    // also needs its minimum size.
    #expect(work.containerRuns <= 10 * count + 1)
    #expect(work.leafSizes <= 16 * count)
}

@Test
func fortyNestedContainersFitInOneMebibyteOfStack() async throws {
    // A phone's main thread has about 1 MiB of stack and the solver recurses once per
    // nesting level; this holds even for an unoptimized build, whose frames are largest.
    var tree = Tree()
    let root = tree.chain(depth: 40)
    _ = try await onThread(stackSize: 1 << 20) {
        try FlexboxEngine.layout(root, size: LayoutSize(width: 800, height: 100_000)).frames.count
    }
}

@Test
func aTreeTooDeepForItsBudgetThrowsRatherThanCrashing() async throws {
    // A 256 KiB thread holds only a few dozen levels in an unoptimized build: without a
    // budget, 300 levels would crash it.
    var tree = Tree()
    let deep = tree.chain(depth: 300)
    let shallow = tree.chain(depth: 3)
    let size = LayoutSize(width: 800, height: 100_000)

    let (deepThrew, shallowFrames) = try await onThread(stackSize: 256 << 10) {
        let context = LayoutContext(stackBudget: LayoutContext.currentThreadStackBudget)
        var threw = false
        do {
            _ = try FlexboxEngine.layout(deep, size: size, context: context)
        } catch is LayoutStackExhausted {
            threw = true
        }
        return (threw, try FlexboxEngine.layout(shallow, size: size, context: context).frames.count)
    }

    #expect(deepThrew)
    #expect(shallowFrames == 2 + 5 * 3)
}

@Test
func aVeryDeepTreeIsReleasedLevelByLevel() async throws {
    // Released at once, a hundred thousand nested levels would take the runtime a frame per
    // level — far more than the 256 KiB this thread has.
    let released = try await onThread(stackSize: 256 << 10) {
        var tree = LayoutNode(id: LayoutID(0))
        for index in 1...100_000 {
            tree = LayoutNode(id: LayoutID(UInt64(index)), children: [tree])
        }
        LayoutNode.dismantle(consume tree)
        return true
    }

    #expect(released)
}
