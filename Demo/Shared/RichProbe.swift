import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import RichTextCore

/// `RICH_PROBE=1` for UI tests of styled text: a text with every mark, a quote and code; a
/// short line that is one link, and a line saying which link was opened.
@MainActor
enum RichProbe {
    static let site = URL(string: "https://example.com/opened")!

    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Rich text")
    }

    private final class Page: Node {
        let styled = Text(
            rich: RichText(
                blocks: [
                    .paragraph([
                        Run("Plain, "), Run("bold", marks: .bold), Run(", "),
                        Run("italic", marks: .italic), Run(", "), Run("mono", marks: .mono),
                        Run(", "), Run("struck", marks: .strike), Run(", "),
                        Run("underlined", marks: .underline), Run("."),
                    ]),
                    .quote([Run("A quotation that goes on long enough to wrap onto a second line.")]
                    ),
                    .code("let answer = 6 * 7\nprint(answer)", language: "swift"),
                ]
            )
        )
        let link = Text(
            rich: RichText(blocks: [.paragraph([Run("Open the page", link: RichProbe.site)])])
        )
        let status = Text("Opened nothing")

        override init() {
            super.init()
            link.onLink = { [weak self] url in
                self?.status.text = "Opened \(url.absoluteString)"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                styled
                link
                status
            }
            .gap(16)
            .padding(24)
            .alignItems(.start)
        }
    }
}
