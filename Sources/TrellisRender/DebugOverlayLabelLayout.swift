import CoreGraphics

/// Chooses where each overlay label goes so that the labels that are shown never overlap
/// each other and never leave the canvas (defect #12) — a pure function over rectangles, with
/// no CALayer involved, so it is deterministic and testable on its own.
///
/// Labels are placed deepest node first, then in preorder, so a small node wins over the
/// container around it. Each label tries a fixed set of nearby positions — rows down from
/// the outline's top-left corner while they fit inside it, the row above the outline, then
/// its other corners — first with its full text, then with the short one, and is hidden when
/// no position is free.
/// Hidden text never hides the outline. Overlap is checked against the labels already
/// accepted, linearly: with a few hundred nodes that is nothing, and the overlay is a
/// diagnostic, not a render path.
///
/// Ownership: values in, values out. Isolation: none. Errors: none. Cancellation: not
/// applicable.
enum DebugOverlayLabelLayout {
    /// One node's outline and the two texts it could be labelled with, in root coordinates.
    struct Candidate {
        let outline: CGRect
        /// Nesting depth of the node — deeper nodes are placed first.
        let depth: Int
        /// Preorder index of the node — the tie-breaker among equal depths.
        let order: Int
        /// `label w×h`.
        let fullText: String
        /// `label` alone, used when the full text does not fit anywhere.
        let shortText: String
    }

    /// The chosen frame and text of one label, in root coordinates.
    struct Placement: Equatable {
        let frame: CGRect
        let text: String
    }

    /// Point width the label text takes at `fontSize` (Menlo is monospaced), plus a margin —
    /// the estimate the label layer's frame is set from, so it is what overlap means.
    static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        CGFloat(text.count) * fontSize * 0.62 + 4
    }

    static func labelHeight(fontSize: CGFloat) -> CGFloat { fontSize + 3 }

    /// Returns one entry per candidate, index-aligned: the placement, or `nil` when the label
    /// is hidden. `gap` is the minimum distance kept between two shown labels; with the
    /// default `0` labels may touch, never overlap.
    static func place(
        _ candidates: [Candidate],
        canvas: CGSize,
        fontSize: CGFloat,
        gap: CGFloat = 0
    ) -> [Placement?] {
        let height = labelHeight(fontSize: fontSize)
        let bounds = CGRect(origin: .zero, size: canvas)
        let order = candidates.indices.sorted { lhs, rhs in
            let left = candidates[lhs]
            let right = candidates[rhs]
            return left.depth != right.depth
                ? left.depth > right.depth : left.order < right.order
        }
        var accepted: [CGRect] = []
        var placements = [Placement?](repeating: nil, count: candidates.count)
        for index in order {
            let candidate = candidates[index]
            let outline = candidate.outline
            placement: for text in [candidate.fullText, candidate.shortText] {
                let width = textWidth(text, fontSize: fontSize)
                // Rows down the outline's left edge while they fit inside it (at least the
                // first), then above the outline and its other corners.
                let rowsInside = max(1, min(6, Int(outline.height / height)))
                let origins =
                    (0..<rowsInside).map { row in
                        CGPoint(x: outline.minX, y: outline.minY + CGFloat(row) * height)
                    } + [
                        CGPoint(x: outline.minX, y: outline.minY - height),
                        CGPoint(x: outline.maxX - width, y: outline.minY),
                        CGPoint(x: outline.minX, y: outline.maxY - height),
                        CGPoint(x: outline.maxX - width, y: outline.maxY - height),
                    ]
                for origin in origins {
                    let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
                    guard bounds.contains(frame) else { continue }

                    let padded = frame.insetBy(dx: -gap, dy: -gap)
                    if accepted.contains(where: { $0.intersects(padded) }) { continue }
                    accepted.append(frame)
                    placements[index] = Placement(frame: frame, text: text)
                    break placement
                }
            }
        }

        return placements
    }
}
