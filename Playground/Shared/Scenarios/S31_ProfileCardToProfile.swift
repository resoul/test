import TrellisCore
import TrellisRender

#if canImport(AppKit)
    import AppKit
    import TrellisAppKit
#else
    import TrellisUIKit
    import UIKit
#endif

/// S31 — compact profile card → full profile, M14's second D74 reusability demonstration
/// (`docs/implementation-plan-5.md` §6). External-consumer code only, same constraints as S30:
/// no `CALayer`, coordinate arithmetic, manual timer, snapshot/copy management or cleanup here —
/// `ExpandGestureHandler` (defined in `S29_ExpandTransitionPlatforms.swift`) is reused unmodified
/// for the real iOS/macOS pan gesture.
///
/// **What makes this composition genuinely different from S30, not a reskin** (D74: "Отличия
/// второй сцены задаются данными/композицией перехода без правок coordinator/renderer"):
///
/// - Three roles again (`avatar`, `name`, `bio`), but shaped differently — `avatar` is a small
///   *circular* geometry element (`cornerRadius` half its side, D61's existing table, not a new
///   property) growing into a large circular portrait, where S30's `hero` is a rectangular photo
///   that goes edge-to-edge. `name` sits *beside* the avatar in the card and *below* it on the
///   profile page — a different arrangement on each side, not just a different size.
/// - `bio` is confined to `interval: 0.5...1` of the session's own progress (D70: "собственные
///   интервалы и кривые внутри него") — it only starts fading in once the avatar/name motion is
///   past its halfway point, instead of fading in across the whole transition the way S30's
///   `body` does. This is `TransitionRoleMapping.interval` (M14's one small, narrowly-scoped
///   addition to `NodeHostBridge`/`TransitionAnimator` — see ADR 0020) exercised by a real scene,
///   not only `Tests/TrellisRenderTests/M14TransitionCompositionTests.swift`'s deterministic
///   harness.
///
/// Both differences are pure data passed to `NodeHostBridge.TransitionRequest.roles` — this file
/// does not import anything beyond `TrellisCore`/`TrellisRender`/the platform host view, and
/// adds no code to `Sources/TrellisRender` beyond the one field `interval` already required to
/// exist for *some* consumer to pass a non-default value.
enum S31 {
    @MainActor
    private static var gestureHandler: AnyObject?

    @MainActor
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let card = ProfileTransitionCardNode()
        let profile = ProfileTransitionPageNode()
        root.addSubnode(card)
        root.addSubnode(profile)

        let request = NodeHostBridge.TransitionRequest(
            source: card.id,
            destinationRoot: profile.id,
            roles: [
                .init(role: Role("avatar"), source: card.avatar.id, destination: profile.avatar.id),
                .init(role: Role("name"), source: card.name.id, destination: profile.name.id),
                .init(
                    role: Role("bio"),
                    source: nil,
                    destination: profile.bio.id,
                    interval: 0.5...1
                ),
            ],
            duration: .milliseconds(360)
        )

        return ScenarioNodes.instance(
            .s31,
            root: root,
            inputs:
                "profile card→profile: circular avatar + name, bio confined to progress 0.5...1",
            expected:
                "opens/closes through TrellisHostView's forwarding API; bio only starts appearing past the halfway point of the motion",
            paths: ["root/card", "root/profile"],
            onAttach: { hostView, _ in
                card.onOpen = { [weak hostView] in _ = hostView?.presentTransition(request) }
                profile.onClose = { [weak hostView] in _ = hostView?.closeTransition() }

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

/// The source card: a small circular avatar beside the name (row layout) — deliberately not
/// S30's column-of-photo-then-headline shape.
final class ProfileTransitionCardNode: ControlNode {
    let avatar = Node(appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 20))
    let name = TextNode(
        text: "J. Rivera",
        textStyle: TextStyle(
            pointSize: 15,
            weight: .semibold,
            color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    )
    var onOpen: (@MainActor () -> Void)?

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 14))
        style {
            $0.flexDirection = .row
            $0.alignItems = .center
            $0.gap = 12
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        avatar.style.width = 40
        avatar.style.height = 40
        addSubnode(avatar)
        name.style.width = 140
        name.style.height = 20
        addSubnode(name)
        activation = { [weak self] in self?.onOpen?() }
    }
}

/// The destination profile: a large circular avatar, the name below it (column layout, not
/// beside it — a different arrangement from the card, not only a different scale), and a bio
/// paragraph that only starts appearing once the motion is past its own halfway point
/// (`interval: 0.5...1` on the `bio` role mapping above).
final class ProfileTransitionPageNode: Node {
    let avatar = Node(appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 48))
    let name = TextNode(
        text: "J. Rivera",
        textStyle: TextStyle(
            pointSize: 26,
            weight: .bold,
            color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    )
    let bio = TextNode(
        text: "Product design, ten years. Previously at two startups; now building small tools "
            + "for people who read a lot. Based in Lisbon, usually reachable by pigeon.",
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
            $0.alignItems = .center
            $0.gap = 14
            $0.padding = DirectionalEdgeInsets(top: 28, leading: 20, bottom: 20, trailing: 20)
        }
        avatar.style.width = 96
        avatar.style.height = 96
        addSubnode(avatar)
        name.style.width = 260
        name.style.height = 34
        addSubnode(name)
        bio.style.width = 320
        bio.style.height = 80
        addSubnode(bio)
        let close = CloseButton()
        close.onClose = { [weak self] in self?.onClose?() }
        addSubnode(close)
    }
}
