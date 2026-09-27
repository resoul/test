#if canImport(UIKit)
    import ThemeCore
    import UIKit

    extension DisplayConditions {
        /// The conditions `traits` and the system's accessibility settings ask for: the
        /// interface style, contrast, the text size (1 at the standard size), Reduce Motion.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        @MainActor
        public init(_ traits: UITraitCollection) {
            self.init(
                colorScheme: traits.userInterfaceStyle == .dark ? .dark : .light,
                highContrast: traits.accessibilityContrast == .high,
                textScale: Double(
                    UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
                        / 17
                ),
                reducesMotion: UIAccessibility.isReduceMotionEnabled
            )
        }
    }

    extension Theme {
        /// The theme's values for the conditions `traits` ask for.
        ///
        /// Ownership: returns a value. Isolation: MainActor. Errors: none. Cancellation: not
        /// applicable.
        @MainActor
        public func resolved(for traits: UITraitCollection) -> ResolvedTheme {
            resolved(for: DisplayConditions(traits))
        }
    }

    extension UIColor {
        /// The color, in sRGB.
        ///
        /// Ownership: returns a new object. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public convenience init(_ color: Color) {
            self.init(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
        }

        /// A color that follows the traits it is drawn with — light or dark, more contrast —
        /// as the system's colors do: a view shows the right one without being told.
        ///
        /// Ownership: returns a new object. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public convenience init(_ color: ThemeColor) {
            self.init { traits in
                let conditions = DisplayConditions(
                    colorScheme: traits.userInterfaceStyle == .dark ? .dark : .light,
                    highContrast: traits.accessibilityContrast == .high
                )
                return UIColor(color.resolved(for: conditions))
            }
        }
    }

    extension UIFont {
        /// The font the theme describes: the named one, or the system font in its weight.
        ///
        /// Ownership: returns an object. Isolation: none. Errors: none. Cancellation: not
        /// applicable.
        public static func themed(_ font: ThemeFont) -> UIFont {
            let size = CGFloat(font.size)
            if let name = font.name, let named = UIFont(name: name, size: size) {
                return named
            }
            let weight: UIFont.Weight =
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
