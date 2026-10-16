#if canImport(CoreText)
    import LayoutCore
    import LocalizationCore
    import Nodes
    import StateCore
    import ThemeCore

    /// What a table shows at its end while it pages: a spinner while a page loads, a message with a
    /// button to try again when it failed, and an optional message when there is nothing more.
    ///
    /// The footer keeps one height whatever it shows, so the end of the list does not jump when a
    /// page starts or ends; it is blank between pages and, without an `endMessage`, at the end.
    /// The texts are `LocalizedText`s, resolved for the tree's locale: give them keys of your own
    /// catalog to translate them, or `defaultValue`s to just change the words.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public struct PageFooter: Sendable, Hashable {
        /// The height of the footer, in points.
        public var height: Double
        /// Shown beside the spinner while a page loads; `nil` shows the spinner alone.
        public var loadingMessage: LocalizedText?
        /// Shown when the last page failed.
        public var failureMessage: LocalizedText
        /// The title of the button that asks for the failed page again.
        public var retryTitle: LocalizedText
        /// Shown when there are no more pages; `nil` shows nothing.
        public var endMessage: LocalizedText?

        public init(
            height: Double = 56,
            loadingMessage: LocalizedText? = nil,
            failureMessage: LocalizedText = LocalizedText(
                "table.pageFooter.failure",
                defaultValue: "Couldn’t load more"
            ),
            retryTitle: LocalizedText = LocalizedText(
                "table.pageFooter.retry",
                defaultValue: "Retry"
            ),
            endMessage: LocalizedText? = nil
        ) {
            self.height = max(0, height)
            self.loadingMessage = loadingMessage
            self.failureMessage = failureMessage
            self.retryTitle = retryTitle
            self.endMessage = endMessage
        }
    }

    /// The footer of a paging table, as a node.
    @MainActor
    final class PageFooterNode: Node {
        private let configuration = State(PageFooter())
        private let state: @MainActor () -> PageLoadState
        private let message = Text("", style: TextStyle(.caption, colorRole: .secondaryText))
        private let spinner = RefreshSpinner()
        private let retry: Button

        var footer: PageFooter {
            get { configuration.value }
            set { configuration.value = newValue }
        }

        init(
            state: @escaping @MainActor () -> PageLoadState,
            retry action: @escaping @MainActor () -> Void
        ) {
            self.state = state
            retry = Button("", action: action)
            super.init()
        }

        override func update() {
            let footer = footer
            switch state() {
            case .loading:
                message.localizedText = footer.loadingMessage
                spinner.accessibility.label = localized(
                    footer.loadingMessage
                        ?? LocalizedText("table.pageFooter.loading", defaultValue: "Loading")
                )
                spinner.showRefresh(pull: 1, isRefreshing: true)
            case .failed:
                message.localizedText = footer.failureMessage
                retry.label.localizedText = footer.retryTitle
                spinner.showRefresh(pull: 0, isRefreshing: false)
            case .endReached:
                message.localizedText = footer.endMessage
                spinner.showRefresh(pull: 0, isRefreshing: false)
            case .idle:
                spinner.showRefresh(pull: 0, isRefreshing: false)
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            let footer = footer
            let state = state()
            return FlexContainer(.row) {
                if state == .loading {
                    spinner.asLayoutSpec.size(20)
                    if footer.loadingMessage != nil { message }
                } else if state == .failed {
                    message
                    retry
                } else if state == .endReached, footer.endMessage != nil {
                    message
                }
            }
            .height(.points(footer.height))
            .justifyContent(.center)
            .alignItems(.center)
            .gap(12)
        }
    }

    /// The content of a paging table's scroll: its rows, and the footer after them.
    @MainActor
    final class TableBody: Node {
        let stack: Node
        let footer: Node

        init(stack: Node, footer: Node) {
            self.stack = stack
            self.footer = footer
            super.init()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                stack
                footer
            }
        }
    }
#endif
