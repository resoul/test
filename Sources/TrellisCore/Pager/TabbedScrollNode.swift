import Foundation

/// Where a `TabbedScrollNode`'s tabs bar goes when the header scrolls away (P6.5).
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TabsPlacement: Sendable, Hashable {
    /// The bar scrolls with the header, then stays at the pin line.
    case pinned
    /// The bar scrolls away with the header; the pages stop at the pin line.
    case inline
}

/// The tabs bar of a `TabbedScrollNode`: placement and appearance of the segmented bar.
///
/// Ownership: a value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TabsConfiguration: Sendable, Hashable {
    /// Where the bar goes when the header scrolls away.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var placement: TabsPlacement

    /// Colors and metrics of the bar.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var appearance: TabsAppearance

    /// Creates a configuration.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public init(
        placement: TabsPlacement = .pinned,
        appearance: TabsAppearance = TabsAppearance()
    ) {
        self.placement = placement
        self.appearance = appearance
    }

    /// A segmented bar (`TabsNode`) with `placement`.
    ///
    /// Ownership: the caller owns the value. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public static func segmented(
        placement: TabsPlacement = .pinned,
        appearance: TabsAppearance = TabsAppearance()
    ) -> TabsConfiguration {
        TabsConfiguration(placement: placement, appearance: appearance)
    }
}

/// A page of a `TabbedScrollNode` that scrolls vertically exposes that scroll view, so the
/// coordinator can lock it until the tabs are pinned (ADR 0037 §4). Collection containers and
/// a vertical `ScrollNode` conform; the first provider in tree order inside a page is used.
///
/// Ownership: implemented by nodes. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
public protocol PageScrollProviding: AnyObject {
    /// The page's vertical scroll node, or `nil` when this node does not scroll vertically.
    ///
    /// Ownership: the provider keeps owning it. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    var pageScrollNode: ScrollNode? { get }
}

extension CollectionNode: PageScrollProviding {
    /// The container's own scroll node.
    ///
    /// Ownership: the container keeps owning it. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var pageScrollNode: ScrollNode? { scrollNode }
}

extension ScrollNode: PageScrollProviding {
    /// This node when it scrolls vertically; `nil` for a horizontal scroll node.
    ///
    /// Ownership: returns this node. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var pageScrollNode: ScrollNode? {
        configuration.axis == .horizontal ? nil : self
    }
}

/// Within this distance of a position the coordinator treats the offset as at it.
private let pinTolerance = 1.0

/// A header, a tabs bar and pages perceived as one vertical scroll (P6.5, ADR 0037 — the
/// Telegram model). An outer vertical `ScrollNode` holds the header and a block exactly as
/// tall as the viewport below the pin line: the tabs bar (`.pinned`) and the `PagerNode`.
/// The outer scroll cannot move past the pin offset, where the block reaches the pin line, so
/// the tabs pin without extra code; the pages are never measured by their content.
///
/// Until the tabs are pinned the pages' vertical scrolls are locked (`userInteractionEnabled`
/// is `false`), so a drag over a page moves the outer scroll. Page positions (ADR 0037 §6):
/// while pinned every page keeps its offset; when the header starts to expand, the selected
/// page returns to its top and the other pages keep theirs; selecting a page that is not at its
/// top while the header is expanded pins the tabs with the pager's settle animation. A tap on
/// the selected tab pins the tabs, or scrolls the page to its top when already pinned.
///
/// The pin line is `pinInset` below the viewport's top — by default the part of the host's
/// top safe area the viewport covers (none inside a root that folded the safe area into its
/// padding). The pages see no top safe area: they are below the pin line. Refresh belongs to
/// the outer scroll at its top edge; page loading stays with each page. One gesture owner
/// (ADR 0029): the pager does not begin while the outer scroll is dragged, and the outer scroll
/// is disabled while the pager's pan runs. A fling that pins the tabs stops at the pin line;
/// momentum handoff to the page is step 2 of R14 (ADR 0037 §5).
///
/// Ownership: owns the header, the tabs bar, the pager and the outer scroll node; owns the
/// `userInteractionEnabled` of mounted pages' vertical scrolls; keeps the host weakly.
/// Isolation: MainActor. Errors: none. Cancellation: leaving the host cancels a running pin
/// animation's bookkeeping and restores the outer scroll; `dispose()` disposes the subtree.
@MainActor
public final class TabbedScrollNode<ID: Hashable & Sendable>: Node, HostedContainer {
    /// The header: any node with children, sized by layout.
    ///
    /// Ownership: retained as a child. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let header: Node

    /// The pages.
    ///
    /// Ownership: retained as a child. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let pager: PagerNode<ID>

    /// The segmented tabs bar.
    ///
    /// Ownership: retained as a child. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let tabsNode: TabsNode<ID>

    /// The outer vertical scroll node.
    ///
    /// Ownership: retained as a child. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let scrollNode: ScrollNode

    /// Placement and appearance of the tabs bar.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public let tabsConfiguration: TabsConfiguration

    /// Distance of the pin line below the viewport's top; `nil` uses the part of the host's
    /// top safe area the viewport covers.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: negative values count as zero.
    /// Cancellation: not applicable.
    public var pinInset: Double? {
        didSet { if pinInset != oldValue { updateBlockHeight() } }
    }

    /// How far the header has collapsed: 0 fully expanded, 1 with the tabs pinned.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var collapseProgress = 0.0

    /// Whether the outer scroll is at the pin offset and the pages scroll.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public private(set) var isPinned = false

    /// Called when `collapseProgress` changes, offset-only ticks included.
    ///
    /// Ownership: retained; capture weakly. Isolation: MainActor. Errors: none. Cancellation:
    /// assign `nil`.
    public var onCollapseProgressChange: (@MainActor (Double) -> Void)?

    /// The pages; see `PagerNode.tabs`.
    ///
    /// Ownership: retains factories and eager nodes. Isolation: MainActor. Errors: duplicate
    /// IDs keep the first page. Cancellation: not applicable.
    public var pages: [Tab<ID>] {
        get { pager.tabs }
        set { pager.tabs = newValue }
    }

    /// The committed page.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var selection: ID? { pager.selection }

    private let content = Node()
    private let block = Node()
    private weak var host: (any ContainerHost)?
    private var hasLayout = false
    private var viewportHeight = 0.0
    private var pinOffset = 0.0
    private var isPagerDragging = false
    private var isPinning = false
    private var pinGeneration: UInt64 = 0
    private var lastSettled: ID?
    /// The page selected since the header was last pinned or dragged; its position may still
    /// arrive (a restored page), and a deep one pins the tabs instead of returning to its top.
    private var selectionAwaitingPosition: ID?
    private var appliedPagesSafeArea: DirectionalEdgeInsets?

    /// Creates the composition; `tabs` defaults to a pinned segmented bar.
    ///
    /// Ownership: retains `header` and `pages`. Isolation: MainActor. Errors: an unknown
    /// selection selects the first page. Cancellation: not applicable.
    public init(
        header: Node,
        tabs: TabsConfiguration = .segmented(),
        pages: [Tab<ID>],
        selection: ID? = nil,
        style: LayoutStyle = LayoutStyle()
    ) {
        self.header = header
        self.tabsConfiguration = tabs
        var pagerStyle = LayoutStyle()
        pagerStyle.flexGrow = 1
        pagerStyle.alignSelf = .stretch
        let pager = PagerNode(tabs: pages, selection: selection, style: pagerStyle)
        self.pager = pager
        self.tabsNode = TabsNode(pager: pager, appearance: tabs.appearance)
        var scrollStyle = LayoutStyle()
        scrollStyle.flexGrow = 1
        scrollStyle.flexShrink = 1
        scrollStyle.alignSelf = .stretch
        self.scrollNode = ScrollNode(style: scrollStyle)
        var ownStyle = style
        ownStyle.flexDirection = .column
        super.init(style: ownStyle)

        scrollNode.configuration = ScrollConfiguration(
            axis: .vertical,
            indicators: .hidden,
            insetsSafeArea: false
        )
        content.style {
            $0.flexDirection = .column
            $0.flexShrink = 0
            $0.alignSelf = .stretch
        }
        block.style {
            $0.flexDirection = .column
            $0.flexShrink = 0
            $0.alignSelf = .stretch
            $0.height = .points(0)
        }
        header.style.flexShrink = 0
        content.addSubnode(header)
        switch tabs.placement {
        case .pinned:
            block.addSubnode(tabsNode)
        case .inline:
            content.addSubnode(tabsNode)
        }
        block.addSubnode(pager)
        content.addSubnode(block)
        scrollNode.addSubnode(content)
        addSubnode(scrollNode)

        scrollNode.onScrollStateChanged = { [weak self] state in
            self?.outerStateChanged(state)
        }
        tabsNode.handlesActivation = { [weak self] id in
            self?.tabActivated(id) ?? false
        }
        // One owner (ADR 0029): a vertical drag of the outer scroll keeps the gesture.
        let pagerMayBegin = pager.pan.shouldBegin
        pager.pan.shouldBegin = { [weak self] in
            guard let self, !self.scrollNode.state.isUserDriven else { return false }

            return pagerMayBegin?() ?? true
        }
        pager.addObserver(
            PagerObservation(
                owner: self,
                tabsChanged: {},
                progressChanged: { [weak self] progress, animation in
                    self?.pagerProgressChanged(progress, animation: animation)
                }
            )
        )
        lastSettled = pager.selection
    }

    /// Selects page `id`; see `PagerNode.select(_:animated:)`. A page that is not at its top
    /// pins the tabs when the header is expanded.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: an unknown ID is ignored. Cancellation: a
    /// later select or pan retargets.
    public func select(_ id: ID, animated: Bool = true) {
        pager.select(id, animated: animated)
    }

    /// Moves the outer scroll to the pin offset, collapsing the header.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none — without a host nothing moves.
    /// Cancellation: user input or a later command cancels the movement.
    public func pinTabs(animated: Bool = true) {
        pin(animation: animated ? pager.settleAnimation : .none)
    }

    /// Moves the outer scroll to its top, expanding the header.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none — without a host nothing moves.
    /// Cancellation: user input or a later command cancels the movement.
    public func expandHeader(animated: Bool = true) {
        guard let host else { return }

        pinGeneration &+= 1
        isPinning = false
        let animation = animated && !environment.reduceMotion ? pager.settleAnimation : .none
        let target = LayoutPoint(x: 0, y: 0)
        let command: ScrollCommand =
            animation.duration > .zero
            ? .timed(target, animation: animation) : .to(target, animated: false)
        host.scrollContainer(scrollNode, command) { _ in }
    }

    // MARK: HostedContainer

    /// Keeps the host for scroll commands and immediate configuration.
    ///
    /// Ownership: keeps `host` weakly. Isolation: MainActor. Errors: none. Cancellation: undone
    /// by `hostDidDetach()`.
    public func hostDidAttach(_ host: any ContainerHost) {
        self.host = host
    }

    /// Reads the committed viewport and block, sizes the block to the viewport below the pin
    /// line, and applies the page lock and position rules to newly mounted pages.
    ///
    /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func hostDidCommit(_ commit: ContainerCommit) {
        syncPagesSafeArea()
        if let height = scrollNode.calculatedFrame?.height {
            viewportHeight = height
        }
        updateBlockHeight()
        if let blockFrame = block.calculatedFrame, let viewport = scrollNode.calculatedFrame,
            viewportHeight > 0
        {
            let first = !hasLayout
            hasLayout = true
            let value = max(0, blockFrame.origin.y - viewport.origin.y - resolvedPinInset)
            if value != pinOffset || first {
                setPinOffset(value)
            }
        }
        applyPageLock()
        enforceSelectedPagePosition()
    }

    /// Restores the outer scroll and forgets pending work.
    ///
    /// Ownership: releases host resources. Isolation: MainActor. Errors: none. Cancellation:
    /// this is the cancellation point.
    public func hostDidDetach() {
        pinGeneration &+= 1
        isPinning = false
        selectionAwaitingPosition = nil
        if isPagerDragging {
            isPagerDragging = false
            scrollNode.configuration.userInteractionEnabled = true
        }
        host = nil
    }

    /// Stops callbacks and disposes the subtree.
    ///
    /// Ownership: releases the subtree. Isolation: MainActor. Errors: none. Cancellation:
    /// terminal.
    public override func dispose() {
        guard !isDisposed else { return }

        pinGeneration &+= 1
        onCollapseProgressChange = nil
        scrollNode.onScrollStateChanged = nil
        tabsNode.handlesActivation = nil
        super.dispose()
    }

    // MARK: Geometry

    private var resolvedPinInset: Double {
        max(0, pinInset ?? coveredSafeArea.top)
    }

    /// The part of the host's safe area the outer viewport covers, per edge. The environment
    /// carries the host's insets unchanged, while an ancestor that folded them into its padding
    /// (the tree root does by default) already keeps the viewport clear of them.
    private var coveredSafeArea: DirectionalEdgeInsets {
        var root: Node = self
        while let parent = root.supernode {
            root = parent
        }
        guard let viewport = scrollNode.calculatedFrame, let bounds = root.calculatedFrame else {
            return DirectionalEdgeInsets()
        }

        let safe = environment.safeAreaInsets
        let above = viewport.origin.y - bounds.origin.y
        let below = bounds.origin.y + bounds.height - viewport.origin.y - viewport.height
        let left = viewport.origin.x - bounds.origin.x
        let right = bounds.origin.x + bounds.width - viewport.origin.x - viewport.width
        let isRightToLeft = environment.layoutDirection == .rightToLeft
        return DirectionalEdgeInsets(
            top: max(0, safe.top - above),
            leading: max(0, safe.leading - (isRightToLeft ? right : left)),
            bottom: max(0, safe.bottom - below),
            trailing: max(0, safe.trailing - (isRightToLeft ? left : right))
        )
    }

    private func updateBlockHeight() {
        guard viewportHeight > 0 else { return }

        let height = SizeValue.points(max(0, viewportHeight - resolvedPinInset))
        if block.style.height != height {
            block.style.height = height
        }
    }

    /// The pages are below the pin line: no top safe area, the rest as far as the viewport
    /// covers it.
    private func syncPagesSafeArea() {
        let covered = coveredSafeArea
        let pages = DirectionalEdgeInsets(
            top: 0,
            leading: covered.leading,
            bottom: covered.bottom,
            trailing: covered.trailing
        )
        guard pages != appliedPagesSafeArea else { return }

        appliedPagesSafeArea = pages
        block.setSafeAreaInsets(pages)
    }

    private func setPinOffset(_ value: Double) {
        let wasPinned = isPinned
        pinOffset = value
        Log.on(
            .host,
            "tabbed-pin-offset",
            host: host?.hostID,
            node: id,
            "pin=\(value) pinned=\(wasPinned)"
        )
        // A header that grows or shrinks while the tabs are pinned keeps them pinned.
        if wasPinned, let host, !scrollNode.state.isUserDriven,
            abs(scrollNode.state.offset.y - value) > pinTolerance
        {
            let target = LayoutPoint(x: 0, y: value)
            host.scrollContainer(scrollNode, .to(target, animated: false)) { _ in }
            return
        }

        outerStateChanged(scrollNode.state)
    }

    // MARK: Outer scroll

    private func outerStateChanged(_ state: ScrollState) {
        guard hasLayout else { return }

        let offset = state.offset.y
        let progress = pinOffset > 0 ? min(1, max(0, offset / pinOffset)) : 1
        if progress != collapseProgress {
            collapseProgress = progress
            onCollapseProgressChange?(progress)
        }
        if state.isUserDriven {
            selectionAwaitingPosition = nil
        }
        updateBounce(offset: offset)

        let pinned = offset >= pinOffset - pinTolerance
        guard pinned != isPinned else { return }

        isPinned = pinned
        Log.on(
            .event,
            pinned ? "tabbed-pinned" : "tabbed-unpinned",
            host: host?.hostID,
            node: id,
            "offset=\(offset) pin=\(pinOffset)"
        )
        if pinned {
            selectionAwaitingPosition = nil
        } else {
            scrollSelectedPageToTop(animated: false)
        }
        applyPageLock()
    }

    /// The outer scroll bounces near its top (refresh) and never at the pin line, where the
    /// page takes over.
    private func updateBounce(offset: Double) {
        let threshold = pinOffset > 0 ? min(50, pinOffset / 2) : Double.infinity
        let bounce: ScrollBouncePolicy = offset < threshold ? .automatic : .never
        guard scrollNode.configuration.bounce != bounce else { return }

        scrollNode.configuration.bounce = bounce
        host?.applyScrollConfiguration(of: scrollNode)
    }

    private func pin(animation: Animation) {
        guard let host, hasLayout, !isPinned, !scrollNode.state.isUserDriven else { return }

        pinGeneration &+= 1
        let generation = pinGeneration
        isPinning = true
        let effective = environment.reduceMotion ? Animation.none : animation
        let animated = effective.duration > .zero
        let target = LayoutPoint(x: 0, y: pinOffset)
        let command: ScrollCommand =
            animated ? .timed(target, animation: effective) : .to(target, animated: false)
        Log.on(
            .event,
            "tabbed-pin",
            host: host.hostID,
            node: id,
            "from=\(scrollNode.state.offset.y) to=\(pinOffset) animated=\(animated)"
        )
        host.scrollContainer(scrollNode, command) { [weak self] _ in
            guard let self, self.pinGeneration == generation else { return }

            self.isPinning = false
        }
    }

    // MARK: Pages

    /// Locks the mounted pages' vertical scrolls until the tabs are pinned (ADR 0037 §3).
    /// During the pager's own pan the pager owns their interaction.
    private func applyPageLock() {
        guard hasLayout, !isPagerDragging else { return }

        let enabled = isPinned
        for scroll in mountedPageScrolls()
        where scroll.configuration.userInteractionEnabled != enabled {
            scroll.configuration.userInteractionEnabled = enabled
            host?.applyScrollConfiguration(of: scroll)
        }
    }

    /// While the header is expanded the selected page stays at its top; a page just selected
    /// (or restored) with a deeper position pins the tabs instead (ADR 0037 §6).
    private func enforceSelectedPagePosition() {
        guard hasLayout, !isPinned, !isPinning, !isPagerDragging,
            !scrollNode.state.isUserDriven,
            let selected = pager.selection,
            let scroll = pageScroll(of: selected),
            scroll.state.offset.y > pinTolerance
        else { return }

        if selectionAwaitingPosition == selected {
            pin(animation: pager.settleAnimation)
        } else {
            scrollSelectedPageToTop(animated: false)
        }
    }

    private func scrollSelectedPageToTop(animated: Bool) {
        guard let host, let selected = pager.selection, let scroll = pageScroll(of: selected),
            scroll.state.offset.y > pinTolerance
        else { return }

        Log.on(
            .event,
            "tabbed-page-top",
            host: host.hostID,
            node: scroll.id,
            "page=\(selected) from=\(scroll.state.offset.y)"
        )
        let target = LayoutPoint(x: scroll.state.offset.x, y: 0)
        host.scrollContainer(scroll, .to(target, animated: animated)) { _ in }
    }

    private func pagerProgressChanged(_ progress: PagerProgress<ID>, animation: Animation) {
        let dragging = progress.settled == nil
        if dragging != isPagerDragging {
            isPagerDragging = dragging
            // One owner (ADR 0029): the outer scroll does not move while the pager's pan runs.
            scrollNode.configuration.userInteractionEnabled = !dragging
            host?.applyScrollConfiguration(of: scrollNode)
        }
        guard let settled = progress.settled else { return }

        applyPageLock()
        guard settled != lastSettled else { return }

        lastSettled = settled
        guard !isPinned else { return }

        selectionAwaitingPosition = settled
        if let scroll = pageScroll(of: settled), scroll.state.offset.y > pinTolerance {
            pin(animation: animation.duration > .zero ? animation : pager.settleAnimation)
        }
    }

    /// A tap on the selected tab pins the tabs, or scrolls the page to its top when pinned.
    private func tabActivated(_ id: ID) -> Bool {
        guard id == pager.selection else { return false }

        if isPinned {
            if let host, let scroll = pageScroll(of: id) {
                let top = LayoutPoint(x: 0, y: 0)
                host.scrollContainer(scroll, .to(top, animated: true)) { _ in }
            }
        } else {
            pin(animation: pager.settleAnimation)
        }
        return true
    }

    private func mountedPageScrolls() -> [ScrollNode] {
        pager.mountedIDs.compactMap { pageScroll(of: $0) }
    }

    private func pageScroll(of id: ID) -> ScrollNode? {
        guard let content = pager.page(for: id) else { return nil }

        return Self.pageScroll(in: content)
    }

    private static func pageScroll(in node: Node) -> ScrollNode? {
        if let provider = node as? any PageScrollProviding, let scroll = provider.pageScrollNode {
            return scroll
        }
        for child in node.subnodes {
            if let found = pageScroll(in: child) { return found }
        }
        return nil
    }
}
