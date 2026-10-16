// AppKit only where UIKit is not, as the rest of this module.
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import ThemeCore

    extension DisplayConditions {
        /// The conditions `appearance` and the system's accessibility settings ask for: light
        /// or dark, Increase Contrast, Reduce Motion. The Mac has no text size setting: the
        /// scale is 1.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        @MainActor
        public init(_ appearance: NSAppearance) {
            let workspace = NSWorkspace.shared
            self.init(
                colorScheme: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark : .light,
                highContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                textScale: 1,
                reducesMotion: workspace.accessibilityDisplayShouldReduceMotion
            )
        }
    }

    extension Theme {
        /// The theme's values for the conditions `appearance` asks for.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        @MainActor
        public func resolved(for appearance: NSAppearance) -> ResolvedTheme {
            resolved(for: DisplayConditions(appearance))
        }
    }

    extension NSColor {
        /// The color, in sRGB.
        ///
        /// Ownership: returns a new object. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public convenience init(_ color: Color) {
            self.init(
                srgbRed: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
        }

        /// A color that follows the appearance it is drawn in — light or dark, more
        /// contrast — as the system's colors do.
        ///
        /// Ownership: returns a new object. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public convenience init(_ color: ThemeColor) {
            self.init(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [
                    .darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastAqua,
                ])
                let conditions = DisplayConditions(
                    colorScheme: dark == .darkAqua || dark == .accessibilityHighContrastDarkAqua
                        ? .dark : .light,
                    highContrast: dark == .accessibilityHighContrastAqua
                        || dark == .accessibilityHighContrastDarkAqua
                )
                return NSColor(color.resolved(for: conditions))
            }
        }
    }

    extension NSFont {
        /// The font the theme describes: the named one, or the system font in its weight.
        ///
        /// Ownership: returns an object. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public static func themed(_ font: ThemeFont) -> NSFont {
            let size = CGFloat(font.size)
            if let name = font.name, let named = NSFont(name: name, size: size) {
                return named
            }
            let weight: NSFont.Weight =
                switch font.weight {
                case .regular: .regular
                case .medium: .medium
                case .semibold: .semibold
                case .bold: .bold
                }
            return .systemFont(ofSize: size, weight: weight)
        }
    }
#endif
