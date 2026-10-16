/// Where the content a tree draws — text — is made.
public enum DrawingMode: Sendable {
    /// On the main thread, inside the render: the content is in the layer when the render
    /// returns. The default.
    case synchronous
    /// In the background, for drawings that can be: the render returns at once, the layer
    /// keeps what it showed — nothing, the first time — and takes the new bitmap when it is
    /// ready, so that drawing text does not hold up a frame of scrolling. Content that changes
    /// shows without the cross-fade an animated render gives synchronous content.
    case asynchronous
}

/// How far from the screen drawn content is kept, in lengths of the host's window.
public struct DisplayRange: Sendable, Equatable {
    /// A drawing is made while its node is within this distance of the screen; one farther off
    /// waits, blank or showing what it last showed, until it comes near.
    public var drawDistance: Double

    /// A drawing farther than this loses its bitmap, which is made again when the node comes
    /// back within `drawDistance`. Not less than `drawDistance`: between the two a bitmap is
    /// kept but not made, so that a scroll that wavers at the edge does not draw and release
    /// the same text again and again.
    public var releaseDistance: Double

    /// - Parameters:
    ///   - drawDistance: One window length by default.
    ///   - releaseDistance: Two window lengths by default.
    public init(drawDistance: Double = 1, releaseDistance: Double = 2) {
        self.drawDistance = max(0, drawDistance)
        self.releaseDistance = max(self.drawDistance, releaseDistance)
    }
}
