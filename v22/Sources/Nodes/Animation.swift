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
