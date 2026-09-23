import TrellisCore

/// Node subclass demonstrating dynamic Arrangement mutations:
/// - transient leaf addition/removal
/// - modifier removal/addition
/// - conditional wrapper insertion/removal
/// - leaf reordering
final class S15ArrangedContainer: Node {
    let stable = ScenarioNodes.fixed("stable", width: 180, height: 56, color: Palette.blue)
    let transient = ScenarioNodes.fixed("transient", width: 180, height: 56, color: Palette.pink)

    var showTransient = true
    var hasMargin = false
    var wrapInContainer = false
    var isReversed = false

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(spacing: 8) {
            if wrapInContainer {
                Row(spacing: 8) {
                    if isReversed {
                        if showTransient {
                            transientLeaf()
                        }
                        Leaf(stable)
                    } else {
                        Leaf(stable)
                        if showTransient {
                            transientLeaf()
                        }
                    }
                }
            } else {
                if isReversed {
                    if showTransient {
                        transientLeaf()
                    }
                    Leaf(stable)
                } else {
                    Leaf(stable)
                    if showTransient {
                        transientLeaf()
                    }
                }
            }
        }
    }

    private func transientLeaf() -> any Arrangement {
        if hasMargin {
            return Leaf(transient).margin(
                DirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            )
        } else {
            return Leaf(transient)
        }
    }
}

@MainActor enum S15 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        makeSubclass(mode: mode)
    }

    /// Classic imperative add/remove toggle.
    static func makeImperative(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style { $0.gap = 8 }
        let stable = ScenarioNodes.fixed("stable", width: 180, height: 56, color: Palette.blue)
        root.addSubnode(stable)
        let session = ScenarioSession()
        var visible = false
        session.start { [weak root] in
            guard let root, !root.isDisposed else { return }
            if visible {
                root.subnodes.first(where: { $0 !== stable })?.removeFromSupernode()
            } else {
                root.addSubnode(
                    ScenarioNodes.fixed("transient", width: 180, height: 56, color: Palette.pink)
                )
            }
            visible.toggle()
        }
        return ScenarioNodes.instance(
            .s15,
            root: root,
            inputs: "one-second add/remove toggle (imperative)",
            expected:
                "only session mutates; replacing/closing cancels it before detached trees can change",
            paths: ["root", "root/stable", "root/transient (alternating)"],
            session: session
        )
    }

    /// Dynamic Arrangement subclass mutating modifiers, wrappers, and leaf order.
    static func makeSubclass(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        let arranged = S15ArrangedContainer()
        root.addSubnode(arranged)

        let session = ScenarioSession()
        var phase = 0

        session.start { [weak root, weak arranged] in
            guard let root, !root.isDisposed, let arranged, !arranged.isDisposed else { return }
            phase = (phase + 1) % 4
            switch phase {
            case 0:
                // Phase 0: Base arrangement with both stable and transient
                arranged.showTransient = true
                arranged.hasMargin = false
                arranged.wrapInContainer = false
                arranged.isReversed = false
            case 1:
                // Phase 1: Apply margin modifier
                arranged.hasMargin = true
            case 2:
                // Phase 2: Wrap in conditional subcontainer and reverse leaf order
                arranged.hasMargin = false
                arranged.wrapInContainer = true
                arranged.isReversed = true
            case 3:
                // Phase 3: Remove container and remove transient leaf
                arranged.wrapInContainer = false
                arranged.isReversed = false
                arranged.showTransient = false
            default:
                break
            }
            // The description changed; the host re-resolves before its next snapshot (C32).
            arranged.markArrangementDirty()
        }

        return ScenarioNodes.instance(
            .s15,
            root: root,
            inputs:
                "Arrangement dynamic session: toggle leaf, modifier, conditional wrapper & reorder",
            expected:
                "stable NodeID across passes, wrapper recycled, CALayers preserved without leaks",
            paths: ["root", "root/arranged/stable", "root/arranged/transient"],
            session: session
        )
    }
}
