import Foundation

/// A platform-neutral affine transform applied around the **center** of a node frame.
///
/// Scale is applied first, then rotation, then translation. The pivot is the frame center —
/// the same point `CALayer` rotates around with its default `anchorPoint` `(0.5, 0.5)`, so
/// what `LayerRenderer` draws and what hit-testing computes agree (defect #30, D17). The
/// `around:` overloads take that pivot explicitly; the `in:` overloads derive it from a frame
/// and are the ones callers should reach for.
///
/// Ownership: the value is immutable and copied by layout descriptions. Isolation: none.
/// Errors: non-finite values normalize to identity components. Cancellation: not applicable.
public struct LayoutTransform: Sendable, Hashable {
    /// Horizontal scale.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scaleX: Double

    /// Vertical scale.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scaleY: Double

    /// Clockwise rotation in radians.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let rotationRadians: Double

    /// Horizontal translation in points.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let translationX: Double

    /// Vertical translation in points.
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let translationY: Double

    /// Identity transform.
    /// Ownership: immutable shared value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let identity = LayoutTransform()

    /// Creates an affine scale, rotation, and translation transform.
    ///
    /// Ownership: values are copied. Isolation: none. Errors: invalid values normalize safely.
    /// Cancellation: not applicable.
    public init(
        scaleX: Double = 1,
        scaleY: Double = 1,
        rotationRadians: Double = 0,
        translationX: Double = 0,
        translationY: Double = 0
    ) {
        self.scaleX = Self.valid(scaleX, fallback: 1)
        self.scaleY = Self.valid(scaleY, fallback: 1)
        self.rotationRadians = Self.valid(rotationRadians, fallback: 0)
        self.translationX = Self.valid(translationX, fallback: 0)
        self.translationY = Self.valid(translationY, fallback: 0)
    }

    /// Converts a point from this node's untransformed space into presentation space, pivoting
    /// around `pivot` — the frame center for a node frame (see `applying(_:in:)`).
    ///
    /// Ownership: the returned point is a value. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func applying(_ point: LayoutPoint, around pivot: LayoutPoint) -> LayoutPoint {
        let scaledX = (point.x - pivot.x) * scaleX
        let scaledY = (point.y - pivot.y) * scaleY
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)

        return LayoutPoint(
            x: pivot.x + cosine * scaledX - sine * scaledY + translationX,
            y: pivot.y + sine * scaledX + cosine * scaledY + translationY
        )
    }

    /// Converts a point from this node's untransformed space into presentation space, pivoting
    /// around the center of `frame` — the node's committed frame in the same coordinate space
    /// as `point`.
    ///
    /// Ownership: the returned point is a value. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func applying(_ point: LayoutPoint, in frame: LayoutFrame) -> LayoutPoint {
        applying(point, around: Self.center(of: frame))
    }

    /// Converts a point from presentation space into this node's untransformed space, pivoting
    /// around `pivot` — the frame center for a node frame (see `inverseApplying(_:in:)`).
    ///
    /// Ownership: the returned point is a value. Isolation: none. Errors: singular scales use
    /// one. Cancellation: not applicable.
    public func inverseApplying(_ point: LayoutPoint, around pivot: LayoutPoint) -> LayoutPoint {
        let translatedX = point.x - pivot.x - translationX
        let translatedY = point.y - pivot.y - translationY
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let rotatedX = cosine * translatedX + sine * translatedY
        let rotatedY = -sine * translatedX + cosine * translatedY

        return LayoutPoint(
            x: pivot.x + rotatedX / nonSingular(scaleX),
            y: pivot.y + rotatedY / nonSingular(scaleY)
        )
    }

    /// Converts a point from presentation space into this node's untransformed space, pivoting
    /// around the center of `frame` — the node's committed frame in the same coordinate space
    /// as `point`.
    ///
    /// Ownership: the returned point is a value. Isolation: none. Errors: singular scales use
    /// one. Cancellation: not applicable.
    public func inverseApplying(_ point: LayoutPoint, in frame: LayoutFrame) -> LayoutPoint {
        inverseApplying(point, around: Self.center(of: frame))
    }

    private static func center(of frame: LayoutFrame) -> LayoutPoint {
        LayoutPoint(x: frame.origin.x + frame.width / 2, y: frame.origin.y + frame.height / 2)
    }

    private static func valid(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    private func nonSingular(_ value: Double) -> Double { abs(value) < 0.000_001 ? 1 : value }
}
