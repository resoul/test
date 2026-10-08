import TrellisCore
import TrellisRender

#if canImport(AppKit)
    import AppKit
    import TrellisAppKit
#else
    import TrellisUIKit
    import UIKit
#endif

/// S29 — `.expand` end to end through the real `TrellisHostView` forwarding API (M13's own
/// checklist item, `docs/implementation-plan-5.md` §6): proves the concrete gap M12's report
/// left open (`docs/validation/m12-progress-and-gesture.md` §4 — "it requires new
/// `TrellisHostView` forwarding API... to reach `NodeHostBridge` from a Playground scene at
/// all"). "Open" activates `NodeHostBridge.presentTransition(_:)` via `TrellisHostView.
/// presentTransition(_:)` on every platform; "Close" the symmetric `closeTransition()`; on
/// iOS/macOS a real `UIPanGestureRecognizer`/`NSPanGestureRecognizer`, attached directly to the
/// mounted host view (D73's fixed host-overlay region), drives the four gesture forwarding
/// calls for real. tvOS gets button/remote only (`Touch-жест не объявляется доступным на tvOS
/// автоматически`) — the pan recognizer is never attached there, decided at runtime
/// (`traitCollection.userInterfaceIdiom == .tv`), not `#if os(tvOS)`.
///
/// Reuses M11's card→page content (hero + title roles) rather than building M14's richer,
/// distinct second scenario — this card's own scope is "one scene sufficient to prove the
/// platform/lifecycle/AX acceptance criteria", not the reusability demo.
enum S29 {
    /// Retained for the scene's lifetime by a `static` (Playground demo convenience, not a
    /// production pattern) — `ScenarioBindings` only tracks `StateBinding`s, and a fresh
    /// instance replaces the previous scene's before `teardown()` ever runs, so there is
    /// exactly one live at a time, same as `Scenario.current` itself.
    @MainActor
    private static var gestureHandler: AnyObject?

    @MainActor
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let card = ExpandCardNode()
        let page = ExpandPageNode()
        root.addSubnode(card)
        root.addSubnode(page)

        let request = NodeHostBridge.TransitionRequest(
            source: card.id,
            destinationRoot: page.id,
            roles: [
                .init(role: .hero, source: card.id, destination: page.id),
                .init(role: .title, source: card.titleNode.id, destination: page.titleNode.id),
            ],
            duration: .milliseconds(320)
        )

        return ScenarioNodes.instance(
            .s29,
            root: root,
            inputs: "card→page `.expand`: button on every platform, real pan gesture on iOS/macOS",
            expected:
                "opens/closes through TrellisHostView's M13 forwarding API; tvOS button/remote only",
            paths: ["root/card", "root/page"],
            onAttach: { hostView, _ in
                card.onOpen = { [weak hostView] in _ = hostView?.presentTransition(request) }
                page.onClose = { [weak hostView] in _ = hostView?.closeTransition() }

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

/// The source card: a `ControlNode` so a plain tap (every platform, including tvOS's remote
/// select) opens the transition — `onOpen` is wired from `S29.make`'s `onAttach`, once a real
/// `TrellisHostView` exists to forward through.
final class ExpandCardNode: ControlNode {
    let titleNode = TextNode(
        text: "Weekly digest",
        textStyle: TextStyle(
            pointSize: 14,
            weight: .semibold,
            color: ThemeColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    )
    var onOpen: (@MainActor () -> Void)?

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 16))
        style {
            $0.height = 120
            $0.padding = DirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        }
        titleNode.style.height = 20
        addSubnode(titleNode)
        activation = { [weak self] in self?.onOpen?() }
    }
}

/// The destination page: a plain container with its own title (the `.title` role's other
/// endpoint) and a `ControlNode` "Close" affordance — the non-interactive close path every
/// platform has, alongside the pan gesture iOS/macOS also get.
final class ExpandPageNode: Node {
    let titleNode = TextNode(
        text: "Weekly digest — full story, with much more room to read than the card ever had",
        textStyle: TextStyle(
            pointSize: 20,
            weight: .bold,
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
            $0.gap = 16
            $0.padding = DirectionalEdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        }
        titleNode.style.height = 90
        addSubnode(titleNode)
        let close = CloseButton()
        close.onClose = { [weak self] in self?.onClose?() }
        addSubnode(close)
    }
}

// MARK: - Real native gesture wiring (M12's deferred gap, closed by M13)

#if canImport(AppKit)
    /// Attaches one real `NSPanGestureRecognizer` directly to the mounted `TrellisHostView`
    /// (a fixed view — D73: "жест принимается через неподвижную host-overlay область") and
    /// forwards it into `TrellisHostView`'s M13 gesture-forwarding API. `handlePan` is a plain
    /// `@objc` target-action method, the real mechanism `NSGestureRecognizer` requires — not a
    /// synthetic event constructed for a test.
    @MainActor
    final class ExpandGestureHandler: NSObject {
        private weak var hostView: TrellisHostView?
        /// The gesture's own extent (D73): a full vertical swipe across this many points maps
        /// to `0...1` of progress. Not the moving overlay's own presentation geometry — this
        /// bridge never reads a moving layer as gesture input.
        private let distance: CGFloat = 240

        init(hostView: TrellisHostView) {
            self.hostView = hostView
            super.init()
            let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            hostView.addGestureRecognizer(recognizer)
        }

        @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let hostView else { return }
            let translation = recognizer.translation(in: hostView)
            let velocity = recognizer.velocity(in: hostView)
            switch recognizer.state {
            case .began:
                _ = hostView.beginTransitionGesture()
            case .changed:
                hostView.updateTransitionGesture(deltaProgress: Double(translation.y / distance))
                recognizer.setTranslation(.zero, in: hostView)
            case .ended:
                _ = hostView.endTransitionGesture(velocity: Double(velocity.y / distance))
            case .cancelled, .failed:
                _ = hostView.cancelTransitionGestureSystemInterrupted()
            default:
                break
            }
        }
    }
#else
    /// UIKit counterpart of the AppKit handler above — same forwarding calls, real
    /// `UIPanGestureRecognizer`. Never attached on tvOS (`S29.make` checks
    /// `traitCollection.userInterfaceIdiom` at runtime before constructing this).
    @MainActor
    final class ExpandGestureHandler: NSObject {
        private weak var hostView: TrellisHostView?
        private let distance: CGFloat = 240

        init(hostView: TrellisHostView) {
            self.hostView = hostView
            super.init()
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            hostView.addGestureRecognizer(recognizer)
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let hostView else { return }
            let translation = recognizer.translation(in: hostView)
            let velocity = recognizer.velocity(in: hostView)
            switch recognizer.state {
            case .began:
                _ = hostView.beginTransitionGesture()
            case .changed:
                hostView.updateTransitionGesture(deltaProgress: Double(translation.y / distance))
                recognizer.setTranslation(.zero, in: hostView)
            case .ended:
                _ = hostView.endTransitionGesture(velocity: Double(velocity.y / distance))
            case .cancelled, .failed:
                _ = hostView.cancelTransitionGestureSystemInterrupted()
            default:
                break
            }
        }
    }
#endif
