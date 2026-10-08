import TrellisCore

/// A small "kitchen sink" of everything M01–M07 proved about `Node.animate` that a single static
/// screenshot cannot show by itself (the transition itself is native/interactive evidence, not a
/// diff-able reference image) — each panel below is a static signal of *what happened*, the same
/// convention S21's `TapCardNode` already uses for gesture outcomes.
///
/// - Retarget (D66): a press moves a bar to one of two widths under a long, visibly-in-flight
///   duration; a second press before the first settles retargets from the live value, not the
///   pre-press one — `pressCount` is the only thing a screenshot can confirm happened at all.
/// - Scopes (D62/D63): two cards share one row; "Animate row" wraps both under the row's scope
///   (both move together, even though only one's background actually changes), "Animate A only"
///   wraps just the first card — a sibling outside the scope always snaps.
/// - Reduce Motion (D67): a subtree-scoped toggle (`Node.setReduceMotion`, not a bridge-wide
///   setting) resolves every subsequent `.animate` in that subtree to an immediate snap.
private enum ScopeState {
    static let dim = ThemeColor(red: 0.24, green: 0.28, blue: 0.36)
    static let lit = ThemeColor(red: 0.98, green: 0.58, blue: 0.2)
}

/// A press-driven bar that alternates between two widths under a long duration, so a live
/// second press lands while the first transition is still visibly in flight (D66).
final class RetargetBarNode: ControlNode {
    private let bar = Node(
        appearance: VisualStyle(background: .color(Palette.cyan), cornerRadius: 6)
    )
    private let counter: TextNode
    private var isWide = false
    private(set) var pressCount = 0

    init() {
        counter = TextNode(
            text: "presses: 0",
            textStyle: TextStyle(pointSize: 12, color: Palette.textSecondary)
        )
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style {
            $0.flexDirection = .column
            $0.gap = 8
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        }
        bar.style.height = 16
        bar.style.width = .points(60)
        addSubnode(bar)
        addSubnode(counter)
        activation = { [weak self] in self?.press() }
    }

    private func press() {
        pressCount += 1
        counter.text = "presses: \(pressCount)"
        isWide.toggle()
        let width = isWide ? 220.0 : 60.0
        animate(.easeInOut(duration: .milliseconds(900))) {
            self.bar.style.width = .points(width)
        }
    }
}

/// Two cards sharing a row; "row" and "card A" are two independently pressable scope owners
/// over the same two children, making D62/D63's scope boundary visible as two different buttons
/// rather than a single toggle.
final class ScopeDemoNode: Node {
    private let row = Node()
    private let cardA = Node(
        appearance: VisualStyle(background: .color(ScopeState.dim), cornerRadius: 8)
    )
    private let cardB = Node(
        appearance: VisualStyle(background: .color(ScopeState.dim), cornerRadius: 8)
    )
    private var litA = false
    private var litB = false

    final class Button: ControlNode {
        init(label: String, action: @escaping @MainActor () -> Void) {
            super.init(appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 8))
            style {
                $0.padding = DirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            }
            // Explicit width: a `ControlNode`/`TextNode` pair with no width of its own, inside a
            // `Row` sibling of another such pair, otherwise resolves its text against a narrow
            // basis-pass width before the row's final layout — the same class of measurement
            // ambiguity S24's own captions already work around with an explicit width (defect
            // #48's precedent), not something this scene tries to fix in `Sources/`.
            let text = TextNode(text: label, textStyle: TextStyle(pointSize: 12, weight: .medium))
            text.style.width = 300
            text.style.height = 20
            addSubnode(text)
            activation = action
        }
    }

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style {
            $0.flexDirection = .column
            $0.gap = 10
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        }
        row.style {
            $0.flexDirection = .row; $0.gap = 8
        }
        cardA.style.width = 60
        cardA.style.height = 40
        cardB.style.width = 60
        cardB.style.height = 40
        row.addSubnode(cardA)
        row.addSubnode(cardB)
        addSubnode(row)

        let buttons = Node()
        buttons.style {
            $0.flexDirection = .row; $0.gap = 8
        }
        buttons.addSubnode(
            Button(label: "Animate row") { [weak self] in self?.animateRow() }
        )
        buttons.addSubnode(
            Button(label: "Animate A only") { [weak self] in self?.animateAOnly() }
        )
        addSubnode(buttons)
    }

    private func animateRow() {
        litA.toggle()
        litB.toggle()
        let colorA = litA ? ScopeState.lit : ScopeState.dim
        let colorB = litB ? ScopeState.lit : ScopeState.dim
        // D63: the row is the common scope owner of both cards — both transitions share one
        // timing even though this closure could just as well have changed only one of them.
        row.animate(.smooth) {
            self.cardA.appearance.background = .color(colorA)
            self.cardB.appearance.background = .color(colorB)
        }
    }

    private func animateAOnly() {
        litA.toggle()
        let colorA = litA ? ScopeState.lit : ScopeState.dim
        // D63: `cardB` sits outside this scope — a later `animateRow()` still finds it exactly
        // where its own model value left it, never mid-flight from this call.
        cardA.animate(.smooth) {
            self.cardA.appearance.background = .color(colorA)
        }
    }
}

/// A subtree-scoped Reduce Motion toggle (`Node.setReduceMotion`, D67) — independent of any
/// bridge-wide accessibility setting, proving the environment key is a plain inherited value a
/// scene (or an app) can override locally, not only a host-level switch.
final class ReduceMotionPanelNode: Node {
    private let toggle: ControlNode
    private let toggleLabel: TextNode
    private let demoCard = Node(
        appearance: VisualStyle(background: .color(ScopeState.dim), cornerRadius: 8)
    )
    private var isReduced = false
    private var isLit = false

    init() {
        toggleLabel = TextNode(
            text: "Reduce Motion: Off",
            textStyle: TextStyle(pointSize: 12, weight: .medium)
        )
        // Same explicit-size workaround as `ScopeDemoNode.Button` above.
        toggleLabel.style.width = 200
        toggleLabel.style.height = 20
        toggle = ControlNode(
            appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 8)
        )
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style {
            $0.flexDirection = .column
            $0.alignItems = .start
            $0.gap = 10
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        }
        toggle.style.padding = DirectionalEdgeInsets(
            top: 8,
            leading: 12,
            bottom: 8,
            trailing: 12
        )
        toggle.addSubnode(toggleLabel)
        toggle.activation = { [weak self] in self?.flip() }
        demoCard.style.width = 60
        demoCard.style.height = 40
        demoCard.focus.isFocusable = false
        addSubnode(toggle)
        addSubnode(demoCard)
    }

    private func flip() {
        isReduced.toggle()
        toggleLabel.text = "Reduce Motion: \(isReduced ? "On" : "Off")"
        // Subtree-scoped (D67): only `demoCard`'s own environment changes, not the whole
        // Playground host — every `.animate` on this node from now on resolves to `.none`'s
        // snap path while `isReduced` is true, exactly like a real per-view override would.
        demoCard.setReduceMotion(isReduced)
        isLit.toggle()
        let color = isLit ? ScopeState.lit : ScopeState.dim
        demoCard.animate(.smooth) {
            self.demoCard.appearance.background = .color(color)
        }
    }
}

@MainActor enum S28 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.flexDirection = .column; $0.gap = 12
        }

        let retarget = RetargetBarNode()
        let scopes = ScopeDemoNode()
        let reduceMotion = ReduceMotionPanelNode()
        root.addSubnode(retarget)
        root.addSubnode(scopes)
        root.addSubnode(reduceMotion)

        return ScenarioNodes.instance(
            .s28,
            root: root,
            inputs:
                "3 panels: retarget bar, row/card animation scopes, subtree Reduce Motion toggle",
            expected:
                "retarget bar: a second press before the first 900ms transition settles "
                + "retargets from the live width, not the pre-press one (D66); scope panel: "
                + "'Animate row' moves both cards under one timing, 'Animate A only' never "
                + "touches card B (D62/D63); Reduce Motion panel: toggling it on scopes every "
                + "later transition on its own demo card to an immediate snap (D67), other "
                + "panels unaffected",
            paths: ["root", "root/retarget", "root/scopes", "root/reduceMotion"]
        )
    }
}
