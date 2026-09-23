#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // R12a (ADR 0032): `ListNode` inside a real `TrellisHostView` with a real `NSScrollView`
    // backing. A prepend after the user scrolled keeps the row being read in place by shifting
    // the clip view in the same geometry commit.

    private struct Line: Sendable, Equatable {
        let height: Double
    }

    @MainActor
    private struct LineProvider: ItemProvider {
        func makeNode(for item: Line, id: Int) -> Node {
            let node = Node()
            node.style.height = .points(item.height)
            return node
        }

        func update(_ node: Node, with item: Line, id: Int) {
            node.style.height = .points(item.height)
        }
    }

    private func lines(_ ids: [Int]) -> [CollectionItem<Int, Line>] {
        ids.map { CollectionItem(id: $0, value: Line(height: Double(30 + ($0 * 37 & 0x3F)))) }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() {
            await Task.yield()
        }
    }

    @MainActor
    private func settle(_ bridge: NodeHostBridge) async {
        for _ in 0..<5 {
            let committed = bridge.committedCount
            for _ in 0..<500 where bridge.committedCount == committed {
                await Task.yield()
            }
            if bridge.committedCount == committed { return }
        }
    }

    @Test @MainActor
    func r12a_appKitPrependAfterUserScrollShiftsTheClipViewInTheSameCommit() async throws {
        let source = StateSubject(
            CollectionSnapshot(dataKey: "feed", revision: 1, items: lines(Array(0..<60)))
        )
        var style = LayoutStyle()
        style.width = 300
        style.height = 400
        let list = ListNode(source: source, provider: LineProvider(), style: style)
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        host.attach(root: list)
        let bridge = try #require(host.hostBridge)
        await waitUntil { bridge.committedCount > 0 }
        await settle(bridge)

        let native = try #require(host.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(Double(native.documentView?.frame.height ?? 0) == list.window.extents.totalExtent)
        native.contentView.scroll(to: NSPoint(x: 0, y: 700))
        native.reflectScrolledClipView(native.contentView)
        await settle(bridge)
        #expect(list.window.offset == 700)
        let anchorIndex = try #require(list.window.extents.index(at: 700))
        let anchorID = list.window.snapshot.items[anchorIndex].id
        let before = list.window.extents.offset(of: anchorIndex) - 700

        source.send(
            CollectionSnapshot(
                dataKey: "feed",
                revision: 2,
                items: lines(Array(-4..<0) + Array(0..<60))
            )
        )
        await waitUntil { list.window.snapshot.revision == 2 }
        await settle(bridge)

        let clipY = Double(native.contentView.bounds.origin.y)
        let index = try #require(list.window.snapshot.index(of: anchorID))
        #expect(clipY > 700)
        #expect(clipY == list.window.offset)
        #expect(abs(list.window.extents.offset(of: index) - clipY - before) <= 0.5)
        #expect(Double(native.documentView?.frame.height ?? 0) == list.window.extents.totalExtent)
        host.detach()
    }
#endif
