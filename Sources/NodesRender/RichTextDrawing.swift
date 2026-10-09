#if canImport(CoreText)
    import CoreGraphics
    import CoreText
    import Foundation
    import LayoutCore
    import RichTextCore
    import ThemeCore

    /// Measures a rich text for the layout engine, on any thread, from the same block layouts
    /// that draw it.
    struct RichTextMeasurer: ContentMeasurer {
        let text: RichText
        let metrics: RichMetrics
        let maxLines: Int?
        let measurements: RichTextMeasurements

        func minContentWidth() -> Double {
            text.blocks.map { measurements.widths($0, metrics: metrics).min }.max() ?? 0
        }

        func maxContentWidth() -> Double {
            text.blocks.map { measurements.widths($0, metrics: metrics).max }.max() ?? 0
        }

        func height(forWidth width: Double) -> Double {
            let geometries = text.blocks.map {
                measurements.geometry($0, width: width, metrics: metrics)
            }
            return ceil(
                RichStack(geometries, spacing: metrics.blockSpacing, maxLines: maxLines).height
            )
        }

        func firstBaseline(forWidth width: Double) -> Double? {
            text.blocks.first.map {
                measurements.geometry($0, width: width, metrics: metrics).firstBaseline
            }
        }
    }

    /// A rich text laid out at one width: the blocks that show, where each goes, and what to
    /// draw and to ask about a point.
    struct RichPlacedLayout {
        let blocks: [RichBlockLayout]
        let stack: RichStack
        let width: Double

        init(blocks: [RichBlockLayout], width: Double, metrics: RichMetrics, maxLines: Int?) {
            let stack = RichStack(
                blocks.map(\.geometry),
                spacing: metrics.blockSpacing,
                maxLines: maxLines
            )
            self.blocks = Array(blocks.prefix(stack.tops.count))
            self.stack = stack
            self.width = width
            self.metrics = metrics
        }

        private let metrics: RichMetrics

        /// The origin of a block's text, from the top left of the whole text.
        private func origin(of index: Int) -> CGPoint {
            CGPoint(
                x: blocks[index].geometry.insets.left,
                y: stack.tops[index] + blocks[index].geometry.insets.top
            )
        }

        /// The link under `point`, from the top left of the text, y down.
        func link(at point: CGPoint) -> URL? {
            links(at: point)
        }

        private func links(at point: CGPoint) -> URL? {
            for index in blocks.indices {
                let origin = origin(of: index)
                let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                for mark in blocks[index].marks {
                    if case .link(let url) = mark.decoration, mark.rect.contains(local) {
                        return url
                    }
                }
            }
            return nil
        }

        /// Whether `maxLines` cuts any of the text.
        var isCut: Bool {
            blocks.indices.contains { index in
                guard let shown = stack.shown[index] else { return false }

                return blocks[index].lines.count > shown
            }
        }

        /// Draws the text into a box `size` points, origin at the bottom left as Core Graphics
        /// has it; the layout itself is measured from the top, y down. A link given in
        /// `highlighting` is filled behind its words.
        func draw(
            in context: CGContext,
            size: CGSize,
            colors: RichColors,
            highlighting highlighted: URL? = nil
        ) {
            func flipped(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: rect.minX,
                    y: size.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
            }
            func fill(_ color: Color, alpha: Double = 1, _ rect: CGRect) {
                context.setFillColor(
                    CGColor(
                        red: CGFloat(color.red),
                        green: CGFloat(color.green),
                        blue: CGFloat(color.blue),
                        alpha: CGFloat(color.alpha * alpha)
                    )
                )
                context.fill(flipped(rect))
            }

            context.textMatrix = .identity
            for (index, layout) in blocks.enumerated() {
                let geometry = layout.geometry
                let shown = stack.shown[index]
                let top = stack.tops[index]
                let height = geometry.height(showing: shown)
                let origin = origin(of: index)

                switch layout.block {
                case .paragraph: break
                case .code:
                    let plate = flipped(CGRect(x: 0, y: top, width: width, height: height))
                    let radius = CGFloat(metrics.codePadding * 0.75)
                    context.addPath(
                        CGPath(
                            roundedRect: plate,
                            cornerWidth: radius,
                            cornerHeight: radius,
                            transform: nil
                        )
                    )
                    context.setFillColor(
                        CGColor(
                            red: CGFloat(colors.text.red),
                            green: CGFloat(colors.text.green),
                            blue: CGFloat(colors.text.blue),
                            alpha: CGFloat(colors.text.alpha * 0.08)
                        )
                    )
                    context.fillPath()
                case .quote:
                    fill(
                        colors.bar,
                        CGRect(x: 0, y: top, width: metrics.quoteBarWidth, height: height)
                    )
                }

                let count = min(shown ?? layout.lines.count, layout.lines.count)
                let textBottom = count == 0 ? Double.infinity : geometry.lineBottoms[count - 1]

                for mark in layout.marks where Double(mark.rect.midY) <= textBottom {
                    let rect = mark.rect.offsetBy(dx: origin.x, dy: origin.y)
                    switch mark.decoration {
                    case .background: fill(colors.text, alpha: 0.1, rect)
                    case .strike: fill(colors.text, rect)
                    case .underline: fill(colors.text, rect)
                    case .link(let url):
                        if url == highlighted { fill(colors.link, alpha: 0.25, rect) }
                    }
                }

                for lineIndex in 0..<count {
                    var line = layout.lines[lineIndex]
                    var ctLine = line.line
                    if lineIndex == count - 1, shown != nil, layout.lines.count > count {
                        ctLine = layout.truncated(line, width: layout.textWidth)
                        line = RichBlockLayout.Line(
                            line: ctLine,
                            x: line.x,
                            baseline: line.baseline,
                            ascent: line.ascent,
                            descent: line.descent,
                            range: line.range
                        )
                    }
                    context.textPosition = CGPoint(
                        x: origin.x + line.x,
                        y: size.height - (origin.y + line.baseline)
                    )
                    CTLineDraw(ctLine, context)
                }
            }
        }

        /// Where the links are, from the top left of the text, y down.
        var linkRects: [CGRect] {
            blocks.indices.flatMap { index in
                let origin = origin(of: index)
                return blocks[index].marks.compactMap { mark -> CGRect? in
                    if case .link = mark.decoration {
                        return mark.rect.offsetBy(dx: origin.x, dy: origin.y)
                    }
                    return nil
                }
            }
        }
    }

    extension RichBlockLayout {
        /// `line` cut to `width` with "…", from its start to the end of the block's text.
        func truncated(_ line: Line, width: Double) -> CTLine {
            let start = line.range.location
            let rest = CFAttributedStringCreateWithSubstring(
                nil,
                string,
                CFRange(location: start, length: CFAttributedStringGetLength(string) - start)
            )!
            let restLine = CTLineCreateWithAttributedString(rest)
            let attributes = CFAttributedStringGetAttributes(string, start, nil)
            let ellipsis = CFAttributedStringCreate(nil, "\u{2026}" as CFString, attributes)!
            let token = CTLineCreateWithAttributedString(ellipsis)
            return CTLineCreateTruncatedLine(restLine, width, .end, token) ?? line.line
        }
    }
#endif
