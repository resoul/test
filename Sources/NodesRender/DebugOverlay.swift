#if canImport(QuartzCore) && canImport(CoreText)
    import CoreGraphics
    import CoreText
    import LayoutCore
    import Nodes
    import QuartzCore

    /// What the debug overlay writes on a node's label.
    public enum DebugOverlayLabelStyle: Sendable, Hashable {
        /// The node's identity (`#42`), the number a log or a breakpoint shows. Identities are
        /// issued for the whole process in creation order, so they shift with every node made
        /// before the tree.
        case nodeID
        /// The node's type (`Text`, `Button`): what the box is.
        case typeName
        /// The node's 1-based place in reading order (`n7`), which depends on the tree and nothing
        /// else: for pictures that are compared, where one scene gaining a node must not change
        /// the labels of another.
        case treeOrder
    }

    /// Draws an outline and a label for every node that shows, as flat layers over the tree: a
    /// look at what layout produced, apart from how the nodes draw themselves.
    ///
    /// The overlay never takes part in layout, hit testing or accessibility: it reads
    /// ``NodeHost/debugFrames()`` and owns only the layers it makes, in one container that is
    /// the last sublayer of the layer it is given. Frames are in the host's root coordinates, so
    /// the overlay is a flat list and follows scrolling. Nodes that can take focus have a
    /// different colour from the rest. Labels are placed by a function that keeps the ones shown
    /// from overlapping or leaving the canvas; a label with no room is hidden and its outline
    /// stays. Label text is drawn into an image, not a text layer, so it is upright in a layer
    /// tree whose geometry is flipped, as on the Mac.
    ///
    /// Call ``update(for:in:scale:)`` after each drawing of the tree. The overlay draws only
    /// while ``NodeHost/showsDebugOverlay`` is true, and removes itself when it is not.
    @MainActor
    public final class DebugOverlay {
        private struct Entry {
            let outline: CALayer
            let label: CALayer
            var drawnLabel: String?
        }

        private let container = CALayer()
        private var entries: [NodeID: Entry] = [:]

        private static let plainColor = CGColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 0.9)
        private static let interactiveColor = CGColor(red: 0.2, green: 0.75, blue: 0.4, alpha: 0.9)
        private static let labelBackground = CGColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 0.75)
        private static let fontSize: CGFloat = 9

        /// What the labels show; takes effect at the next ``update(for:in:scale:)``.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var labelStyle: DebugOverlayLabelStyle = .nodeID

        /// Ownership: the caller owns the overlay. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init() {
            container.name = "debug-overlay"
            container.anchorPoint = .zero
            container.masksToBounds = false
            container.zPosition = 1_000_000
        }

        /// How many nodes are outlined; a hook for tests, not a rendering contract.
        public var outlinedCount: Int { entries.count }

        /// The container, or `nil` while the overlay is not mounted; a hook for tests that
        /// check nothing of the overlay is left behind.
        public var mountedContainer: CALayer? {
            container.superlayer == nil ? nil : container
        }

        /// Draws the overlay for `host` into `layer`, which is the layer the tree is drawn into,
        /// or takes it away when ``NodeHost/showsDebugOverlay`` is false. Layers made for
        /// earlier calls are reused, and those of nodes that no longer show are removed.
        ///
        /// Only nodes whose box meets the host's size get an outline: the rest are off screen, and
        /// a long list would otherwise cost a layer for every row.
        ///
        /// - Parameter scale: The pixels per point the labels are drawn for.
        public func update(for host: NodeHost, in layer: CALayer, scale: Double) {
            guard host.showsDebugOverlay else {
                unmount()
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            // The container goes last in the sublayer order as well as highest in `zPosition`:
            // rendering a layer into an image ignores `zPosition` and draws in array order.
            if container.superlayer !== layer || layer.sublayers?.last !== container {
                container.removeFromSuperlayer()
                layer.addSublayer(container)
            }
            let canvas = CGSize(width: host.size.width, height: host.size.height)
            container.frame = CGRect(origin: .zero, size: canvas)

            let bounds = CGRect(origin: .zero, size: canvas)
            let shown = host.debugFrames().enumerated().compactMap {
                order,
                item -> (item: DebugFrame, order: Int, frame: CGRect)? in
                let frame = CGRect(
                    x: item.frame.origin.x,
                    y: item.frame.origin.y,
                    width: item.frame.size.width,
                    height: item.frame.size.height
                )
                return frame.intersects(bounds) ? (item, order, frame) : nil
            }
            let candidates = shown.map { entry -> DebugOverlayLabelLayout.Candidate in
                let name: String
                switch labelStyle {
                case .nodeID: name = "\(entry.item.id)"
                case .typeName: name = entry.item.typeName
                case .treeOrder: name = "n\(entry.order + 1)"
                }
                let size =
                    "\(Int(entry.frame.width.rounded()))×\(Int(entry.frame.height.rounded()))"
                return DebugOverlayLabelLayout.Candidate(
                    outline: entry.frame,
                    depth: entry.item.depth,
                    order: entry.order,
                    fullText: "\(name) \(size)",
                    shortText: name
                )
            }
            let placements = DebugOverlayLabelLayout.place(
                candidates,
                canvas: canvas,
                fontSize: Self.fontSize
            )

            var active: Set<NodeID> = []
            for (entry, placement) in zip(shown, placements) {
                active.insert(entry.item.id)
                draw(entry.item, frame: entry.frame, placement: placement, scale: CGFloat(scale))
            }
            for id in Set(entries.keys).subtracting(active) {
                entries.removeValue(forKey: id)?.outline.removeFromSuperlayer()
            }
        }

        /// Takes the container and every layer of the overlay out of the layer tree.
        public func unmount() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for entry in entries.values { entry.outline.removeFromSuperlayer() }
            entries.removeAll()
            container.removeFromSuperlayer()
            CATransaction.commit()
        }

        private func draw(
            _ item: DebugFrame,
            frame: CGRect,
            placement: DebugOverlayLabelLayout.Placement?,
            scale: CGFloat
        ) {
            var entry = entries[item.id] ?? makeEntry()
            let color = item.isInteractive ? Self.interactiveColor : Self.plainColor
            entry.outline.frame = frame
            entry.outline.borderColor = color
            entry.outline.zPosition = CGFloat(item.depth)

            guard let placement else {
                entry.label.isHidden = true
                entry.drawnLabel = nil
                entries[item.id] = entry
                return
            }

            entry.label.isHidden = false
            // The label is a sublayer of the outline: root coordinates become outline-relative.
            entry.label.frame = placement.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            entry.label.contentsScale = scale
            let key = "\(placement.text)|\(item.isInteractive)|\(scale)"
            if entry.drawnLabel != key {
                entry.label.contents = Self.image(
                    of: placement.text,
                    size: placement.frame.size,
                    color: color,
                    scale: scale
                )
                entry.drawnLabel = key
            }
            entries[item.id] = entry
        }

        private func makeEntry() -> Entry {
            let outline = CALayer()
            outline.name = "debug-outline"
            outline.borderWidth = 1
            outline.masksToBounds = false
            outline.anchorPoint = .zero

            let label = CALayer()
            label.name = "debug-label"
            label.anchorPoint = .zero
            outline.addSublayer(label)
            container.addSublayer(outline)
            return Entry(outline: outline, label: label, drawnLabel: nil)
        }

        /// The label as an image, upright whatever the geometry of the layers around it.
        private static func image(
            of text: String,
            size: CGSize,
            color: CGColor,
            scale: CGFloat
        ) -> CGImage? {
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0,
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            else { return nil }

            context.scaleBy(x: scale, y: scale)
            context.setFillColor(labelBackground)
            context.fill(CGRect(origin: .zero, size: size))
            let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(
                    nil,
                    text as CFString,
                    [
                        kCTFontAttributeName: font,
                        kCTForegroundColorAttributeName: color,
                    ] as CFDictionary
                )
            )
            // The baseline sits a little above the bottom edge so the descenders stay inside.
            context.textPosition = CGPoint(x: 2, y: CTFontGetDescent(font) + 1)
            CTLineDraw(line, context)
            return context.makeImage()
        }
    }
#endif
