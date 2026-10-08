import CoreGraphics
import QuartzCore
import TrellisCore

/// Applies Trellis's supported paint fields to one native layer.
///
/// Supported fields are `VisualStyle.background`, `border`, `cornerRadius`, and `shadow`, plus
/// `LayoutVisualProperties.opacity`, `overflow`, `zIndex`, and `transform` in `LayerRenderer`.
/// `OverflowPolicy.scroll` clips content but does not create scrolling behavior; Text, Image,
/// video, swipe, display-artifact, and animation paths are deliberately outside C16.
///
/// Ownership: borrows `appearance`, `theme`, and `layer`; callers retain every object.
/// Isolation: MainActor callers only, because `CALayer` is native mutable state. Errors:
/// unsupported or absent paint clears its corresponding layer fields. Cancellation: not
/// applicable.
@MainActor
public func applyVisualStyle(
    _ appearance: VisualStyle,
    to layer: CALayer,
    theme: Theme = .defaultValue
) {
    switch appearance.background {
    case .none:
        layer.backgroundColor = nil
    case let .color(color):
        layer.backgroundColor = cgColor(color)
    case let .theme(role):
        layer.backgroundColor = cgColor(resolveThemeColor(role, in: theme))
    }

    layer.cornerRadius = CGFloat(appearance.cornerRadius)
    if let border = appearance.border {
        layer.borderWidth = CGFloat(border.width)
        layer.borderColor = cgColor(border.color)
    } else {
        layer.borderWidth = 0
        layer.borderColor = nil
    }

    if let shadow = appearance.shadow {
        layer.shadowColor = cgColor(shadow.color)
        layer.shadowOpacity = Float(shadow.opacity)
        layer.shadowRadius = CGFloat(shadow.radius)
        layer.shadowOffset = CGSize(width: shadow.offset.x, height: shadow.offset.y)
    } else {
        layer.shadowColor = nil
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
    }
}

/// Resolves a semantic fill role in an immutable theme snapshot.
///
/// Ownership: returns a copied color. Isolation: none. Errors: roles are exhaustive.
/// Cancellation: not applicable.
public func resolveThemeColor(_ role: ThemeColorRole, in theme: Theme) -> ThemeColor {
    switch role {
    case .background: theme.colors.background
    case .surface: theme.colors.surface
    case .primary: theme.colors.primary
    case .secondary: theme.colors.secondary
    case .accent: theme.colors.accent
    case .text: theme.colors.text
    case .textSecondary: theme.colors.textSecondary
    case .border: theme.colors.border
    case .error: theme.colors.error
    case .success: theme.colors.success
    case .warning: theme.colors.warning
    }
}

private func cgColor(_ color: ThemeColor) -> CGColor {
    CGColor(
        red: CGFloat(color.red),
        green: CGFloat(color.green),
        blue: CGFloat(color.blue),
        alpha: CGFloat(color.alpha)
    )
}
