import Foundation
import StateCore

/// How the screen moves from what it shows to what it shows after a change: frames,
/// appearance, nodes coming in (they fade in) and going out (they fade out).
///
///     withAnimation {
///         profile.isFollowing.value.toggle()
///     }
///
/// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Animation: Sendable, Hashable {
    /// How the values move over time.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Curve: Sendable, Hashable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case linear
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case easeIn
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case easeOut
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case easeInOut
        /// A spring. `response` is the seconds one swing would take without damping;
        /// `dampingRatio` 1 comes to rest without overshooting, less overshoots.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case spring(response: Double, dampingRatio: Double)
    }

    /// Seconds the animation runs. For a spring, the time it takes to come to rest.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var duration: Double

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public var curve: Curve

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(duration: Double, curve: Curve) {
        self.duration = duration
        self.curve = curve
    }

    /// A quarter of a second, easing in and out.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let `default` = Animation(duration: 0.25, curve: .easeInOut)

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func linear(duration: Double = 0.25) -> Animation {
        Animation(duration: duration, curve: .linear)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func easeIn(duration: Double = 0.25) -> Animation {
        Animation(duration: duration, curve: .easeIn)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func easeOut(duration: Double = 0.25) -> Animation {
        Animation(duration: duration, curve: .easeOut)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func easeInOut(duration: Double = 0.25) -> Animation {
        Animation(duration: duration, curve: .easeInOut)
    }

    /// A spring that runs until its swing has died down to a thousandth.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func spring(response: Double = 0.5, dampingRatio: Double = 0.8) -> Animation {
        let response = max(response, 0.01)
        let damping = max(dampingRatio, 0.01)
        let frequency = 2 * Double.pi / response
        // The slowest part of the motion decays as e^(-rate·t).
        let rate =
            damping < 1
            ? damping * frequency : frequency * (damping - (damping * damping - 1).squareRoot())
        return Animation(
            duration: log(1000) / rate,
            curve: .spring(response: response, dampingRatio: damping)
        )
    }

    /// The animation of changes made right now, set by `withAnimation`.
    @MainActor static var current: Animation?
}

extension Animation: StateTransaction {
    /// Makes the writes inside `withAnimation(self)`, so what they change is drawn with this
    /// animation — the way a stream bound with `animation:` writes its values.
    ///
    /// Ownership: runs `writes` once. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    @MainActor
    public func perform(_ writes: () -> Void) {
        withAnimation(self, writes)
    }
}

// So that a parameter typed as a transaction takes `.default`, `.spring()` and the rest, as
// a parameter typed `Animation` does.
extension StateTransaction where Self == Animation {
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static var `default`: Animation { Animation.default }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func linear(duration: Double = 0.25) -> Animation {
        Animation.linear(duration: duration)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func easeIn(duration: Double = 0.25) -> Animation {
        Animation.easeIn(duration: duration)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func easeOut(duration: Double = 0.25) -> Animation {
        Animation.easeOut(duration: duration)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func easeInOut(duration: Double = 0.25) -> Animation {
        Animation.easeInOut(duration: duration)
    }

    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func spring(response: Double = 0.5, dampingRatio: Double = 0.8) -> Animation {
        Animation.spring(response: response, dampingRatio: dampingRatio)
    }
}

/// Runs `body` and animates what it changes: the layouts and redraws it causes — directly
/// or through the states it writes — move with `animation` when they are drawn next. `nil`
/// turns animation off inside an animated block.
///
/// State updates caused by `body` run before it returns, so the changes are known to belong
/// to it.
///
/// Ownership: returns what `body` returns. Isolation: MainActor. Errors: rethrows `body`'s
/// error. Cancellation: not applicable.
@MainActor
@discardableResult
public func withAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    let outer = Animation.current
    Animation.current = animation
    defer {
        StateUpdates.flush()
        Animation.current = outer
    }
    return try body()
}

extension Animation {
    /// How far along its way the animation is `elapsed` seconds after it began, from 0 to 1;
    /// a spring may go past 1 before it settles. The curves are Core Animation's: the same
    /// cubic Béziers for the named timings, and a spring of unit mass starting at rest.
    func progress(at elapsed: Double) -> Double {
        guard duration > 0, elapsed < duration else { return 1 }
        guard elapsed > 0 else { return 0 }

        let time = elapsed / duration
        switch curve {
        case .linear:
            return time
        case .easeIn:
            return Animation.bezier(0.42, 0, 1, 1, at: time)
        case .easeOut:
            return Animation.bezier(0, 0, 0.58, 1, at: time)
        case .easeInOut:
            return Animation.bezier(0.42, 0, 0.58, 1, at: time)
        case .spring(let response, let dampingRatio):
            return Animation.spring(response: response, dampingRatio: dampingRatio, at: elapsed)
        }
    }

    /// The value at `time` of a timing curve from (0, 0) to (1, 1) with control points
    /// (`x1`, `y1`) and (`x2`, `y2`): the curve's parameter is found for `time` along x, then
    /// its y taken.
    private static func bezier(
        _ x1: Double,
        _ y1: Double,
        _ x2: Double,
        _ y2: Double,
        at time: Double
    ) -> Double {
        func coordinate(_ first: Double, _ second: Double, _ s: Double) -> Double {
            let rest = 1 - s
            return 3 * rest * rest * s * first + 3 * rest * s * s * second + s * s * s
        }
        // x grows with the parameter, so halving the interval always closes in on it.
        var low = 0.0
        var high = 1.0
        var s = time
        for _ in 0..<48 {
            let x = coordinate(x1, x2, s)
            if abs(x - time) < 1e-9 { break }

            if x < time {
                low = s
            } else {
                high = s
            }
            s = (low + high) / 2
        }
        return coordinate(y1, y2, s)
    }

    /// Where a spring of unit mass, pulled from 0 toward 1 and let go at rest, is at
    /// `elapsed` seconds: stiffness (2π / response)², damping 4π · dampingRatio / response.
    private static func spring(response: Double, dampingRatio: Double, at elapsed: Double)
        -> Double
    {
        let frequency = 2 * Double.pi / max(response, 0.01)
        let damping = max(dampingRatio, 0.01)
        let t = elapsed
        if damping < 1 {
            let damped = frequency * (1 - damping * damping).squareRoot()
            let decay = exp(-damping * frequency * t)
            return 1 - decay * (cos(damped * t) + damping * frequency / damped * sin(damped * t))
        }
        if damping == 1 {
            return 1 - exp(-frequency * t) * (1 + frequency * t)
        }
        let root = (damping * damping - 1).squareRoot()
        let slow = -frequency * (damping - root)
        let fast = -frequency * (damping + root)
        return 1 - (fast * exp(slow * t) - slow * exp(fast * t)) / (fast - slow)
    }
}
