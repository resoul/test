#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // R07 (`implementation-plan-6.md` plan 6): generalizes R06's prototype
    // (`AppKitNativeScrollEmbeddingPrototypeTests.swift`, which wrapped a whole `TrellisHostView`
    // as the sole `documentView` of an externally created `NSScrollView`) to a real `ScrollNode`
    // anywhere in the tree, backed by `NSScrollViewBacking`. Covers the R07 checklist's third
    // bullet: empty/short/long content, resize/insets, reveal — the AppKit half of
    // `UIKitScrollNodeEmbeddingTests.swift`'s shared contract.

    @MainActor
    private func waitForCommit(_ host: TrellisHostView, _ count: Int) async {
        for _ in 0..<10_000 where (host.hostBridge?.committedCount ?? 0) < count {
            await Task.yield()
        }
    }

    @MainActor
    private func makeHost(
        frame: NSRect = NSRect(x: 0, y: 0, width: 300, height: 400)
    ) -> TrellisHostView {
        TrellisHostView(frame: frame)
    }

    @Test
    @MainActor
    func test_scrollNode_embedsARealNSScrollViewAsADirectSubviewOfTheHost() async {
        let root = Node()
        root.style.flexDirection = .column
        root.style.width = 300
        root.style.height = 400
        let header = Node()
        header.style.width = 300
        header.style.height = 40
        let scroll = ScrollNode()
        scroll.style.flexDirection = .column
        scroll.style.width = 300
        scroll.style.height = 360
        let content = Node()
        content.style.width = 300
        content.style.height = 900
        scroll.addSubnode(content)
        root.addSubnode(header)
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        // Scenario 1, `r06-scroll-api-sketch.md` §10: `ScrollNode` nested at depth (not the sole
        // child of the host) still gets a real native scroll view.
        let scrollView = host.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView != nil)
        #expect(scrollView?.documentView?.frame.height == 900)
    }

    @Test
    @MainActor
    func test_scrollNode_emptyContentGivesTheNativeScrollViewAViewportSizedDocument() async {
        let root = Node()
        root.style.width = 300
        root.style.height = 400
        let scroll = ScrollNode()
        scroll.style.width = 300
        scroll.style.height = 400
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        let scrollView = host.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView?.documentView?.frame.size == NSSize(width: 300, height: 400))
    }

    @Test
    @MainActor
    func test_scrollNode_resizingTheHostUpdatesTheNativeViewportSize() async {
        // No explicit height on `root`/`scroll`: both stretch to fill the host's cross axis
        // (default `alignItems: .stretch`, single row-direction child) so a host resize
        // actually changes the committed viewport, instead of an explicit style value pinning
        // it regardless of the host's own bounds.
        let root = Node()
        root.style.width = 300
        let scroll = ScrollNode()
        scroll.style.width = 300
        let content = Node()
        content.style.width = 300
        content.style.height = 900
        scroll.addSubnode(content)
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        host.setFrameSize(NSSize(width: 300, height: 250))
        host.layout()
        await waitForCommit(host, 2)

        let scrollView = host.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView?.frame.height == 250)
    }

    @Test
    @MainActor
    func test_scrollCommand_revealScrollsTheRealNSScrollViewAndCompletes() async {
        let root = Node()
        root.style.flexDirection = .column
        root.style.width = 300
        root.style.height = 400
        let scroll = ScrollNode()
        scroll.style.flexDirection = .column
        scroll.style.width = 300
        scroll.style.height = 400
        let first = Node()
        first.style.width = 300
        first.style.height = 400
        let target = ControlNode()
        target.style.width = 300
        target.style.height = 400
        scroll.addSubnode(first)
        scroll.addSubnode(target)
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        guard let bridge = host.hostBridge, let targetFrame = target.calculatedFrame else {
            Issue.record("expected a mounted bridge and committed frame")
            return
        }

        var outcomes: [ScrollCommandOutcome] = []
        bridge.scroll(.reveal(frame: targetFrame, alignment: .start, animated: false), on: scroll) {
            outcomes.append($0)
        }

        #expect(outcomes.count == 1)
        guard case let .completed(state) = outcomes.first else {
            Issue.record("expected .completed")
            return
        }
        #expect(state.offset.y == 400)

        let scrollView = host.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView?.contentView.bounds.origin.y == 400)
    }

    @Test
    @MainActor
    func test_scrollNode_contentInsetsAreAppliedToTheRealNSScrollView() async {
        let root = Node()
        root.style.width = 300
        root.style.height = 400
        let scroll = ScrollNode()
        scroll.style.width = 300
        scroll.style.height = 400
        scroll.configuration.insetsSafeArea = false
        scroll.configuration.contentInsets = DirectionalEdgeInsets(
            top: 10,
            leading: 5,
            bottom: 20,
            trailing: 5
        )
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        let scrollView = host.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView?.contentInsets.top == 10)
        #expect(scrollView?.contentInsets.bottom == 20)
        #expect(scrollView?.contentInsets.left == 5)
        #expect(scrollView?.contentInsets.right == 5)
    }

    @Test
    @MainActor
    func test_scrollNode_shortContentDoesNotProduceAScrollableExtent() async {
        let root = Node()
        root.style.width = 300
        root.style.height = 400
        let scroll = ScrollNode()
        scroll.style.flexDirection = .column
        scroll.style.width = 300
        scroll.style.height = 400
        let short = Node()
        short.style.width = 300
        short.style.height = 60
        scroll.addSubnode(short)
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        let scrollView = host.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView?.documentView?.frame.height == 400)
    }
#endif
