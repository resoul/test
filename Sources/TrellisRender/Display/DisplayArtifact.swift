import CoreGraphics

/// One rasterized bitmap produced by a `TextRasterizer` — the display-pipeline counterpart to
/// `TextMetrics` (T05). Carries `CGImage` directly rather than a `Data` copy per D54: T02's
/// Sendable compile-probe found `CGImage` safe to cross an isolation boundary on the pinned SDK,
/// and the measured cost of a defensive copy (~8-14ms/1000 lines) is not worth paying when it
/// is not required for correctness.
///
/// Ownership: the value is immutable and owned by its caller; `image` is retained for the
/// artifact's lifetime. Isolation: none — `Sendable` per D54's compile-probe. Errors: none.
/// Cancellation: not applicable — a cancelled raster job never produces one (`DisplayScheduler`).
public struct DisplayArtifact: Sendable {
    /// The rasterized bitmap, at `pixelWidth × pixelHeight` device pixels.
    ///
    /// Ownership: returns the retained image. Isolation: none. Errors: none. Cancellation: not
    /// applicable.
    public let image: CGImage

    /// Bitmap width in device pixels — `ceil(size.width * scale)`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let pixelWidth: Int

    /// Bitmap height in device pixels — `ceil(size.height * scale)`.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let pixelHeight: Int

    /// The pixel density this bitmap was rendered at — the value a consumer sets as
    /// `CALayer.contentsScale` (T07).
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let scale: Double

    /// Creates a display artifact, clamping an invalid `scale` to `1`.
    ///
    /// Ownership: the returned value retains `image`. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(image: CGImage, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.image = image
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}
