#if canImport(UIKit)
    import FlexEngine
    import LayoutCore
    import Nodes
    import NodesRender
    import NodesUIKit
    import ThemeCore
    import UIKit

    @MainActor
    final class NodeFeedController: FeedController {
        private lazy var page = ProfileFeedNode(session: session)
        private lazy var nodeView = NodeView(root: page)
        private var displayedRevision = -1

        override func viewDidLoad() {
            super.viewDidLoad()
            nodeView.translatesAutoresizingMaskIntoConstraints = false
            nodeView.accessibilityIdentifier = "node-feed"
            nodeView.host.solvesInBackground = true
            nodeView.host.drawingMode = .asynchronous
            nodeView.host.contentRangePolicy = ContentRangePolicy()
            view.addSubview(nodeView)
            NSLayoutConstraint.activate([
                nodeView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                nodeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                nodeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                nodeView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
            contentChanged()
        }

        override func contentChanged() {
            super.contentChanged()
            guard isViewLoaded else { return }
            let reset = displayedRevision != session.revision
            displayedRevision = session.revision
            page.show(reset: reset)
        }
    }

    @MainActor
    private final class ProfileFeedNode: Node {
        let scroll = Scroll(.vertical)
        private let session: ComparisonSession
        private let pipeline: ImagePipeline
        private let rows: NodeCache<Int, PostCardNode>
        private lazy var header = ProfileHeaderNode(posts: session.posts, pipeline: pipeline)
        private let count = Text("", style: FeedStyle.text(17, weight: .semibold))
        private lazy var table: Table<FeedPost> = {
            let pipeline = pipeline
            let rows = rows
            let table = Table<FeedPost>(
                scrolls: false,
                estimatedRowHeight: 560,
                preparation: ItemPreparationPolicy(
                    maximumConcurrentTasks: 2,
                    maximumQueuedItems: 16,
                    maximumRetainedItems: 48
                ),
                key: { $0.revision },
                prepare: { post, context in
                    try await FeedPlan.prepare(post, context: context, pipeline: pipeline)
                },
                row: { [weak session] post, state in
                    rows[post.id].show(
                        post,
                        state: state,
                        saved: session?.saved.contains(post.id) ?? false
                    )
                }
            )
            table.onSelect = { [weak session] post in session?.toggleSaved(post.id) }
            return table
        }()
        private lazy var body = FeedBody(header: header, count: count, table: table)

        init(session: ComparisonSession) {
            self.session = session
            let pipeline = ImagePipeline()
            self.pipeline = pipeline
            rows = NodeCache(reserve: 8) { [weak session] id in
                PostCardNode(pipeline: pipeline) { session?.toggleSaved(id) }
            }
            super.init()
            appearance.background = FeedStyle.background
            scroll.content = body
        }
        func show(reset: Bool) {
            count.text = "Лента · \(session.count) записей"
            if reset {
                table.sections = [TableSection(id: "feed", items: session.posts)]
                scroll.contentOffset = .zero
            } else {
                table.setNeedsLayout()
            }
            setNeedsLayout()
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll.flex(grow: 1) }
        }
    }

    @MainActor
    private final class FeedBody: Node {
        let header: Node
        let count: Node
        let table: Node
        init(header: Node, count: Node, table: Node) {
            self.header = header; self.count = count; self.table = table
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                header.flex(shrink: 0)
                count.padding(top: 22, leading: 20, bottom: 8, trailing: 20)
                table.flex(shrink: 0)
            }
        }
    }

    @MainActor
    private final class PostCardNode: Node {
        private let author = Text("Анна Лесная", style: FeedStyle.text(13, weight: .semibold))
        private let date = Text("", style: FeedStyle.text(11, color: FeedStyle.muted))
        private let avatar = InitialsNode(
            size: 12,
            background: FeedStyle.background,
            foreground: FeedStyle.ink
        )
        private let title = Text("", style: FeedStyle.text(21, weight: .semibold))
        private let body = Text("", style: FeedStyle.text(FeedStyle.bodySize))
        private let place = Text("", style: FeedStyle.text(12, color: FeedStyle.muted))
        private let likes = Text("", style: FeedStyle.text(13, color: FeedStyle.muted))
        private let save = Text(
            "Сохранить",
            style: FeedStyle.text(13, weight: .medium, color: FeedStyle.accent)
        )
        private let photo: NodesRender.Image
        private let card = SpecNode()
        private var item: FeedPost?
        private var planIsReady = false
        private let placeholder = Node()

        init(pipeline: ImagePipeline, save: @escaping @MainActor () -> Void) {
            photo = NodesRender.Image(
                contentMode: .fill,
                placeholder: ImagePlaceholder(
                    color: FeedStyle.background,
                    size: LayoutSize(width: 1280, height: 800)
                ),
                pipeline: pipeline,
                loadingMode: .demandDriven
            )
            super.init()
            appearance.background = FeedStyle.background
            card.appearance.background = .white
            card.appearance.cornerRadius = 20
            card.appearance.clipsContent = true
            avatar.appearance.background = FeedStyle.background
            avatar.appearance.cornerRadius = 17
            body.style.lineSpacing = 3
            self.save.onTap = save
            self.save.minimumHitSize = LayoutSize(width: 80, height: 44)
            photo.accessibility.label = "Иллюстрация маршрута"
            card.make = { [weak self] in self?.cardLayout() }
            placeholder.appearance.background = FeedStyle.background
            placeholder.appearance.cornerRadius = 8
            placeholder.accessibility.label = "Подготовка записи"
        }

        func show(_ post: FeedPost, state: PreparedItemState<FeedPlan>, saved: Bool) -> PostCardNode
        {
            let ready: FeedPost
            let isReady: Bool
            if case let .ready(plan) = state {
                ready = plan.value.post; isReady = true
            } else {
                ready = post; isReady = false
            }
            if planIsReady != isReady { planIsReady = isReady; setNeedsLayout() }
            if item?.id != ready.id || item?.revision != ready.revision {
                item = ready
                title.text = ready.title
                title.accessibility.label = ready.accessibilityTitle
                date.text = ready.date
                body.text = ready.body
                place.text = "↗ " + ready.place
                likes.text = "♡ \(ready.likes)     ◌ \(12 + ready.id % 38)"
                photo.source = .url(ready.imageURL)
            }
            save.text = saved ? "Сохранено ✓" : "Сохранить"
            return self
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                card.width(.fraction(1)).limits(minWidth: .points(0))
            }.padding(top: 8, leading: 16, bottom: 8, trailing: 16)
                .width(.fraction(1)).limits(minWidth: .points(0))
        }

        private func cardLayout() -> LayoutSpec {
            FlexContainer(.column) {
                FlexContainer(.column) {
                    FlexContainer(.row) {
                        avatar.size(width: 34, height: 34)
                        FlexContainer(.column) {
                            author; date
                        }.gap(3)
                    }.gap(10).alignItems(.center)
                    title
                    if planIsReady { body; place } else { placeholder.height(.points(100)) }
                }.gap(12).padding(16)
                photo.width(.fraction(1)).aspectRatio(FeedStyle.photoRatio)
                    .limits(minWidth: .points(0), maxWidth: .fraction(1))
                FlexContainer(.row) {
                    likes.flex(grow: 1)
                    save
                }.alignItems(.center).limits(minHeight: .points(32))
                    .padding(top: 12, leading: 16, bottom: 12, trailing: 16)
            }
        }
    }

    @MainActor
    private final class InitialsNode: Node {
        private let text: Text
        init(size: Double, background: Color, foreground: Color) {
            text = Text("АЛ", style: FeedStyle.text(size, weight: .semibold, color: foreground))
            super.init()
            appearance.background = background
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { text }.justifyContent(.center).alignItems(.center)
        }
    }

    @MainActor
    private final class SpecNode: Node {
        var make: (@MainActor () -> LayoutSpec?)?
        override func layoutSpec() -> LayoutSpec? { make?() }
    }

    @MainActor
    private final class ProfileHeaderNode: Node {
        private let initials = InitialsNode(
            size: 22,
            background: FeedStyle.accent,
            foreground: .white
        )
        private let name = Text("Анна Лесная", style: FeedStyle.text(24, weight: .bold))
        private let location = Text(
            "Тбилиси, Грузия · @anna.outside",
            style: FeedStyle.text(12, color: FeedStyle.muted)
        )
        private let bio = Text(
            "Собираю места, в которые хочется вернуться.\nМаршруты, свет и немного тишины.",
            style: FeedStyle.text(14, color: FeedStyle.muted)
        )
        private let stats = Text(
            "48 поездок     126 мест     8,4 тыс. друзей",
            style: FeedStyle.text(13, weight: .medium)
        )
        private let subtitle = Text(
            "Избранные маршруты",
            style: FeedStyle.text(17, weight: .semibold)
        )
        private let albums = Scroll(.horizontal)

        init(posts: [FeedPost], pipeline: ImagePipeline) {
            super.init()
            initials.appearance.background = FeedStyle.accent
            initials.appearance.cornerRadius = 30
            let strip = AlbumStrip(posts: Array(posts.prefix(6)), pipeline: pipeline)
            albums.content = strip
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                FlexContainer(.column) {
                    FlexContainer(.row) {
                        initials.size(width: 60, height: 60)
                        FlexContainer(.column) {
                            name; location
                        }.gap(5).flex(grow: 1, shrink: 1)
                    }.gap(14).alignItems(.center)
                    bio
                    stats
                    subtitle
                }.gap(14).padding(top: 16, leading: 16, bottom: 0, trailing: 16)
                albums.height(.points(126))
            }.gap(14)
        }
    }

    @MainActor
    private final class AlbumStrip: Node {
        private let albums: [AlbumNode]
        init(posts: [FeedPost], pipeline: ImagePipeline) {
            albums = posts.map { AlbumNode(post: $0, pipeline: pipeline) }
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                for album in albums { album.width(.points(154)).flex(shrink: 0) }
            }.gap(12).padding(top: 0, leading: 16, bottom: 0, trailing: 16)
        }
    }

    @MainActor
    private final class AlbumNode: Node {
        private let photo: NodesRender.Image
        private let title: Text
        init(post: FeedPost, pipeline: ImagePipeline) {
            photo = NodesRender.Image(
                source: .url(post.imageURL),
                contentMode: .fill,
                placeholder: ImagePlaceholder(color: FeedStyle.line),
                pipeline: pipeline,
                loadingMode: .demandDriven
            )
            title = Text(post.place, style: FeedStyle.text(12, weight: .medium))
            title.style.maxLines = 1
            super.init()
            photo.appearance.cornerRadius = 14
            photo.appearance.clipsContent = true
        }
        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                photo.height(.points(96)); title
            }.gap(8)
        }
    }
#endif
