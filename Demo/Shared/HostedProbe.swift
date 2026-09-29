import AppShell
import LayoutCore
import Nodes
import NodesRender

#if canImport(UIKit)
    import NodesUIKit
    import UIKit
#elseif canImport(AppKit)
    import AppKit
    import NodesAppKit
#endif

/// A screen of `HOSTED_PROBE=1` for UI tests of views of the platform inside the tree: a
/// system button whose presses count, under a line saying how many, in a scroll with room
/// enough to scroll the button out of sight.
@MainActor
enum HostedProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Hosted")
    }

    /// The presses so far, and who to tell of each.
    private final class Tally {
        var count = 0
        var changed: (@MainActor () -> Void)?
    }

    private final class Page: Node {
        let tally: Tally
        let heading = Text("Hosted view page", style: TextStyle(size: 17))
        let counter = Text("Count 0", style: TextStyle(size: 17))
        let button: HostedView<Control>
        let filler = Filler()
        let end = Text("End of page", style: TextStyle(size: 17))
        lazy var scroll = Scroll(.vertical, content: Content(page: self))

        override init() {
            let tally = Tally()
            self.tally = tally
            button = HostedView(
                make: {
                    Control.hostedButton {
                        tally.count += 1
                        tally.changed?()
                    }
                }
            )
            super.init()
            tally.changed = { [weak self] in
                guard let self else { return }

                counter.text = "Count \(tally.count)"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { scroll }
        }
    }

    private final class Content: Node {
        unowned let page: Page

        init(page: Page) {
            self.page = page
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                page.heading
                page.counter
                page.button
                page.filler.size(width: 50, height: 900)
                page.end
            }
            .gap(16)
            .padding(24)
            .alignItems(.start)
        }
    }

    private final class Filler: Node {}
}

#if canImport(UIKit)
    private typealias Control = UIButton

    extension UIButton {
        fileprivate static func hostedButton(_ action: @escaping @MainActor () -> Void) -> UIButton
        {
            let button = UIButton(type: .system)
            button.setTitle("Hosted button", for: .normal)
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return button
        }
    }
#elseif canImport(AppKit)
    private typealias Control = NSButton

    /// A push button that runs a closure.
    private final class ClosureButton: NSButton {
        var handler: (@MainActor () -> Void)?

        @objc func run() {
            handler?()
        }
    }

    extension NSButton {
        fileprivate static func hostedButton(_ action: @escaping @MainActor () -> Void) -> NSButton
        {
            let button = ClosureButton(title: "Hosted button", target: nil, action: nil)
            button.handler = action
            button.target = button
            button.action = #selector(ClosureButton.run)
            return button
        }
    }
#endif
