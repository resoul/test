#if canImport(UIKit)
    import UIKit
    import Testing

    @testable import TrellisCore
    @testable import TrellisRender
    @testable import TrellisUIKit

    // R07 (`implementation-plan-6.md` plan 6): generalizes R06's prototype
    // (`UIKitNativeScrollEmbeddingPrototypeTests.swift`, which wrapped a whole `TrellisHostView`
    // as the sole subview of an externally created `UIScrollView`) to a real `ScrollNode`
    // anywhere in the tree, backed by `UIScrollViewBacking`. Covers the R07 checklist's third
    // bullet: empty/short/long content, resize/insets, reveal, and the embedding-specific parts
    // `ScrollNodeHitTestTests.swift`'s fake backing cannot exercise (a real `UIScrollView`
    // subview, real `contentInset`, real `setContentOffset(_:animated:)`).

    @MainActor
    private func waitForCommit(_ host: TrellisHostView, _ count: Int) async {
        for _ in 0..<10_000 where (host.hostBridge?.committedCount ?? 0) < count {
            await Task.yield()
        }
    }

    @MainActor
    private func makeHost(frame: CGRect = CGRect(x: 0, y: 0, width: 300, height: 400))
        -> TrellisHostView
    {
        TrellisHostView(frame: frame)
    }

    @Test
    @MainActor
    func test_scrollNode_embedsARealUIScrollViewAsADirectSubviewOfTheHost() async {
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

        // Scenario 1, `r06-scroll-api-sketch.md` §10: `ScrollNode` nested at depth (not the
        // sole child of the host) still gets a real native scroll view — the depth-2 position
        // (`root` → `scroll`, with `header` as an unrelated sibling) is what generalizes R06's
        // prototype, which only ever embedded the whole host.
        let scrollView = host.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scrollView != nil)
        #expect(scrollView?.contentSize.height == 900)
    }

    @Test
    @MainActor
    func test_scrollNode_emptyContentGivesTheNativeScrollViewAViewportSizedContentSize() async {
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

        let scrollView = host.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scrollView?.contentSize == CGSize(width: 300, height: 400))
    }

    @Test
    @MainActor
    func test_scrollNode_resizingTheHostUpdatesTheNativeViewportSize() async {
        let root = Node()
        root.style.width = 300
        root.style.height = 400
        let scroll = ScrollNode()
        scroll.style.width = 300
        scroll.style.height = 400
        let content = Node()
        content.style.width = 300
        content.style.height = 900
        scroll.addSubnode(content)
        root.addSubnode(scroll)

        let host = makeHost()
        host.attach(root: root)
        await waitForCommit(host, 1)

        host.frame = CGRect(x: 0, y: 0, width: 300, height: 250)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        await waitForCommit(host, 2)

        let scrollView = host.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scrollView?.frame.height == 250)
    }

    @Test
    @MainActor
    func test_scrollCommand_revealScrollsTheRealUIScrollViewAndCompletes() async {
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

        let scrollView = host.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scrollView?.contentOffset.y == 400)
    }

    @Test
    @MainActor
    func test_scrollNode_contentInsetsAreAppliedToTheRealUIScrollView() async {
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

        let scrollView = host.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scrollView?.contentInset.top == 10)
        #expect(scrollView?.contentInset.bottom == 20)
        #expect(scrollView?.contentInset.left == 5)
        #expect(scrollView?.contentInset.right == 5)
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

        let scrollView = host.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scrollView?.contentSize.height == 400)
    }
#endif
