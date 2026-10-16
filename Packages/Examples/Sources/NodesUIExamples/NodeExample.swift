#if canImport(CoreText)
    import FlexEngine
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import ThemeCore

    /// A counter as a tree of nodes. A node describes its subnodes' layout in `layoutSpec()` and
    /// brings its own properties up to date in `update()`; the states each of them reads are
    /// tracked, so changing one runs it again. The nodes a spec mentions become subnodes.
    @MainActor
    public final class CounterNode: Node {
        /// How many times the button was pressed.
        public let count = State(0)
        /// Whether the hint under the count shows.
        public let showsHint = State(true)

        /// The count.
        public let label = Text("0", style: TextStyle(.title))
        /// The hint.
        public let hint = Text(
            "Press the button",
            style: TextStyle(.caption, colorRole: .secondaryText)
        )
        /// The button; pressing it adds one.
        public private(set) lazy var button = Button("Add") { [unowned self] in
            count.value += 1
        }

        /// Shows the count in the label.
        public override func update() {
            label.text = "\(count.value)"
        }

        /// The column: the count, the hint while it shows, and the button.
        public override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                label
                if showsHint.value { hint }
                button
            }
            .alignItems(.center)
            .gap(.s3)
            .padding(.s5)
        }
    }

    /// Hosts the counter without a view, as tests and benchmarks do: the host lays the tree out in
    /// its size; on screen `NodeView` (UIKit) or `NodeNSView` (AppKit) is the host.
    ///
    /// - Returns: The button's frame before and after the hint is hidden.
    @MainActor
    public func runCounter() -> (before: LayoutRect, after: LayoutRect) {
        let counter = CounterNode()
        let host = NodeHost(root: counter, size: LayoutSize(width: 320, height: 240))
        host.layoutIfNeeded()
        let before = counter.button.frame

        counter.showsHint.value = false
        host.layoutIfNeeded()
        return (before, counter.button.frame)
    }
#endif
