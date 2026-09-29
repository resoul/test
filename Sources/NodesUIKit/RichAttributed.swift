#if canImport(UIKit)
    import Foundation
    import NodesRender
    import RichTextCore
    import UIKit

    /// How rich text looks in a text view, and how what the view holds is read back.
    struct RichAttributedStyle {
        var font: UIFont
        var color: UIColor
        /// The color of a quotation.
        var quoteColor: UIColor
        /// Behind code.
        var codeBackground: UIColor

        static var standard: RichAttributedStyle {
            RichAttributedStyle(
                font: .preferredFont(forTextStyle: .body),
                color: .label,
                quoteColor: .secondaryLabel,
                codeBackground: .secondarySystemFill
            )
        }
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
                let kind = run.kind ?? .paragraph
                var attributes: [NSAttributedString.Key: Any] = [
                    blockKey: tag(kind),
                    .paragraphStyle: paragraphStyle(kind, style: style, isFirst: blockIndex == 0),
                ]
                switch kind {
                case .paragraph:
                    attributes[.font] = font(run.attributes.marks, base: style.font)
                    attributes[.foregroundColor] = style.color
                case .quote:
                    attributes[.font] = font(run.attributes.marks, base: style.font)
                    attributes[.foregroundColor] = style.quoteColor
                case .code:
                    attributes[.font] = font(.mono, base: style.font)
                    attributes[.foregroundColor] = style.color
                    attributes[.backgroundColor] = style.codeBackground
                }
                if case .code = kind {
                    // Code has no marks and no links.
                } else {
                    if run.attributes.marks.contains(.strike) {
                        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if run.attributes.marks.contains(.underline) {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if let link = run.attributes.link { attributes[.link] = link }
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
                if run.text == "\n" { blockIndex += 1 }
            }
            return result
        }

        private static func paragraphStyle(
            _ kind: RichText.Kind,
            style: RichAttributedStyle,
            isFirst: Bool
        ) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = isFirst ? 0 : (style.font.pointSize * 0.6).rounded()
            if kind == .quote {
                paragraph.firstLineHeadIndent = 14
                paragraph.headIndent = 14
            }
            return paragraph
        }

        // MARK: Attributes to text

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
