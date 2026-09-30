#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import Foundation
    import RichTextCore

    /// A paragraph of a rich text editor's text, laid out and drawn with what its kind adds to
    /// the lines: a bar beside a quotation, a rounded plate behind code. Both are drawn here
    /// rather than made of text attributes, so that the plate reaches past the lines by its
    /// padding and the bar is as high as the block. The kind, and the numbers, are read from the
    /// attributes of the paragraph (`RichAttributed.attributes`).
    final class RichBlockFragment: NSTextLayoutFragment {
        private struct Decoration {
            let kind: RichText.Kind
            let paragraph: NSParagraphStyle
            let color: NSColor
        }

        private var decoration: Decoration? {
            guard let paragraph = textElement as? NSTextParagraph,
                paragraph.attributedString.length > 0
            else { return nil }

            let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            guard let tag = attributes[RichAttributed.blockKey] as? String,
                let kind = RichAttributed.kind(ofTag: tag), kind != .paragraph,
                let style = attributes[.paragraphStyle] as? NSParagraphStyle
            else { return nil }

            return Decoration(
                kind: kind,
                paragraph: style,
                color: attributes[.foregroundColor] as? NSColor ?? .labelColor
            )
        }

        /// The left and right edges of the block: where the text container's lines begin and
        /// end. A fragment's coordinates start where its lines do, indent included, so the left
        /// edge of a quotation or code is before zero.
        private var edges: (left: CGFloat, right: CGFloat) {
            let container = textLayoutManager?.textContainer
            let padding = container?.lineFragmentPadding ?? 0
            let origin = layoutFragmentFrame.minX
            let width = container.map { $0.size.width } ?? 0
            let right = width.isFinite && width > 0 && width < 100_000 ? width : nil
            return (padding - origin, (right ?? layoutFragmentFrame.maxX) - padding - origin)
        }

        /// What the block adds to its lines, in the fragment's coordinates: the plate of code,
        /// the bar of a quotation.
        private var decorationRect: CGRect? {
            guard let decoration, let first = textLineFragments.first,
                let last = textLineFragments.last
            else { return nil }

            let (left, right) = edges
            var top = first.typographicBounds.minY
            var bottom = last.typographicBounds.maxY
            switch decoration.kind {
            case .code:
                let padding = decoration.paragraph.headIndent
                top -= padding
                bottom += padding
                return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            case .quote:
                return CGRect(
                    x: left,
                    y: top,
                    width: RichAttributedStyle.standard.quoteBarWidth,
                    height: bottom - top
                )
            case .paragraph:
                return nil
            }
        }

        override var renderingSurfaceBounds: CGRect {
            guard let rect = decorationRect else { return super.renderingSurfaceBounds }

            return super.renderingSurfaceBounds.union(rect)
        }

        override func draw(at point: CGPoint, in context: CGContext) {
            if let decoration, let rect = decorationRect?.offsetBy(dx: point.x, dy: point.y) {
                context.saveGState()
                switch decoration.kind {
                case .code:
                    let radius = decoration.paragraph.headIndent * 0.75
                    context.addPath(
                        CGPath(
                            roundedRect: rect,
                            cornerWidth: radius,
                            cornerHeight: radius,
                            transform: nil
                        )
                    )
                    context.setFillColor(decoration.color.withAlphaComponent(0.08).cgColor)
                    context.fillPath()
                case .quote:
                    context.setFillColor(decoration.color.cgColor)
                    context.fill(rect)
                case .paragraph:
                    break
                }
                context.restoreGState()
            }
            super.draw(at: point, in: context)
        }
    }

    /// Gives the text layout manager of a rich text editor's view the fragments that draw the
    /// bars and plates. The view holds it: the layout manager does not.
    final class RichBlockFragments: NSObject, NSTextLayoutManagerDelegate {
        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: any NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            RichBlockFragment(textElement: textElement, range: textElement.elementRange)
        }
    }
#endif
