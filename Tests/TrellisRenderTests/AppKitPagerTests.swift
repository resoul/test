#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // R13 (ADR 0036): `PagerNode` inside a real `TrellisHostView`. The pager's own
    // `NSScrollView` hosts the pages, so a page's native scroll view is nested in it (clipped
    // and moved with it); a timed settle reports the offset on screen while it runs.

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() {
            await Task.yield()
        }
    }

    @Test @MainActor
    func r13_appKitPagerNestsPageScrollViewsAndReportsThePresentedOffset() async throws {
        let feed = StateSubject(
            CollectionSnapshot(
                dataKey: "feed",
                revision: 1,
                items: (0..<50).map { CollectionItem(id: $0, value: $0) }
            )
        )
        let provider = ClosureItemProvider<Int, Int, Node>(
            make: { _, _ in
                let node = Node()
                node.style.height = 40
                return node
            },
            update: { _, _, _ in }
        )
        var style = LayoutStyle()
        style.width = 300
        style.height = 400
        let pager = PagerNode(
            tabs: [
                Tab(id: "a", title: "A") { Node() },
                Tab(id: "feed", title: "Feed") { ListNode(source: feed, provider: provider) },
            ],
            style: style
        )
        pager.settleAnimation = .linear(duration: .milliseconds(500))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.attach(root: pager)
        let bridge = try #require(host.hostBridge)
        await waitUntil { pager.mountedIDs.count == 2 && bridge.committedCount > 2 }
        for _ in 0..<2_000 { await Task.yield() }

        // The pager's scroll view is the host's; the feed's is nested inside it.
        let outer = try #require(host.subviews.compactMap { $0 as? NSScrollView }.first)
        let nested = outer.documentView?.subviews.compactMap { $0 as? NSScrollView } ?? []
        #expect(nested.count == 1)
        #expect(host.subviews.compactMap { $0 as? NSScrollView }.count == 1)
        #expect(nested.first?.frame.origin.x == 300)

        let scroll = try #require(pager.subnodes.first as? ScrollNode)
        pager.select("feed")
        try await Task.sleep(for: .milliseconds(200))
        let presented = try #require(bridge.presentedScrollOffset(of: scroll))
        #expect(presented.x > 1 && presented.x < 299)
        try await Task.sleep(for: .milliseconds(600))
        #expect(bridge.presentedScrollOffset(of: scroll)?.x == 300)
        #expect(outer.contentView.bounds.origin.x == 300)
        host.detach()
    }
#endif
