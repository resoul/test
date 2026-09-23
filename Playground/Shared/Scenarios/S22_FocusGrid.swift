import TrellisCore
import TrellisRender

#if canImport(AppKit)
    import TrellisAppKit
#else
    import TrellisUIKit
#endif

/// A focusable card (A11): a `ControlNode` with three visible signals and no text —
/// the focus ring (border, from `isFocused`), the pressed background (from `isPressed`)
/// and an activation counter bar. Every activation source (tap, Return/Space, Siri Remote
/// Select, VoiceOver activate) ends in the same `activation` closure (D43), so the counter
/// is the one place to check "exactly once" from any input.
final class FocusCardNode: ControlNode {
    private static let counterStep = 12.0
    private static let counterCap = 6

    private let counterTrack = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 4)
    )
    private let counterFill = Node(appearance: VisualStyle(background: .color(Palette.cyan)))
    private let badge: Node
    private(set) var activationCount = 0
    var onActivated: (() -> Void)?

    init(label: String, color: ThemeColor) {
        badge = Node(appearance: VisualStyle(background: .color(color), cornerRadius: 6))
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style.width = .points(96)
        style.height = .points(72)
        counterFill.style.width = .points(0)
        accessibility.label = label
        accessibility.hint = "Activates the card"
        activation = { [weak self] in self?.activated() }
    }

    /// The focus ring and pressed colour follow the control's own state; both are paint-only
    /// changes (H06/A07), so no layout pass runs for them.
    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        refreshAppearance()
    }

    override func handleBubble(_ event: Event) {
        super.handleBubble(event)
        refreshAppearance()
    }

    private func refreshAppearance() {
        appearance.border = isFocused ? Border(color: Palette.cyan, width: 3) : nil
        appearance.background = .color(
            !isEnabled ? Palette.border : isPressed ? Palette.blue : Palette.card
        )
    }

    func setDisabled() {
        isEnabled = false
        refreshAppearance()
    }

    private func activated() {
        activationCount += 1
        counterFill.style.width = .points(
            Self.counterStep * Double(min(activationCount, Self.counterCap))
        )
        onActivated?()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 8,
            align: .start,
            padding: DirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        ) {
            Leaf(badge).size(width: 20, height: 20)
            Overlay {
                Leaf(counterTrack).size(
                    width: .points(Self.counterStep * Double(Self.counterCap)),
                    height: 8
                )
                Leaf(counterFill).size(height: 8)
            }
            .size(width: .points(Self.counterStep * Double(Self.counterCap)), height: 8)
        }
    }
}

/// The S22 tree: a 3×3 grid of `FocusCardNode`s where one card is disabled, one removes
/// itself when activated, one opens a modal dialog (two buttons, focus scope confined to it,
/// closing restores the previous focus). Owns a weak reference to the host so it can drive
/// the focus scope; `attach(to:)` requests the initial focus so a screenshot shows the ring.
final class FocusGridRoot: Node {
    private weak var host: TrellisHostView?
    private var cards: [FocusCardNode] = []
    private var modal: Node?

    init(mode: ScenarioMode) {
        super.init(appearance: VisualStyle(background: .color(Palette.canvas)))
        style {
            $0.flexDirection = .column
            $0.padding = DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            $0.gap = 12
            $0.alignItems = .center
            if mode == .fixedInput {
                $0.width = 320
                $0.height = 640
            }
        }
        let colors = [Palette.blue, Palette.green, Palette.orange, Palette.pink, Palette.purple]
        for index in 0..<9 {
            let card = FocusCardNode(
                label: "Card \(index + 1)",
                color: colors[index % colors.count]
            )
            cards.append(card)
        }
        cards[4].setDisabled()
        cards[4].accessibility.label = "Disabled card"
        cards[6].accessibility.label = "Remove me"
        cards[6].onActivated = { [weak self, weak card = cards[6]] in
            guard let self, let card else { return }
            // Removing the focused card: the resolver detaches it on the next flush and the
            // engine falls back to the next live candidate on that commit (A04 §3.1).
            self.cards.removeAll { $0 === card }
            self.markArrangementDirty()
        }
        cards[8].accessibility.label = "Open dialog"
        cards[8].onActivated = { [weak self] in self?.openDialog() }
    }

    func attach(to host: TrellisHostView) {
        self.host = host
        host.onFocusChange = { change in
            Log.on(
                .focus,
                "scene",
                node: change.next,
                "previous=\(String(describing: change.previous)) reason=\(change.reason)"
            )
        }
        // A focus request needs a committed, published tree (D36); the app attaches the root
        // first and the commit lands asynchronously, so the initial focus is retried until
        // the engine accepts it — the ring is then visible in a screenshot without input.
        Self.retry { [weak host, weak self] in
            guard let host, let first = self?.cards.first else { return true }
            if case .moved = host.focus(first.id) { return true }
            return host.focusedID != nil
        }
    }

    /// Yields the main actor until `done` returns `true`, up to a bounded number of turns.
    private static func retry(_ done: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            for _ in 0..<2000 {
                if done() { return }
                await Task.yield()
            }
        }
    }

    private func openDialog() {
        guard modal == nil, let host else { return }
        let dialog = Node(
            appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 16)
        )
        dialog.style {
            $0.positionType = .absolute
            $0.offsets = DirectionalEdgeOffsets(top: 200, leading: 40)
            $0.width = 240
            $0.height = 120
            $0.flexDirection = .row
            $0.justifyContent = .spaceAround
            $0.alignItems = .center
            $0.visual = LayoutVisualProperties(zIndex: 10)
        }
        dialog.accessibility = AccessibilityProperties(isElement: true, label: "Dialog")
        let cancel = FocusCardNode(label: "Cancel", color: Palette.orange)
        let confirm = FocusCardNode(label: "Confirm", color: Palette.green)
        cancel.onActivated = { [weak self] in self?.closeDialog() }
        confirm.onActivated = { [weak self] in self?.closeDialog() }
        dialog.addSubnode(cancel)
        dialog.addSubnode(confirm)
        modal = dialog
        markArrangementDirty()
        // The scope opens once the dialog is committed and published (D36/D40): confining
        // focus to a subtree the screen does not show yet is refused by the bridge, so the
        // request is retried until the commit lands.
        Self.retry { [weak host, weak dialog] in
            guard let host, let dialog else { return true }
            host.setFocusScope(dialog.id)
            return host.focusScopeID == dialog.id
        }
    }

    private func closeDialog() {
        guard modal != nil else { return }
        // Closing restores the focus from before the dialog opened (D40); the dialog itself
        // leaves the tree on the next resolve.
        host?.setFocusScope(nil)
        modal = nil
        markArrangementDirty()
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 12,
            align: .center,
            padding: DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        ) {
            for row in stride(from: 0, to: cards.count, by: 3) {
                Row(spacing: 12) {
                    for card in cards[row..<min(row + 3, cards.count)] {
                        Leaf(card)
                    }
                }
            }
            if let modal {
                Leaf(modal)
            }
        }
    }
}

@MainActor enum S22 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = FocusGridRoot(mode: mode)
        return ScenarioNodes.instance(
            .s22,
            root: root,
            inputs:
                "3×3 FocusCardNode grid; card 5 disabled; card 7 removes itself; card 9 opens a modal with Cancel/Confirm",
            expected:
                "Tab/arrows move the cyan ring in tree order / by geometry, skipping the disabled card; "
                + "Return/Space/Select/tap/VoiceOver activate exactly once (counter bar); removing the "
                + "focused card moves focus to the next one; the dialog confines focus and restores it on close",
            paths: ["root", "root/card1..9", "root/dialog"],
            onAttach: { host, _ in root.attach(to: host) }
        )
    }
}
