/// Pixel scale used to snap logical points to stable device pixels.
///
/// Two hosts with different `scale` (a Retina Mac window and a plain-scale external display,
/// or an iPhone and a tvOS overscan-adjusted screen) legitimately round the same logical
/// frame to different physical pixels — that is not a layout defect (F01).
///
/// Ownership: the policy is an immutable value owned by the layout caller. Isolation: none.
/// Errors: non-positive or non-finite scales normalize to one. Cancellation: not applicable.
public struct PixelRoundingPolicy: Sendable, Hashable {
    /// Positive, finite pixel scale.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scale: Double

    /// Creates a pixel rounding policy.
    ///
    /// Ownership: the returned policy is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(scale: Double = 1) {
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    /// Snaps one logical value to the nearest physical pixel at this scale.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public func snapped(_ value: Double) -> Double {
        (value * scale).rounded() / scale
    }
}

extension LayoutFrame {
    /// Snaps origin and size to this policy's pixel grid.
    ///
    /// Ownership: returns a new frame. Isolation: none. Errors: none. Cancellation: not applicable.
    public func rounded(to policy: PixelRoundingPolicy) -> LayoutFrame {
        LayoutFrame(
            origin: LayoutPoint(x: policy.snapped(origin.x), y: policy.snapped(origin.y)),
            width: policy.snapped(width),
            height: policy.snapped(height)
        )
    }
}
