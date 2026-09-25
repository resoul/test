import Testing

@testable import LayoutCore

@Test
func cancelledPassThrowsAndReturnsNothing() {
    let root = LayoutNode(
        id: LayoutID(0),
        children: [LayoutNode(id: LayoutID(1), content: .size(width: 10, height: 10))]
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
            LayoutNode(id: LayoutID(1), content: .size(width: 20, height: 20)),
            LayoutNode(id: LayoutID(2), content: .size(width: 30, height: 10)),
        ]
    )

    let size = try FlexboxEngine.measure(root, width: .maxContent, height: .maxContent)

    #expect(size == LayoutSize(width: 64, height: 30))
}

@Test
func widthVariantsChosenWithoutAWidthAreReported() throws {
    // `inner` changes direction from 100 points on. In a row its parent sizes itself to its
    // content, so there is no width to choose by; in a column its parent is stretched to the
    // root's width.
    var wide = FlexStyle()
    wide.direction = .column
    func tree(_ direction: FlexDirection) -> LayoutNode {
        var style = FlexStyle()
        style.direction = direction
        return LayoutNode(
            id: LayoutID(0),
            style: style,
            children: [
                LayoutNode(
                    id: LayoutID(1),
                    children: [
                        LayoutNode(
                            id: LayoutID(2),
                            children: [
                                LayoutNode(id: LayoutID(3), content: .size(width: 10, height: 10))
                            ],
                            variants: [StyleVariant(minWidth: 100, style: wide)]
                        )
                    ]
                )
            ]
        )
    }
    let size = LayoutSize(width: 300, height: 100)

    #expect(try FlexboxEngine.layout(tree(.row), size: size).variantsWithoutWidth == [LayoutID(2)])
    #expect(try FlexboxEngine.layout(tree(.column), size: size).variantsWithoutWidth.isEmpty)
}

@Test
func aTraceRecordsOnlyWhatWasAskedFor() throws {
    let root = LayoutNode(
        id: LayoutID(0),
        children: [
            LayoutNode(id: LayoutID(1), content: .size(width: 10, height: 10)),
            LayoutNode(id: LayoutID(2), content: .size(width: 20, height: 10)),
        ]
    )
    let size = LayoutSize(width: 100, height: 50)

    #expect(try FlexboxEngine.layout(root, size: size).trace.isEmpty)

    let context = LayoutContext(trace: LayoutTraceRequest(ids: [LayoutID(2)]))
    let trace = try FlexboxEngine.layout(root, size: size, context: context).trace
    #expect(trace.allSatisfy { $0.id == LayoutID(2) })
    #expect(trace.contains { if case .measured = $0 { true } else { false } })
    #expect(
        trace.last == .placed(LayoutID(2), frame: LayoutRect(x: 10, y: 0, width: 20, height: 50))
    )

    let places = LayoutContext(trace: LayoutTraceRequest(areas: [.place]))
    let placed = try FlexboxEngine.layout(root, size: size, context: places).trace
    #expect(placed.map(\.id) == [LayoutID(0), LayoutID(1), LayoutID(2)])
}
