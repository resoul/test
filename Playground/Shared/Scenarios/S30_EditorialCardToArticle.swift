import TrellisCore
import TrellisRender

#if canImport(AppKit)
    import AppKit
    import TrellisAppKit
#else
    import TrellisUIKit
    import UIKit
#endif

/// S30 — editorial card → article, the first of M14's two D74 reusability demonstrations
/// (`docs/implementation-plan-5.md` §6, renumbered from S29 when M13 claimed that number for its
/// own platform-verification scene). Written the way an external app author would: only public
/// `TrellisCore`/`TrellisRender`/`TrellisHostView` API — `NodeHostBridge.TransitionRequest`'s
/// `roles`, `TrellisHostView.presentTransition(_:)`/`closeTransition()`, and (iOS/macOS) the same
/// `ExpandGestureHandler` S29 already defines, reused unmodified because it only forwards a pan
/// gesture's translation/velocity into the four gesture methods — it has no idea what roles a
/// scene uses. No `CALayer`, no coordinate arithmetic, no manual timer, no snapshot/copy
/// management, and no cleanup code anywhere in this file (D74's own checklist for "external
/// consumer").
///
/// Emphasis, per M14's checklist: a *large* hero image and *substantial* body text — a
/// three-role composition (`hero`, `headline`, `body`) distinct from S29's two-role `.expand`.
/// `body` has no source counterpart at all (the card has no excerpt) — D70's "missing element
/// fades" is exercised for real, not just asserted by a unit test, and it uses the *default*
/// full-progress range (unlike S31's `bio`, which confines itself to a sub-interval) — the two
/// scenes deliberately differ in which of D70's mechanisms they lean on.
///
/// Local fixtures only (`docs/implementation-plan-5.md` §6: "данные и изображения локальные... без
/// скрытой зависимости от N02/ScrollNode"): the "photo" is a plain colored `Node` — N02 (network
/// image loading) does not exist yet in this codebase, and no other scene fakes a bitmap image
/// any other way (see `S16_ProfileCard.swift`/`S19_MediaPlayer.swift`'s own "artwork" tiles) — and
/// the page is a static container, no `ScrollNode` (D73's scroll-arbitration item stays open,
/// not solved here).
enum S30 {
    @MainActor
    private static var gestureHandler: AnyObject?

    @MainActor
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let card = EditorialCardNode()
        let article = EditorialArticleNode()
        root.addSubnode(card)
        root.addSubnode(article)

        let request = NodeHostBridge.TransitionRequest(
            source: card.id,
            destinationRoot: article.id,
            roles: [
                .init(role: Role("hero"), source: card.photo.id, destination: article.photo.id),
                .init(
                    role: Role("headline"),
                    source: card.headline.id,
                    destination: article.headline.id
                ),
                // No `source` — the card carries no excerpt at all. D70: a role missing on one
                // side fades instead of flying. Default (full) progress range, unlike S31's
                // interval-confined `bio` role.
                .init(role: Role("body"), source: nil, destination: article.body.id),
            ],
            duration: .milliseconds(360)
        )

        return ScenarioNodes.instance(
            .s30,
            root: root,
            inputs: "editorial card→article: large hero image + substantial body text",
            expected:
                "opens/closes through TrellisHostView's forwarding API; hero+headline fly, body fades in with no source counterpart",
            paths: ["root/card", "root/article"],
            onAttach: { hostView, _ in
                card.onOpen = { [weak hostView] in _ = hostView?.presentTransition(request) }
                article.onClose = { [weak hostView] in _ = hostView?.closeTransition() }

                #if canImport(AppKit)
                    gestureHandler = ExpandGestureHandler(hostView: hostView)
                #else
                    if hostView.traitCollection.userInterfaceIdiom != .tv {
                        gestureHandler = ExpandGestureHandler(hostView: hostView)
                    } else {
                        gestureHandler = nil
                    }
                #endif
            }
        )
    }
}

/// The source card: a large "photo" (a plain colored `Node` — no `ImageNode`/N02 in this
/// codebase yet, same local-fixture convention `S16_ProfileCard.swift`/`S19_MediaPlayer.swift`
/// already use for artwork) and a two-line headline. A `ControlNode` so a plain tap opens the
/// transition, on every platform including tvOS's remote select.
final class EditorialCardNode: ControlNode {
    let photo = Node(appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 12))
    let headline = TextNode(
        text: "The quiet redesign of the city's oldest market hall",
        textStyle: TextStyle(
            pointSize: 15,
            weight: .semibold,
            color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    )
    var onOpen: (@MainActor () -> Void)?

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 16))
        style {
            $0.flexDirection = .column
            $0.gap = 10
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        photo.style.height = 160
        addSubnode(photo)
        headline.style.height = 40
        addSubnode(headline)
        activation = { [weak self] in self?.onOpen?() }
    }
}

/// The destination article: a taller hero photo, the same headline at article scale, and a
/// substantial (multi-sentence) body paragraph — the emphasis M14's checklist asks S30 to carry.
final class EditorialArticleNode: Node {
    let photo = Node(appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 0))
    let headline = TextNode(
        text: "The quiet redesign of the city's oldest market hall",
        textStyle: TextStyle(
            pointSize: 24,
            weight: .bold,
            color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    )
    let body = TextNode(
        text: """
            For three decades the market hall's timber roof went unrepaired, its stalls thinning \
            year by year as the surrounding blocks were rebuilt around it. The renovation that \
            finally reached it last spring kept almost none of the original fittings, yet the \
            architects insist the building reads as the same place — the same proportions, the \
            same light falling through the same high windows, just carried by a structure that \
            will no longer need this kind of repair for another eighty years. Vendors who left \
            during construction are trickling back, several of them the grandchildren of the \
            people who first opened stalls here.
            """,
        textStyle: TextStyle(
            pointSize: 15,
            weight: .regular,
            color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    )
    var onClose: (@MainActor () -> Void)?

    private final class CloseButton: ControlNode {
        var onClose: (@MainActor () -> Void)?

        init() {
            super.init(appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 8))
            style {
                $0.padding = DirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            }
            let label = TextNode(
                text: "Close",
                textStyle: TextStyle(
                    pointSize: 13,
                    weight: .medium,
                    color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
                )
            )
            label.style.width = 60
            label.style.height = 18
            addSubnode(label)
            activation = { [weak self] in self?.onClose?() }
        }
    }

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.canvas), cornerRadius: 0))
        style {
            $0.flexDirection = .column
            $0.gap = 14
            $0.padding = DirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        }
        photo.style.height = 260
        addSubnode(photo)
        headline.style.height = 64
        addSubnode(headline)
        body.style.height = 180
        addSubnode(body)
        let close = CloseButton()
        close.onClose = { [weak self] in self?.onClose?() }
        addSubnode(close)
    }
}
