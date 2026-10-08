import TrellisCore
import TrellisRender

#if canImport(AppKit)
    import TrellisAppKit
#else
    import TrellisUIKit
#endif

/// A card that toggles `isSelected` on activation (A11): VoiceOver reads "selected", the
/// badge turns green — one node, one source of the state (D41/D42).
final class SelectableCardNode: ControlNode {
    private let badge = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 6)
    )
    private(set) var isSelectedCard = false

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style.width = .points(288)
        style.height = .points(48)
        accessibility = AccessibilityProperties(
            isElement: true,
            label: "Notifications",
            hint: "Toggles notifications",
            role: .button
        )
        activation = { [weak self] in self?.toggle() }
    }

    private func toggle() {
        isSelectedCard.toggle()
        accessibility.isSelected = isSelectedCard
        badge.appearance.background = .color(isSelectedCard ? Palette.green : Palette.border)
    }

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        appearance.border = isFocused ? Border(color: Palette.cyan, width: 3) : nil
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(
            spacing: 12,
            align: .center,
            padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
            Leaf(badge).size(width: 24, height: 24)
        }
    }
}

/// An adjustable card (A11): `value` 0…10 read as text, changed by VoiceOver's
/// increment/decrement (swipe up/down) through `onAccessibilityAction`, and by Return/Space
/// as a plain activation that steps up. The fill bar shows the value without any text.
final class VolumeCardNode: ControlNode {
    private let track = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 4)
    )
    private let fill = Node(appearance: VisualStyle(background: .color(Palette.purple)))
    private(set) var value = 4

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 12))
        style.width = .points(288)
        style.height = .points(48)
        accessibility = AccessibilityProperties(
            isElement: true,
            label: "Volume",
            value: "4",
            hint: "Swipe up or down to adjust",
            role: .adjustable,
            actions: [.increment, .decrement]
        )
        onAccessibilityAction = { [weak self] action in
            guard let self else { return false }
            switch action {
            case .increment: return self.step(1)
            case .decrement: return self.step(-1)
            default: return false
            }
        }
        activation = { [weak self] in _ = self?.step(1) }
        applyValue()
    }

    private func step(_ delta: Int) -> Bool {
        let next = min(10, max(0, value + delta))
        guard next != value else { return false }
        value = next
        accessibility.value = "\(value)"
        applyValue()
        return true
    }

    private func applyValue() {
        fill.style.width = .points(Double(value) * 24)
    }

    override func handleEvent(_ event: Event) {
        super.handleEvent(event)
        appearance.border = isFocused ? Border(color: Palette.cyan, width: 3) : nil
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(
            spacing: 12,
            align: .center,
            padding: DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
            Overlay {
                Leaf(track).size(width: 240, height: 10)
                Leaf(fill).size(height: 10)
            }
            .size(width: 240, height: 10)
        }
    }
}

@MainActor enum S23 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style {
            $0.alignItems = .center; $0.gap = 12
        }

        // 1. `.contain` with `isElement`: a labelled group whose children are read one by one.
        let profile = ScenarioNodes.node("profile", color: Palette.card)
        profile.style {
            $0.width = 288; $0.flexDirection = .column; $0.gap = 6;
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        profile.accessibility = AccessibilityProperties(isElement: true, label: "Profile")
        let name = ScenarioNodes.fixed("name", width: 160, height: 18, color: Palette.textSecondary)
        name.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Ada Lovelace",
            role: .header
        )
        let subtitle = ScenarioNodes.fixed(
            "subtitle",
            width: 120,
            height: 12,
            color: Palette.border
        )
        subtitle.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Mathematician",
            role: .text
        )
        let follow = ControlNode(
            appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 8)
        )
        follow.style {
            $0.width = 80; $0.height = 28
        }
        follow.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Follow",
            hint: "Follows Ada",
            customActions: [AccessibilityCustomAction(id: "share", name: "Share profile")]
        )
        follow.onAccessibilityAction = { action in
            Log.on(.event, "custom-action", "action=\(action)")
            return action == .custom("share")
        }
        profile.addSubnode(name)
        profile.addSubnode(subtitle)
        profile.addSubnode(follow)

        // 2. `.combine`: one element, label joined from the children ("Weather, 21 degrees").
        let combined = ScenarioNodes.node("combined", color: Palette.card)
        combined.style {
            $0.width = 288; $0.height = 44; $0.flexDirection = .row; $0.gap = 8;
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        combined.accessibility = AccessibilityProperties(childrenPolicy: .combine)
        let icon = ScenarioNodes.fixed("icon", width: 20, height: 20, color: Palette.orange)
        icon.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Weather",
            role: .image
        )
        let temperature = ScenarioNodes.fixed(
            "temperature",
            width: 100,
            height: 20,
            color: Palette.textSecondary
        )
        temperature.accessibility = AccessibilityProperties(
            isElement: true,
            label: "21 degrees",
            role: .text
        )
        combined.addSubnode(icon)
        combined.addSubnode(temperature)

        // 3. `.ignoreSelf`: the row is a container only; its two buttons are the elements.
        let actions = ScenarioNodes.node("actions", color: Palette.card)
        actions.style {
            $0.width = 288; $0.height = 52; $0.flexDirection = .row; $0.gap = 12;
            $0.padding = DirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        }
        actions.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Ignored row",
            childrenPolicy: .ignoreSelf
        )
        for (label, color) in [("Like", Palette.pink), ("Comment", Palette.green)] {
            let button = ControlNode(
                appearance: VisualStyle(background: .color(color), cornerRadius: 8)
            )
            button.style {
                $0.width = 80; $0.height = 28
            }
            button.accessibility.label = label
            actions.addSubnode(button)
        }
        // A purely decorative block inside the row: `.hide` keeps it out of the semantic tree.
        let decoration = ScenarioNodes.fixed(
            "decoration",
            width: 28,
            height: 28,
            color: Palette.border
        )
        decoration.accessibility = AccessibilityProperties(
            isElement: true,
            label: "Decoration",
            childrenPolicy: .hide
        )
        actions.addSubnode(decoration)

        // 4–5. Selectable and adjustable elements.
        let selectable = SelectableCardNode()
        let volume = VolumeCardNode()

        for node in [profile, combined, actions, selectable, volume] { root.addSubnode(node) }

        return ScenarioNodes.instance(
            .s23,
            root: root,
            inputs:
                "labelled .contain group (header, text, button with hint + custom action); .combine row; .ignoreSelf row with two buttons and a .hide decoration; selectable card; adjustable 0…10",
            expected:
                "VoiceOver reads: Profile group → Ada Lovelace (heading), Mathematician, Follow (hint, Share profile action); "
                + "'Weather, 21 degrees' as one element; Like, Comment without the row itself or the decoration; "
                + "Notifications toggles 'selected'; Volume adjusts with swipe up/down and reads its value — no TextNode anywhere",
            paths: [
                "root", "root/profile", "root/combined", "root/actions", "root/selectable",
                "root/volume",
            ]
        )
    }
}
