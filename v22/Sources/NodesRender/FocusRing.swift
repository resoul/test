#if canImport(QuartzCore)
    import LayoutCore
    import Nodes
    import QuartzCore

    /// The ring around the focused node that keyboard focus shows on iPad and Mac. The
    /// adapter owns one and updates it after every drawing.
    ///
    /// Ownership: the ring owns its layer. Isolation: MainActor. Errors: none. Cancellation:
    /// not applicable.
    @MainActor
    public final class FocusRing {
        private let layer = CALayer()

        /// Ownership: the caller owns the ring. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init() {
            layer.borderWidth = 3
            layer.isHidden = true
        }

        /// Shows the ring around `item`, in `container`'s coordinates and above its other
        /// sublayers, or hides it for `nil`.
        ///
        /// Ownership: adds the ring's layer to `container`. Isolation: MainActor. Errors:
        /// none. Cancellation: not applicable.
        public func show(around item: FocusItem?, color: CGColor, in container: CALayer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            if container.sublayers?.last !== layer {
                container.addSublayer(layer)
            }
            guard let item else {
                layer.isHidden = true
                return
            }

            let outset = 4.0
            layer.isHidden = false
            layer.borderColor = color
            layer.cornerRadius = CGFloat(item.cornerRadius + outset)
            layer.frame = CGRect(
                x: item.frame.origin.x - outset,
                y: item.frame.origin.y - outset,
                width: item.frame.size.width + 2 * outset,
                height: item.frame.size.height + 2 * outset
            )
        }
    }
#endif
