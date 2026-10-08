import Foundation
import TrellisCore

/// R08 (`implementation-plan-6.md`): the first Playground scene that actually mounts a
/// `ScrollNode` for manual/device evidence, not just the fake-backing unit tests
/// (`ScrollNodeHitTestTests.swift`) or the headless `UIKitScrollNodeEmbeddingTests.swift`/
/// `AppKitScrollNodeEmbeddingTests.swift` embedding checks. R06/R07 built and verified the
/// geometry pipeline; this scene is what a real touch/trackpad/wheel run drives.
///
/// Content is a vertical column of 16 fixed-height rows — enough to make the native content
/// size (16 × 96 = 1536pt) far exceed a device viewport, so a real drag/fling always has room
/// to move. Two rows carry a `ControlNode` (`TargetCardNode`, defined below): one near the top
/// (row 1, visible without scrolling — a same-place tap baseline) and one below the fold (row
/// 11 by default, `targetRowIndex`) whose activation only a correct offset-aware hit test can
/// reach after a drag reveals it (R08 checklist's "hit test учитывает текущий offset").
/// `accessibility.label`/`.hint` on both distinguish them for VoiceOver/AX-tree evidence
/// (R08's "AX scroll actions и корректные frames").
final class TargetCardNode: ControlNode {
    private let indicator = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 6)
    )
    private(set) var activationCount = 0

    init(label: String, idleColor: ThemeColor) {
        super.init(appearance: VisualStyle(background: .color(idleColor), cornerRadius: 12))
        style.height = .points(80)
        style.width = .fraction(1)
        accessibility.label = label
        accessibility.hint = "Activates the target card"
        accessibility.value = "0"
        activation = { [weak self] in self?.activated() }
    }

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        respond(to: event)
    }

    override func handleBubble(_ event: Event) {
        super.handleBubble(event)
        respond(to: event)
    }

    /// Live "pressed" feedback only — never touches the indicator on release, so it does not
    /// race `activated()` (D29 (1): `ControlNode.handleEvent` runs `track`, which can call
    /// `activation` synchronously on the same `pointerUp`, before this override's own
    /// `super.handleEvent` call returns and `respond(to:)` runs after it).
    private func respond(to event: Event) {
        guard isPressed else { return }
        indicator.appearance.background = .color(Palette.cyan)
    }

    private func activated() {
        activationCount += 1
        accessibility.value = String(activationCount)
        indicator.appearance.background = .color(Palette.green)
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(
            align: .center,
            padding: DirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        ) {
            Leaf(indicator).size(width: 16, height: 16)
        }
    }
}

@MainActor enum S33 {
    static let rowCount = 16
    static let rowHeight = 96.0
    static let targetRowIndex = 10

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.flexDirection = .column; $0.gap = 0
        }

        let scroll = ScrollNode()
        scroll.configuration.axis = .vertical
        scroll.style {
            $0.flexDirection = .column
            $0.width = .fraction(1)
            $0.flexGrow = 1
            $0.flexShrink = 1
        }

        if ProcessInfo.processInfo.arguments.contains("--r08-test") {
            scroll.style.height = 400
            scroll.style.flexGrow = 0
        }

        var target: TargetCardNode?
        var baseline: TargetCardNode?

        for index in 0..<rowCount {
            let row: Node
            if index == 1 {
                let card = TargetCardNode(
                    label: "Baseline card, row \(index)",
                    idleColor: Palette.blue
                )
                baseline = card
                row = card
            } else if index == targetRowIndex {
                let card = TargetCardNode(
                    label: "Target card, row \(index)",
                    idleColor: Palette.purple
                )
                target = card
                row = card
            } else {
                let plain = ScenarioNodes.node(
                    "row\(index)",
                    color: index.isMultiple(of: 2) ? Palette.card : Palette.cardLight
                )
                plain.style {
                    $0.height = .points(rowHeight); $0.width = .fraction(1)
                }
                row = plain
            }
            scroll.addSubnode(row)
        }

        root.addSubnode(scroll)

        _ = target
        _ = baseline

        return ScenarioNodes.instance(
            .s33,
            root: root,
            inputs: "ScrollNode, vertical, \(rowCount) rows × \(rowHeight)pt "
                + "(content \(Double(rowCount) * rowHeight)pt); ControlNode at row 1 (visible) "
                + "and row \(targetRowIndex) (below the fold)",
            expected: "Real drag moves native offset with momentum on release; a tap that "
                + "ends a drag gesture does not activate a card under the release point; "
                + "dragging the target card into view and tapping it activates it (offset-aware "
                + "hit test, R08); VoiceOver/AX reaches both cards with correct frames as the "
                + "offset changes",
            paths: ["root", "root/scroll"],
            onAttach: { host, _ in
                guard ProcessInfo.processInfo.arguments.contains("--r08-detach-test") else {
                    return
                }
                scroll.onScrollStateChanged = { [weak host] state in
                    guard state.phase == .decelerating, let host else { return }
                    host.detach()
                    let result = ControlNode()
                    result.accessibility.label = "Detached during deceleration"
                    result.style.width = 300
                    result.style.height = 200
                    host.attach(root: result)
                }
            }
        )
    }
}
