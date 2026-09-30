#if canImport(UIKit)
    import Foundation
    import NodesRender
    import RichTextCore
    import UIKit

    /// How rich text looks in a text view, and how what the view holds is read back.
    struct RichAttributedStyle {
        var font: UIFont
        var color: UIColor
        /// The color of a quotation, and of the bar beside it.
        var quoteColor: UIColor

        static var standard: RichAttributedStyle {
            RichAttributedStyle(
                font: .preferredFont(forTextStyle: .body),
                color: .label,
                quoteColor: .secondaryLabel
            )
        }

        /// The space between one block and the next.
        var blockSpacing: CGFloat { (font.pointSize * 0.6).rounded() }
        /// How wide the bar beside a quotation is.
        var quoteBarWidth: CGFloat { 3 }
        /// How far a quotation's text is from the left edge: the bar and a gap.
        var quoteIndent: CGFloat { quoteBarWidth + blockSpacing }
        /// The space between the edge of the plate behind code and its text.
        var codePadding: CGFloat { (font.pointSize * 0.5).rounded() }
    }

    /// The conversion between `RichText` and the attributed text of a `UITextView`: the marks
    /// become fonts, underline, strikethrough and links; the kind of each block is kept in an
    /// attribute on all its characters, the `"\n"` that ends it included, so that the view can
    /// change the text freely and the blocks can still be read back. Colors and sizes are the
    /// view's own and are never read back.
    enum RichAttributed {
        static let blockKey = NSAttributedString.Key("espalier.block")

        // MARK: Kinds

        static func tag(_ kind: RichText.Kind) -> String {
            switch kind {
            case .paragraph: "p"
            case .quote: "q"
            case .code(let language): language.map { "c:" + $0 } ?? "c"
            }
        }

        static func kind(ofTag tag: String) -> RichText.Kind? {
            switch tag {
            case "p": return .paragraph
            case "q": return .quote
            case "c": return .code(language: nil)
            default:
                guard tag.hasPrefix("c:") else { return nil }

                return .code(language: String(tag.dropFirst(2)))
            }
        }

        // MARK: Fonts

        /// `base` set with `marks`: bold and italic are traits of its face, monospaced is the
        /// system's monospaced face a little smaller.
        static func font(_ marks: Marks, base: UIFont) -> UIFont {
            guard !marks.isEmpty else { return base }

            var descriptor = base.fontDescriptor
            var size = base.pointSize
            if marks.contains(.mono) {
                let mono = UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
                descriptor = mono.fontDescriptor
                size = mono.pointSize
            }
            var traits = descriptor.symbolicTraits
            if marks.contains(.bold) { traits.insert(.traitBold) }
            if marks.contains(.italic) { traits.insert(.traitItalic) }
            return UIFont(
                descriptor: descriptor.withSymbolicTraits(traits) ?? descriptor,
                size: size
            )
        }

        /// The marks a font has beyond those of `base`.
        static func marks(of font: UIFont, base: UIFont) -> Marks {
            let traits = font.fontDescriptor.symbolicTraits
            let own = base.fontDescriptor.symbolicTraits
            var marks: Marks = []
            if traits.contains(.traitBold), !own.contains(.traitBold) { marks.insert(.bold) }
            if traits.contains(.traitItalic), !own.contains(.traitItalic) { marks.insert(.italic) }
            if traits.contains(.traitMonoSpace), !own.contains(.traitMonoSpace) {
                marks.insert(.mono)
            }
            return marks
        }

        // MARK: Text to attributes

        static func attributedString(
            _ text: RichText,
            style: RichAttributedStyle = .standard
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            var blockIndex = 0
            for run in text.platformRuns {
                let attributes = Self.attributes(
                    kind: run.kind ?? .paragraph,
                    style: style,
                    isFirst: blockIndex == 0,
                    marks: run.attributes.marks,
                    link: run.attributes.link
                )
                result.append(NSAttributedString(string: run.text, attributes: attributes))
                if run.text == "\n" { blockIndex += 1 }
            }
            return result
        }

        /// The attributes text of `kind` with `marks` and `link` has in a view: the kind tag, the
        /// paragraph style, font, colors, and the marks the platform draws itself. Code has no
        /// marks and no link. `isFirst` is whether the block is the first: it has no space above
        /// it.
        static func attributes(
            kind: RichText.Kind,
            style: RichAttributedStyle,
            isFirst: Bool,
            marks: Marks = [],
            link: URL? = nil
        ) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                blockKey: tag(kind),
                .paragraphStyle: paragraphStyle(kind, style: style, isFirst: isFirst),
            ]
            switch kind {
            case .paragraph:
                attributes[.font] = font(marks, base: style.font)
                attributes[.foregroundColor] = style.color
            case .quote:
                attributes[.font] = font(marks, base: style.font)
                attributes[.foregroundColor] = style.quoteColor
            case .code:
                attributes[.font] = font(.mono, base: style.font)
                attributes[.foregroundColor] = style.color
            }
            if case .code = kind {
                return attributes
            }
            if marks.contains(.strike) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if marks.contains(.underline) {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link { attributes[.link] = link }
            return attributes
        }

        private static func paragraphStyle(
            _ kind: RichText.Kind,
            style: RichAttributedStyle,
            isFirst: Bool
        ) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            switch kind {
            case .paragraph:
                paragraph.paragraphSpacingBefore = isFirst ? 0 : style.blockSpacing
            case .quote:
                paragraph.paragraphSpacingBefore = isFirst ? 0 : style.blockSpacing
                paragraph.firstLineHeadIndent = style.quoteIndent
                paragraph.headIndent = style.quoteIndent
            case .code:
                // The plate behind code (`RichBlockFragment`) reaches `codePadding` beyond the
                // lines on every side: the space above and below is kept for it, and the lines
                // are set in from both edges.
                let padding = style.codePadding
                paragraph.paragraphSpacingBefore = (isFirst ? 0 : style.blockSpacing) + padding
                paragraph.paragraphSpacing = padding
                paragraph.firstLineHeadIndent = padding
                paragraph.headIndent = padding
                paragraph.tailIndent = -padding
            }
            return paragraph
        }

        // MARK: Attributes to text

        /// The marks the attributes of a piece of text carry: the font's traits beyond those of
        /// the base font, strikethrough and underline.
        static func marks(
            of attributes: [NSAttributedString.Key: Any],
            style: RichAttributedStyle
        ) -> Marks {
            var marks: Marks = []
            if let font = attributes[.font] as? UIFont {
                marks = Self.marks(of: font, base: style.font)
            }
            if let value = attributes[.strikethroughStyle] as? Int, value != 0 {
                marks.insert(.strike)
            }
            if let value = attributes[.underlineStyle] as? Int, value != 0 {
                marks.insert(.underline)
            }
            return marks
        }

        /// The text a view holds, read back: runs from the attributes, blocks from the kind
        /// attribute and the newlines. Text without a kind — pasted from elsewhere — is in the
        /// block it landed in.
        static func richText(
            from text: NSAttributedString,
            style: RichAttributedStyle = .standard
        ) -> RichText {
            var runs: [PlatformRun] = []
            let whole = NSRange(location: 0, length: text.length)
            text.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
                let piece = text.attributedSubstring(from: range).string
                let marks = Self.marks(of: attributes, style: style)
                var link: URL?
                if let url = attributes[.link] as? URL {
                    link = url
                } else if let string = attributes[.link] as? String {
                    link = URL(string: string)
                }
                let kind = (attributes[blockKey] as? String).flatMap(kind(ofTag:))
                runs.append(
                    PlatformRun(piece, attributes: Attributes(marks: marks, link: link), kind: kind)
                )
            }
            return RichText(platformRuns: runs)
        }
    }
#endif
