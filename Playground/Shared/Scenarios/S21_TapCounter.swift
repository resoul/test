import TrellisCore

/// One tappable card (H09): a `ControlNode` that proves snapshot → hit-test → dispatch →
/// arena → control end-to-end, with three visible signals — no text (N01 is not in scope
/// yet), so all three are colored shapes:
///
/// - the card's own background is the **live** signal, straight from `isPressed`: idle color
///   while up, accent color while down and still inside (H01 §5 (1)/(2));
/// - `outcomeIndicator` is the **last outcome**, set the moment a press ends and kept until
///   the next one — amber for "ended without activating" (moved outside and released there,
///   explicit cancel, lost arbitration to another recognizer), green for "activated". Both are
///   decided from the same synchronous turn (D29 (1): capture → target → bubble → arena all
///   run before the pointer callback that produced the event returns), so setting amber
///   tentatively in `respond(to:)` and overriding it to green in `activated()` a moment later
///   in the same turn is race-free — no scheduling trick, no new hook on `ControlNode`;
/// - `counterFill` is the **activation count**, one step per successful tap, capped so the
///   bar never overflows the card.
///
/// A screenshot taken any time after a gesture completes — not only mid-touch, which the
/// simulator tooling used to drive this scene cannot capture (see
/// `docs/validation/h09-tap-counter.md`) — shows exactly what happened: the live color has
/// already reverted, but the outcome indicator and counter have not.
final class TapCardNode: ControlNode {
    private static let counterStep = 12.0
    private static let counterCap = 6

    /// A plain child with no recognizer of its own, present only when `withDecorativeIcon`
    /// is set (H01 §5 (7)): a tap that lands on it is still hit-tested to this child, but
    /// bubbles to this card, which recognizes and activates.
    let decorativeIcon: Node?

    private let spacer = Node()
    private let outcomeIndicator = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 5)
    )
    private let counterTrack = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 4)
    )
    // No corner radius: a zero-width rounded rect self-intersects into a visible bowtie
    // (CALayer does not clamp `cornerRadius` to half of a near-zero `width`) — a plain
    // rectangle has no such degenerate case, and it already sits inside the rounded track.
    private let counterFill = Node(appearance: VisualStyle(background: .color(Palette.cyan)))

    /// Number of completed activations — the value `counterFill`'s width encodes, capped at
    /// `counterCap` for display; the count itself is never capped.
    private(set) var tapCount = 0

    init(withDecorativeIcon: Bool = false) {
        decorativeIcon =
            withDecorativeIcon
            ? Node(appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 6))
            : nil
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 14))
        style.width = .points(320)
        style.height = .points(72)
        style.alignSelf = .center
        counterFill.style.width = .points(0)  // no taps yet — an invisible, not degenerate, bar
        activation = { [weak self] in self?.activated() }
    }

    /// Reached when this card is itself the hit target (no decorative child under the point).
    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        respond(to: event)
    }

    /// Reached when the hit target is `decorativeIcon`, bubbling up to this card.
    override func handleBubble(_ event: Event) {
        super.handleBubble(event)
        respond(to: event)
    }

    private func respond(to event: Event) {
        if event.type == .pointerUp || event.type == .pointerCancel {
            // Tentative "missed": `activated()` overrides this in the same turn if arbitration
            // and geometry both went this card's way for this same event.
            outcomeIndicator.appearance.background = .color(Palette.orange)
        }
        appearance.background = .color(isPressed ? Palette.blue : Palette.card)
    }

    private func activated() {
        tapCount += 1
        outcomeIndicator.appearance.background = .color(Palette.green)
        let steps = min(tapCount, Self.counterCap)
        counterFill.style.width = .points(Self.counterStep * Double(steps))
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(
            spacing: 14,
            align: .center,
            padding: DirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        ) {
            if let decorativeIcon {
                Leaf(decorativeIcon).size(width: 28, height: 28)
            }
            Leaf(spacer).grow(1)
            Column(spacing: 6, align: .end) {
                Leaf(outcomeIndicator).size(width: 10, height: 10)
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
}

@MainActor enum S21 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.alignItems = .center; $0.gap = 16
        }

        let plain = TapCardNode()
        let withIcon = TapCardNode(withDecorativeIcon: true)
        let third = TapCardNode()
        root.addSubnode(plain)
        root.addSubnode(withIcon)
        root.addSubnode(third)

        return ScenarioNodes.instance(
            .s21,
            root: root,
            inputs: "3 ControlNode cards (one with a decorative child); Tap slop 10pt (D31)",
            expected: "down inside -> isPressed; move outside -> not pressed, no activation; "
                + "up inside -> activation once, counter grows, indicator green; up/cancel "
                + "outside -> indicator amber, counter unchanged; tap on the decorative child "
                + "still activates the card it sits in (H01 §5 (7))",
            paths: ["root", "root/card0", "root/card1", "root/card2"]
        )
    }
}
