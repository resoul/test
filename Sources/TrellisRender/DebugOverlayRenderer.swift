import CoreGraphics
import QuartzCore
import TrellisCore

/// How the debug overlay names a node in its label (defect #11).
///
/// Ownership: a plain value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum DebugOverlayLabelStyle: Sendable, Hashable {
    /// The runtime `NodeID` (`#42`), the same number the pipeline log prints — for reading
    /// an overlay next to a log. Issued process-wide in creation order, so it shifts with
    /// every node created before this tree.
    case runtimeID

    /// The node's 1-based position in a preorder walk of the mounted tree (`n7`) — a
    /// representation only, stable across processes and unaffected by nodes created
    /// elsewhere. For reference screenshots: adding a node to one scene leaves every other
    /// scene's labels as they were. Nothing else — logs, snapshots, caches, layer registry —
    /// uses it.
    case treeOrder
}

/// Draws every committed node's frame and label as flat, non-interactive CALayers on top of
/// the host layer (C25) — a diagnostic view of what the layout engine actually produced,
/// independent of the main `LayerRenderer` pass.
///
/// The overlay never participates in layout: it reads `Node.calculatedFrame` after a commit
/// and owns only the layers it created, in one container sublayer of the host. Frames are
/// root-absolute, so the overlay is a flat list, not a mirror of the node tree — reparenting
/// in the logical tree never moves an overlay layer, it only redraws it. Nodes managed by an
/// `Arrangement` (an owner's `Leaf`s and implicit wrappers) are outlined in a second colour so
/// resolver decisions are visible next to manual ones. Labels are laid out by
/// `DebugOverlayLabelLayout` so the ones shown never overlap or leave the canvas; a label
/// with no room is hidden, its outline stays.
///
/// Ownership: retains only its own container and per-node layers, never the node tree or the
/// host layer. Isolation: MainActor. Errors: nodes without a committed frame are skipped.
/// Cancellation: `unmount()` removes every owned layer; a later `apply` starts fresh.
@MainActor
public final class DebugOverlayRenderer {
    private struct Entry {
        let outline: CALayer
        let label: CATextLayer
    }

    private struct Outlined {
        let node: Node
        let frame: CGRect
        let depth: Int
    }

    private let container = CALayer()
    private var entries: [NodeID: Entry] = [:]

    /// Outline colour for nodes laid out from their own base `style`.
    private static let manualColor = ThemeColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 0.9)
    /// Outline colour for nodes whose effective style comes from an `Arrangement` (D12).
    private static let arrangedColor = ThemeColor(red: 0.98, green: 0.58, blue: 0.2, alpha: 0.9)
    private static let labelBackground = ThemeColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 0.75)
    private static let fontSize: CGFloat = 9

    /// What the labels show; takes effect at the next `apply`.
    ///
    /// Ownership: the renderer stores the value. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var labelStyle: DebugOverlayLabelStyle = .runtimeID

    /// Creates an overlay with no layers mounted.
    ///
    /// Ownership: the caller owns the renderer. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {
        container.name = "trellis.debug-overlay"
        container.anchorPoint = CGPoint(x: 0, y: 0)
        container.masksToBounds = false
        container.zPosition = 1_000_000
    }

    /// Number of nodes currently outlined — a test hook, not a rendering contract.
    ///
    /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    public var outlinedCount: Int { entries.count }

    /// The overlay's container layer, or `nil` while unmounted — a test hook for asserting
    /// that nothing of the overlay survives `unmount()`.
    ///
    /// Ownership: borrowed; the renderer keeps ownership. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public var mountedContainer: CALayer? { container.superlayer == nil ? nil : container }

    /// Redraws the overlay for the tree under `root` from its committed frames, on top of
    /// every other sublayer of `hostLayer`. Reuses per-node layers across calls and removes
    /// the ones whose node is no longer in the tree.
    ///
    /// Ownership: mounts the container on `hostLayer` if needed; never touches other
    /// sublayers. Isolation: MainActor. Errors: nodes without a `calculatedFrame` are skipped
    /// and logged. Cancellation: not applicable.
    public func apply(root: Node, on hostLayer: CALayer, request: HostRenderRequest) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Keep the container last in the host's sublayer order as well as highest in
        // `zPosition`: `CALayer.render(in:)` (screenshot export) ignores `zPosition` and
        // draws sublayers in array order.
        if container.superlayer !== hostLayer || hostLayer.sublayers?.last !== container {
            container.removeFromSuperlayer()
            hostLayer.addSublayer(container)
        }
        let canvas = CGSize(
            width: request.bounds.origin.x + request.bounds.width,
            height: request.bounds.origin.y + request.bounds.height
        )
        container.frame = CGRect(origin: .zero, size: canvas)
        container.contentsScale = CGFloat(request.scale)

        var outlined: [Outlined] = []
        collect(node: root, depth: 0, request: request, into: &outlined)
        let candidates = outlined.enumerated().map { order, item in
            let label: String
            switch labelStyle {
            case .runtimeID: label = "\(item.node.id)"
            case .treeOrder: label = "n\(order + 1)"
            }
            let size = "\(Int(item.frame.width.rounded()))×\(Int(item.frame.height.rounded()))"
            return DebugOverlayLabelLayout.Candidate(
                outline: item.frame,
                depth: item.depth,
                order: order,
                fullText: "\(label) \(size)",
                shortText: label
            )
        }
        let placements = DebugOverlayLabelLayout.place(
            candidates,
            canvas: canvas,
            fontSize: Self.fontSize
        )

        var active: Set<NodeID> = []
        for (item, placement) in zip(outlined, placements) {
            active.insert(item.node.id)
            draw(item, placement: placement, scale: CGFloat(request.scale))
        }
        for identity in Set(entries.keys).subtracting(active) {
            guard let entry = entries.removeValue(forKey: identity) else { continue }
            entry.outline.removeFromSuperlayer()
            Log.on(.layer, "overlay-remove", host: request.hostID, node: identity)
        }
    }

    /// Removes the container and every per-node layer from the host.
    ///
    /// Ownership: releases all owned layers. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func unmount() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in entries.values { entry.outline.removeFromSuperlayer() }
        entries.removeAll()
        container.removeFromSuperlayer()
        CATransaction.commit()
        Log.on(.layer, "overlay-unmount")
    }

    /// Preorder walk: the order the tree-order labels count in.
    private func collect(
        node: Node,
        depth: Int,
        request: HostRenderRequest,
        into outlined: inout [Outlined]
    ) {
        guard let frame = node.calculatedFrame else {
            Log.on(.layer, "overlay-missing-frame", host: request.hostID, node: node.id)
            return
        }
        outlined.append(
            Outlined(
                node: node,
                frame: CGRect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                ),
                depth: depth
            )
        )
        for child in node.subnodes {
            collect(node: child, depth: depth + 1, request: request, into: &outlined)
        }
    }

    private func draw(
        _ item: Outlined,
        placement: DebugOverlayLabelLayout.Placement?,
        scale: CGFloat
    ) {
        let entry = entries[item.node.id] ?? makeEntry(for: item.node.id)
        let color =
            item.node.arrangementEffectiveStyle == nil ? Self.manualColor : Self.arrangedColor
        entry.outline.frame = item.frame
        entry.outline.borderColor = cgColor(color)
        entry.outline.contentsScale = scale
        entry.outline.zPosition = CGFloat(item.depth)

        entry.label.contentsScale = scale
        entry.label.backgroundColor = cgColor(Self.labelBackground)
        entry.label.foregroundColor = cgColor(color)
        if let placement {
            entry.label.isHidden = false
            entry.label.string = placement.text
            // The label is a sublayer of the outline: root coordinates → outline-relative.
            entry.label.frame = placement.frame.offsetBy(dx: -item.frame.minX, dy: -item.frame.minY)
        } else {
            entry.label.isHidden = true
            entry.label.string = nil
        }
    }

    private func makeEntry(for identity: NodeID) -> Entry {
        let outline = CALayer()
        outline.name = "trellis.debug-outline"
        outline.borderWidth = 1
        outline.masksToBounds = false
        outline.anchorPoint = CGPoint(x: 0, y: 0)

        let label = CATextLayer()
        label.name = "trellis.debug-label"
        label.font = "Menlo" as CFString
        label.fontSize = Self.fontSize
        label.alignmentMode = .left
        label.truncationMode = .none
        label.isWrapped = false
        label.anchorPoint = CGPoint(x: 0, y: 0)
        outline.addSublayer(label)

        container.addSublayer(outline)
        let entry = Entry(outline: outline, label: label)
        entries[identity] = entry
        return entry
    }
}

private func cgColor(_ color: ThemeColor) -> CGColor {
    CGColor(
        red: CGFloat(color.red),
        green: CGFloat(color.green),
        blue: CGFloat(color.blue),
        alpha: CGFloat(color.alpha)
    )
}
