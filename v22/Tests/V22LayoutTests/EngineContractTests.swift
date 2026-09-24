import Testing

@testable import V22Layout

@Test
func cancelledPassThrowsAndReturnsNothing() {
    let root = LayoutNode(
        id: LayoutID(0),
        children: [LayoutNode(id: LayoutID(1), content: LayoutSize(width: 10, height: 10))]
    )
    let cancelled = LayoutContext(isCancelled: { true })

    #expect(throws: LayoutCancelled.self) {
        try FlexboxEngine.layout(
            root,
            size: LayoutSize(width: 100, height: 100),
            context: cancelled
        )
    }
    #expect(throws: LayoutCancelled.self) {
        try FlexboxEngine.measure(root, width: .maxContent, height: .maxContent, context: cancelled)
    }
}

@Test
func cancellingTheSolvingTaskCancelsThePass() async {
    let children = (1...1000).map { LayoutNode(id: LayoutID(UInt64($0))) }
    let root = LayoutNode(id: LayoutID(0), children: children)

    let task = Task { () -> Bool in
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try FlexboxEngine.layout(
                root,
                size: LayoutSize(width: 100, height: 100),
                context: .currentTask
            )
            return false
        } catch {
            return error is LayoutCancelled
        }
    }

    #expect(await task.value)
}

@Test
func duplicateIdentitiesAreReportedNotHidden() throws {
    let root = LayoutNode(
        id: LayoutID(0),
        children: [LayoutNode(id: LayoutID(1)), LayoutNode(id: LayoutID(1))]
    )

    let result = try FlexboxEngine.layout(root, size: LayoutSize(width: 100, height: 100))

    #expect(result.duplicateIDs == [LayoutID(1)])
    #expect(result.frames.count == 3)
}

@Test
func measureReturnsContentSizeOfAnAutoSizedTree() throws {
    var style = FlexStyle()
    style.padding = Edges(all: 5)
    style.columnGap = 4
    let root = LayoutNode(
        id: LayoutID(0),
        style: style,
        children: [
            LayoutNode(id: LayoutID(1), content: LayoutSize(width: 20, height: 20)),
            LayoutNode(id: LayoutID(2), content: LayoutSize(width: 30, height: 10)),
        ]
    )

    let size = try FlexboxEngine.measure(root, width: .maxContent, height: .maxContent)

    #expect(size == LayoutSize(width: 64, height: 30))
}
