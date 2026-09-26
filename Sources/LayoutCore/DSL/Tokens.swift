/// A spacing value: points, or a step of the theme's spacing scale (`.s1` … `.s9`). Steps
/// become points when the layout is applied, with the scale of that pass.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Spacing: Sendable, Hashable {
    enum Kind: Hashable {
        case points(Double)
        case step(Int)
    }

    let kind: Kind

    /// A fixed amount of points.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func points(_ value: Double) -> Spacing {
        Spacing(kind: .points(value))
    }

    /// Steps of the spacing scale, smallest to largest.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s1 = Spacing(kind: .step(1))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s2 = Spacing(kind: .step(2))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s3 = Spacing(kind: .step(3))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s4 = Spacing(kind: .step(4))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s5 = Spacing(kind: .step(5))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s6 = Spacing(kind: .step(6))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s7 = Spacing(kind: .step(7))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s8 = Spacing(kind: .step(8))
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let s9 = Spacing(kind: .step(9))
}

/// The points of each spacing step. A theme supplies its own; `standard` is a 4-point grid.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct SpacingScale: Sendable, Hashable {
    /// Points of `.s1` … `.s9`, in order.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var steps: [Double]

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(steps: [Double]) {
        self.steps = steps
    }

    /// 2, 4, 8, 12, 16, 24, 32, 48, 64.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = SpacingScale(steps: [2, 4, 8, 12, 16, 24, 32, 48, 64])

    /// The points of `spacing`; a step outside the scale uses the nearest step it has.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: none.
    public func points(_ spacing: Spacing) -> Double {
        switch spacing.kind {
        case let .points(value):
            return value
        case let .step(step):
            guard !steps.isEmpty else { return 0 }

            return steps[min(max(step, 1), steps.count) - 1]
        }
    }
}

/// A width from which a responsive value or a `Breakpoint` branch applies: points, or a
/// named size. The names describe the width of the space an element gets, not a device.
///
///     extension BreakpointWidth {
///         static let sidebar: Self = 280
///     }
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct BreakpointWidth: Sendable, Hashable, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral
{
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let points: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(integerLiteral value: Int) {
        points = Double(value)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(floatLiteral value: Double) {
        points = value
    }

    /// 400 points: a large phone in portrait, a card in a wide column.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let sm: BreakpointWidth = 400
    /// 600 points: a phone in landscape, a narrow iPad column.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let md: BreakpointWidth = 600
    /// 840 points: an iPad in portrait, a Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let lg: BreakpointWidth = 840
    /// 1200 points: an iPad in landscape, a large Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let xl: BreakpointWidth = 1200
    /// 1600 points: tvOS, a full-screen Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let xxl: BreakpointWidth = 1600
}
