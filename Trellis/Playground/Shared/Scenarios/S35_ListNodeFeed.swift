import Foundation
import TrellisCore

/// R12a consumer: a `ListNode` feed of text posts with variable heights. The first 20 posts and
/// every next 20 come from a slow fake API through the loader hooks; the next page is asked for
/// two viewport lengths before the end. New posts arrive on top every few seconds, like a live
/// feed, and must not move the post being read — also while the user drags.
///
/// The status line (accessibility identifier `r12a-status`) reports loaded posts, requests and
/// the largest drift of the read post measured against the native scroll offset around each
/// arrival; `--r12a-test` makes arrivals every second so a UI test can hold a drag through them.
@MainActor enum S35 {
    struct Post: Sendable, Equatable {
        let title: String
        let body: String
    }

    @MainActor
    final class PostProvider: ItemProvider {
        func makeNode(for item: Post, id: Int) -> PostNode { PostNode(item) }
        func update(_ node: PostNode, with item: Post, id: Int) { node.show(item) }
    }

    final class PostNode: Node {
        private let title = TextNode(
            text: "",
            textStyle: TextStyle(pointSize: 16, weight: .semibold, color: Palette.theme.colors.text)
        )
        private let body = TextNode(text: "", textStyle: TextStyle(pointSize: 14))

        init(_ post: Post) {
            super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 10))
            style {
                $0.flexDirection = .column
                $0.gap = 6
                $0.padding = DirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
                $0.margin = DirectionalEdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0)
            }
            addSubnode(title)
            addSubnode(body)
            show(post)
        }

        func show(_ post: Post) {
            title.text = post.title
            body.text = post.body
            accessibility.label = post.title
        }
    }

    /// The model: owns the source, calls a slow API and keeps its own IDs.
    @MainActor
    final class FeedModel {
        let source = StateSubject(CollectionSnapshot<Int, Post>.initial(dataKey: "feed"))
        weak var loader: CollectionLoader<Int, Post>?
        private(set) var requestCount = 0
        private var newestID = 0

        static let sentences = [
            "Morning light over the harbour.",
            "The bakery on the corner opened again after the summer, and the queue reached the "
                + "bridge before seven.",
            "A long thread about keeping a garden alive through a dry month: mulch early, water "
                + "late, and accept that some plants will not make it.",
            "Short one.",
            "Notes from the reading group: we argued about the ending for an hour and agreed "
                + "only that the middle chapters were the best part of the book.",
        ]

        static func post(_ id: Int) -> Post {
            let body = (0...(abs(id) % 3)).map { sentences[(abs(id) + $0) % sentences.count] }
            return Post(
                title: id < 0 ? "New post \(-id)" : "Post \(id)",
                body: body.joined(separator: " ")
            )
        }

        func load(_ context: CollectionLoadContext) async -> CollectionLoadResult {
            requestCount += 1
            try? await Task.sleep(for: .milliseconds(800))
            guard let loader, loader.isCurrent(context) else { return .completed }

            let current = source.current
            let start = current.items.filter { $0.id >= 0 }.count
            let page = (start..<start + (context.pageSize ?? 20)).map {
                CollectionItem(id: $0, value: Self.post($0))
            }
            source.send(
                CollectionSnapshot(
                    dataKey: context.dataKey,
                    revision: current.revision + 1,
                    items: current.items + page
                )
            )
            return .completed
        }

        func arrive(_ count: Int) {
            let current = source.current
            guard current.count > 0 else { return }

            let items = (0..<count).map { _ -> CollectionItem<Int, Post> in
                newestID -= 1
                return CollectionItem(id: newestID, value: Self.post(newestID))
            }
            source.send(
                CollectionSnapshot(
                    dataKey: current.dataKey,
                    revision: current.revision + 1,
                    items: items.reversed() + current.items
                )
            )
        }
    }

    /// Measures, around each arrival, how far the read post moved beyond the list's own anchor
    /// shifts (`drift`, independent of user movement) and, while a drag is held still, how far
    /// the native offset moved beyond those shifts (`native`, zero if UIKit/AppKit kept them).
    @MainActor
    final class DriftProbe {
        weak var list: ListNode<PostProvider>?
        private var pending: Sample?
        private(set) var drift = 0.0
        private(set) var native = 0.0
        private(set) var checks = 0
        private(set) var heldChecks = 0

        private struct Sample {
            let id: Int
            let extentOffset: Double
            let applied: Double
            let nativeOffset: Double
            let held: Bool
        }

        var isMeasuring: Bool { pending != nil }

        func before(held: Bool) {
            guard let list, let sample = sample(of: nil, in: list, held: held) else { return }

            pending = sample
        }

        func after(held: Bool) {
            guard let list, let old = pending,
                let now = sample(of: old.id, in: list, held: held)
            else {
                pending = nil
                return
            }

            let shift = now.applied - old.applied
            drift = max(drift, abs((now.extentOffset - old.extentOffset) - shift))
            checks += 1
            if old.held, now.held {
                native = max(native, abs((now.nativeOffset - old.nativeOffset) - shift))
                heldChecks += 1
            }
            pending = nil
        }

        private func sample(of id: Int?, in list: ListNode<PostProvider>, held: Bool) -> Sample? {
            let offset = list.scrollNode.state.offset.y
            let window = list.window
            guard
                let index = id.flatMap(window.snapshot.index(of:))
                    ?? window.extents.index(at: offset),
                index < window.snapshot.count
            else { return nil }

            return Sample(
                id: window.snapshot.items[index].id,
                extentOffset: window.extents.offset(of: index),
                applied: list.appliedOffsetShift,
                nativeOffset: offset,
                held: held
            )
        }
    }

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let testing = ProcessInfo.processInfo.arguments.contains("--r12a-test")
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.flexDirection = .column; $0.gap = 8
        }

        let status = TextNode(text: "Loading…", textStyle: TextStyle(pointSize: 13))
        status.accessibility.identifier = "r12a-status"
        status.accessibility.label = "List status"
        // A list's flex basis is its whole content; without this the column would shrink the
        // status line below its text (Trellis has no CSS `min-height: auto`).
        status.style.flexShrink = 0
        root.addSubnode(status)

        let model = FeedModel()
        var listStyle = LayoutStyle()
        listStyle.width = .fraction(1)
        listStyle.flexGrow = 1
        listStyle.flexShrink = 1
        let list = ListNode(
            source: model.source,
            provider: PostProvider(),
            estimatedLength: 90,
            pagination: PaginationPolicy(pageSize: 20),
            style: listStyle
        )
        // The list's loader owns the model through its hooks; the model keeps the loader weakly.
        list.loader.onLoad = { await model.load($0) }
        list.loader.onLoadMore = { await model.load($0) }
        model.loader = list.loader
        root.addSubnode(list)

        let probe = DriftProbe()
        probe.list = list
        let report: @MainActor () -> Void = { [weak list, weak model, weak status] in
            guard let list, let model, let status else { return }

            let posts = list.window.snapshot.count
            let text =
                "posts=\(posts) requests=\(model.requestCount) "
                + "drift=\(String(format: "%.1f", probe.drift)) "
                + "native=\(String(format: "%.1f", probe.native)) checks=\(probe.checks) "
                + "held=\(probe.heldChecks) live=\(list.window.materializedIDs.count) "
                + "offset=\(Int(list.window.offset)) end=\(Int(list.window.extents.totalExtent))"
            status.text = text
            status.accessibility.value = text
        }
        list.events.onVisibleItemsChange = { _ in report() }

        let session = ScenarioSession()
        if testing {
            // Arrivals only while a drag is held still, so the native check has no user motion.
            Task { @MainActor [weak list, weak model] in
                var lastOffset = -1.0
                var stillSince = ContinuousClock.now
                var lastArrival = ContinuousClock.now
                while let currentList = list, let currentModel = model {
                    try? await Task.sleep(for: .milliseconds(50))
                    let state = currentList.scrollNode.state
                    let now = ContinuousClock.now
                    if state.offset.y != lastOffset {
                        lastOffset = state.offset.y
                        stillSince = now
                    }
                    let held = state.phase == .dragging && now - stillSince > .milliseconds(300)
                    report()
                    if probe.isMeasuring {
                        if now - lastArrival > .milliseconds(400) {
                            probe.after(held: state.phase == .dragging)
                            report()
                        }
                    } else if held, now - lastArrival > .seconds(1) {
                        probe.before(held: true)
                        currentModel.arrive(2)
                        lastArrival = now
                    }
                }
            }
        } else {
            var tick = 0
            session.start { [weak model] in
                tick += 1
                guard tick.isMultiple(of: 3) else {
                    report()
                    return
                }

                probe.before(held: false)
                model?.arrive(2)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    probe.after(held: false)
                    report()
                }
            }
        }

        return ScenarioNodes.instance(
            .s35,
            root: root,
            inputs: "ListNode, 20 + 20 posts from a slow API, 2 new posts on top periodically",
            expected: "the read post keeps its place when posts arrive; next page before the end",
            paths: ["status", "list"],
            session: session
        )
    }
}
