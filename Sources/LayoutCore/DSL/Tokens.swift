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
/// named size. The names describe the width of the space an element gets, not a device;
/// they stay names until the layout is prepared, and the theme's `BreakpointScale` of that
/// pass gives their points. A number written out stays that number.
///
///     extension BreakpointWidth {
///         static let sidebar: Self = 280
///     }
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct BreakpointWidth: Sendable, Hashable, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral
{
    enum Kind: Hashable {
        case points(Double)
        case named(Name)
    }

    /// The named sizes, narrowest first.
    enum Name: Int, Hashable, CaseIterable {
        case sm
        case md
        case lg
        case xl
        case xxl
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(integerLiteral value: Int) {
        kind = .points(Double(value))
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(floatLiteral value: Double) {
        kind = .points(value)
    }

    /// A fixed width in points, whatever the theme.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func points(_ value: Double) -> BreakpointWidth {
        BreakpointWidth(kind: .points(value))
    }

    /// 400 points by default: a large phone in portrait, a card in a wide column.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let sm = BreakpointWidth(kind: .named(.sm))
    /// 600 points by default: a phone in landscape, a narrow iPad column.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let md = BreakpointWidth(kind: .named(.md))
    /// 840 points by default: an iPad in portrait, a Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let lg = BreakpointWidth(kind: .named(.lg))
    /// 1200 points by default: an iPad in landscape, a large Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let xl = BreakpointWidth(kind: .named(.xl))
    /// 1600 points by default: tvOS, a full-screen Mac window.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let xxl = BreakpointWidth(kind: .named(.xxl))
}

/// The points of each named breakpoint. A theme supplies its own; `standard` is 400, 600,
/// 840, 1200, 1600.
///
/// Ownership: value type. Isolation: none. Errors: none. Cancellation: not applicable.
public struct BreakpointScale: Sendable, Hashable {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var sm: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var md: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var lg: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var xl: Double
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var xxl: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(sm: Double, md: Double, lg: Double, xl: Double, xxl: Double) {
        self.sm = sm
        self.md = md
        self.lg = lg
        self.xl = xl
        self.xxl = xxl
    }

    /// 400, 600, 840, 1200, 1600.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let standard = BreakpointScale(sm: 400, md: 600, lg: 840, xl: 1200, xxl: 1600)

    /// The points of `width`: a name's in this scale, a number's own.
    ///
    /// Ownership: returns a value. Isolation: none. Errors: none. Cancellation: none.
    public func points(_ width: BreakpointWidth) -> Double {
        switch width.kind {
        case let .points(value):
            value
        case .named(.sm):
            sm
        case .named(.md):
            md
        case .named(.lg):
            lg
        case .named(.xl):
            xl
        case .named(.xxl):
            xxl
        }
    }
}
