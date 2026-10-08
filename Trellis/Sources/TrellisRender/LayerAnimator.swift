import CoreGraphics
import Foundation
import QuartzCore
import TrellisCore

/// M04's small explicit animator: for each of D61's six supported properties, diffs one
/// committed node's pre-write and post-write model value on its own `CALayer` and either
/// retargets an in-flight `CABasicAnimation` or snaps, using the `AnimationIntent`
/// `LayerRenderer` resolved for that node this commit.
///
/// Every active animation is addressed by `(mountEpoch, NodeID, property)` (D64): a callback
/// or a later commit's intent for any other key never touches it, and a stale token from a
/// since-replaced animation is ignored rather than clearing a newer one. Only identities and
/// scalar/CG values are retained here — no `Node`, closure, or solver snapshot (D62/D64).
///
/// Ownership: owns only its own per-key bookkeeping; every `CALayer` it touches is retained by
/// `LayerRenderer`'s registry, not here. Isolation: MainActor — `CALayer` is native mutable
/// state. Errors: an intent whose scope does not resolve to a node, or `.none`, is treated as
/// "snap this property". Cancellation: `forgetNode`/`unmount` drop bookkeeping for layers that
/// are already gone without touching them.
@MainActor
final class LayerAnimator {
    /// D61's supported property table.
    enum Property: String, CaseIterable, Hashable {
        case position
        case bounds
        case opacity
        case transform
        case backgroundColor
        case cornerRadius

        /// The actual `CALayer` animation key(s) this property adds/removes explicit
        /// animations under. `position`/`bounds` box to `NSValue(point:)`/`NSValue(rect:)` on
        /// one platform and `NSValue(cgPoint:)`/`NSValue(cgRect:)` on another — rather than
        /// branch on platform in a file outside the UIKit/AppKit adapters, each axis animates
        /// as its own plain `CGFloat` sub-keyPath, which bridges to `NSNumber` identically
        /// everywhere (the same shape M02's prototype used for exactly this reason).
        var animationKeys: [String] {
            switch self {
            case .position: ["position.x", "position.y"]
            case .bounds: ["bounds.size.width", "bounds.size.height"]
            case .opacity, .transform, .backgroundColor, .cornerRadius: [rawValue]
            }
        }
    }

    /// One layer's D61 model values, read directly off it before this commit's writes land —
    /// what `reconcile` diffs against the same values re-read after the writes.
    struct BeforeState {
        let position: CGPoint
        let bounds: CGRect
        let opacity: Float
        let cornerRadius: CGFloat
        let backgroundColor: CGColor?
        let transform: CGAffineTransform
    }

    private struct ActiveKey: Hashable {
        let mountEpoch: UInt64
        let nodeID: NodeID
        let property: Property
    }

    /// Bookkeeping for one property's currently-running explicit animation — just enough to
    /// recognize a same-target repeat (nothing to do, D64) and to ignore a stale completion
    /// (D66 point 3).
    private final class ActiveAnimation {
        let token: UInt64
        init(token: UInt64) { self.token = token }
    }

    private var active: [ActiveKey: ActiveAnimation] = [:]
    private var nextToken: UInt64 = 0

    /// Reads the current D61 model values off `layer`, before this commit writes new ones.
    func captureBeforeState(layer: CALayer) -> BeforeState {
        BeforeState(
            position: layer.position,
            bounds: layer.bounds,
            opacity: layer.opacity,
            cornerRadius: layer.cornerRadius,
            backgroundColor: layer.backgroundColor,
            transform: layer.affineTransform()
        )
    }

    /// Diffs `before` against `layer`'s current (already-written) model values and, for each
    /// property that changed, either retargets/creates an explicit animation under `intent`
    /// or snaps it — a repeat commit that writes the same value as `before` leaves any active
    /// animation on that property completely untouched (D64's same-target rule falls out of
    /// this equality check with no separate case).
    func reconcile(
        nodeID: NodeID,
        layer: CALayer,
        before: BeforeState,
        mountEpoch: UInt64,
        intent: AnimationIntent?,
        host: UInt64?,
        generation: UInt64?
    ) {
        reconcileAxisPair(
            .position,
            nodeID: nodeID,
            layer: layer,
            before: (before.position.x, before.position.y),
            after: (layer.position.x, layer.position.y),
            presentationValue: { ($0.position.x, $0.position.y) },
            keyPaths: ("position.x", "position.y"),
            intent: intent,
            mountEpoch: mountEpoch,
            host: host,
            generation: generation
        )
        reconcileAxisPair(
            .bounds,
            nodeID: nodeID,
            layer: layer,
            before: (before.bounds.width, before.bounds.height),
            after: (layer.bounds.width, layer.bounds.height),
            presentationValue: { ($0.bounds.width, $0.bounds.height) },
            keyPaths: ("bounds.size.width", "bounds.size.height"),
            intent: intent,
            mountEpoch: mountEpoch,
            host: host,
            generation: generation
        )
        reconcileValue(
            .opacity,
            nodeID: nodeID,
            layer: layer,
            before: before.opacity,
            after: layer.opacity,
            presentationValue: { $0.opacity },
            box: { $0 as Any },
            intent: intent,
            mountEpoch: mountEpoch,
            host: host,
            generation: generation
        )
        reconcileValue(
            .cornerRadius,
            nodeID: nodeID,
            layer: layer,
            before: before.cornerRadius,
            after: layer.cornerRadius,
            presentationValue: { $0.cornerRadius },
            box: { $0 as Any },
            intent: intent,
            mountEpoch: mountEpoch,
            host: host,
            generation: generation
        )
        reconcileBackgroundColor(
            nodeID: nodeID,
            layer: layer,
            before: before.backgroundColor,
            mountEpoch: mountEpoch,
            intent: intent,
            host: host,
            generation: generation
        )
        reconcileTransform(
            nodeID: nodeID,
            layer: layer,
            before: before.transform,
            mountEpoch: mountEpoch,
            intent: intent,
            host: host,
            generation: generation
        )
    }

    /// A layer materialized or reparented this commit (D62): nothing to retarget from and no
    /// coordinate space a retarget could rely on, so every property this animator might still
    /// be tracking for it is removed outright instead of reconciled.
    func snapAll(
        nodeID: NodeID,
        layer: CALayer,
        mountEpoch: UInt64,
        host: UInt64?,
        generation: UInt64?
    ) {
        for property in Property.allCases {
            let key = ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: property)
            if active.removeValue(forKey: key) != nil {
                for animationKey in property.animationKeys {
                    layer.removeAnimation(forKey: animationKey)
                }
            }
        }
        Log.on(
            .layer,
            "animate-snap",
            host: host,
            generation: generation,
            node: nodeID,
            "scope=all"
        )
    }

    /// A node removed from the tree since the last commit (`LayerRenderer.removeStaleLayers`):
    /// its layer is already gone, so only this animator's own bookkeeping needs clearing.
    func forgetNode(_ nodeID: NodeID, mountEpoch: UInt64) {
        for property in Property.allCases {
            active.removeValue(
                forKey: ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: property)
            )
        }
    }

    /// Drops every active-animation record — `LayerRenderer.unmount()` already detaches every
    /// layer, so there is nothing left here to address.
    func unmount() {
        active.removeAll()
    }

    /// How many `(NodeID, property)` explicit animations are currently tracked as active in
    /// `mountEpoch` — M07's scene-readiness check (D69: "отсутствие активных переходов сцены")
    /// reads this instead of re-deriving it from `CALayer.animationKeys`, which would also see
    /// a lingering removed-but-not-yet-GC'd animation object CA itself has not cleaned up.
    func activeCount(mountEpoch: UInt64) -> Int {
        active.keys.count { $0.mountEpoch == mountEpoch }
    }

    /// D67: ends every explicit animation currently active in `mountEpoch` right where it is
    /// headed, without a new commit/solve — `NodeHostBridge.suspend()` and Reduce Motion
    /// turning on mid-flight both need this. `layerForNode` looks the node's layer up in
    /// `LayerRenderer`'s own registry (this class holds no `CALayer` references itself); a
    /// node whose layer is already gone is simply skipped, nothing to finish. Each affected
    /// layer's model value is already the committed target (D66 step 2 happens at write time,
    /// before an animation is ever added) — removing the explicit animation is the entire
    /// "finish" here, exactly like `snapAll` for one node.
    func finishAllActive(mountEpoch: UInt64, layerForNode: (NodeID) -> CALayer?) {
        for key in active.keys where key.mountEpoch == mountEpoch {
            guard let layer = layerForNode(key.nodeID) else { continue }
            for animationKey in key.property.animationKeys {
                layer.removeAnimation(forKey: animationKey)
            }
        }
        active = active.filter { $0.key.mountEpoch != mountEpoch }
    }

    /// The completion adapter (D66/D67): called from a `CATransaction` completion block set at
    /// the moment one property's explicit animation was added. Ignores a stale token from an
    /// animation that has since been replaced or removed (D66 point 3) instead of clearing a
    /// newer one. Exposed for direct invocation from tests — M02 found real CA completion
    /// delivery does not reach an XCTest-hosted process on this toolchain, so this method's own
    /// cleanup logic, not end-to-end delivery, is what a deterministic test can verify.
    func completeIfCurrent(nodeID: NodeID, mountEpoch: UInt64, property: Property, token: UInt64) {
        let key = ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: property)
        guard let current = active[key], current.token == token else { return }
        active.removeValue(forKey: key)
    }

    /// Shared D61/D66 reconciliation for one scalar-ish property: unchanged values leave any
    /// active animation on this key completely alone (D66: "изменение другого свойства тоже
    /// его не отменяет" — and, since a same-target repeat also compares equal here, D64's
    /// no-restart rule as well); a changed value with no positive-duration intent snaps by
    /// removing this key's own animation (addressed, never `removeAllAnimations`); otherwise a
    /// new explicit animation is created from the presentation value (if one is active) or the
    /// prior model value, to the new model value, under a fresh token.
    private func reconcileValue<Value: Equatable>(
        _ property: Property,
        nodeID: NodeID,
        layer: CALayer,
        before: Value,
        after: Value,
        presentationValue: (CALayer) -> Value,
        box: (Value) -> Any,
        intent: AnimationIntent?,
        mountEpoch: UInt64,
        host: UInt64?,
        generation: UInt64?
    ) {
        guard before != after else { return }
        let key = ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: property)

        guard let intent, intent.animation.duration > .zero else {
            if active.removeValue(forKey: key) != nil {
                layer.removeAnimation(forKey: property.rawValue)
            }
            Log.on(
                .layer,
                "animate-snap",
                host: host,
                generation: generation,
                node: nodeID,
                "property=\(property.rawValue)"
            )
            return
        }

        let hasActive = active[key] != nil
        let fromValue = hasActive ? (layer.presentation().map(presentationValue) ?? before) : before

        let token = nextToken
        nextToken &+= 1
        active[key] = ActiveAnimation(token: token)

        let animation = makeAnimation(keyPath: property.rawValue, timing: intent.animation)
        animation.fromValue = box(fromValue)
        animation.toValue = box(after)

        CATransaction.begin()
        CATransaction.setCompletionBlock { @MainActor [weak self] in
            self?.completeIfCurrent(
                nodeID: nodeID,
                mountEpoch: mountEpoch,
                property: property,
                token: token
            )
        }
        layer.add(animation, forKey: property.rawValue)
        CATransaction.commit()
        Log.on(
            .layer,
            "animate",
            host: host,
            generation: generation,
            node: nodeID,
            "property=\(property.rawValue) duration=\(intent.animation.duration)"
        )
    }

    /// `position`/`bounds` each animate as two `CGFloat` sub-keyPaths sharing one bookkeeping
    /// entry and one token — see `Property.animationKeys`'s doc comment for why a single
    /// `NSValue`-boxed `CGPoint`/`CGRect` keyPath is not portable here. Both axes are
    /// created, retargeted, or removed together, atomically, so a completion for this
    /// property's token always means "both axes settled," never just one.
    private func reconcileAxisPair(
        _ property: Property,
        nodeID: NodeID,
        layer: CALayer,
        before: (CGFloat, CGFloat),
        after: (CGFloat, CGFloat),
        presentationValue: (CALayer) -> (CGFloat, CGFloat),
        keyPaths: (String, String),
        intent: AnimationIntent?,
        mountEpoch: UInt64,
        host: UInt64?,
        generation: UInt64?
    ) {
        guard before.0 != after.0 || before.1 != after.1 else { return }
        let key = ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: property)

        guard let intent, intent.animation.duration > .zero else {
            if active.removeValue(forKey: key) != nil {
                layer.removeAnimation(forKey: keyPaths.0)
                layer.removeAnimation(forKey: keyPaths.1)
            }
            Log.on(
                .layer,
                "animate-snap",
                host: host,
                generation: generation,
                node: nodeID,
                "property=\(property.rawValue)"
            )
            return
        }

        let hasActive = active[key] != nil
        let from = hasActive ? (layer.presentation().map(presentationValue) ?? before) : before

        let token = nextToken
        nextToken &+= 1
        active[key] = ActiveAnimation(token: token)

        let first = makeAnimation(keyPath: keyPaths.0, timing: intent.animation)
        first.fromValue = from.0
        first.toValue = after.0

        let second = makeAnimation(keyPath: keyPaths.1, timing: intent.animation)
        second.fromValue = from.1
        second.toValue = after.1

        CATransaction.begin()
        CATransaction.setCompletionBlock { @MainActor [weak self] in
            self?.completeIfCurrent(
                nodeID: nodeID,
                mountEpoch: mountEpoch,
                property: property,
                token: token
            )
        }
        layer.add(first, forKey: keyPaths.0)
        layer.add(second, forKey: keyPaths.1)
        CATransaction.commit()
        Log.on(
            .layer,
            "animate",
            host: host,
            generation: generation,
            node: nodeID,
            "property=\(property.rawValue) duration=\(intent.animation.duration)"
        )
    }

    /// `backgroundColor` is optional and needs D61's normalization ("отсутствие цвета —
    /// прозрачный цвет для интерполяции, целевое model-значение сохраняется") before it can be
    /// handed to a `CABasicAnimation`, so it does not fit `reconcileValue`'s plain `Equatable`
    /// shape.
    private func reconcileBackgroundColor(
        nodeID: NodeID,
        layer: CALayer,
        before: CGColor?,
        mountEpoch: UInt64,
        intent: AnimationIntent?,
        host: UInt64?,
        generation: UInt64?
    ) {
        let after = layer.backgroundColor
        guard before != after else { return }
        let key = ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: .backgroundColor)

        guard let intent, intent.animation.duration > .zero else {
            if active.removeValue(forKey: key) != nil {
                layer.removeAnimation(forKey: Property.backgroundColor.rawValue)
            }
            Log.on(
                .layer,
                "animate-snap",
                host: host,
                generation: generation,
                node: nodeID,
                "property=backgroundColor"
            )
            return
        }
        guard let pair = Self.normalizedColorPair(before: before, after: after) else { return }

        let hasActive = active[key] != nil
        let fromColor = hasActive ? (layer.presentation()?.backgroundColor ?? pair.from) : pair.from

        let token = nextToken
        nextToken &+= 1
        active[key] = ActiveAnimation(token: token)

        let animation = makeAnimation(
            keyPath: Property.backgroundColor.rawValue,
            timing: intent.animation
        )
        animation.fromValue = fromColor
        animation.toValue = pair.to

        CATransaction.begin()
        CATransaction.setCompletionBlock { @MainActor [weak self] in
            self?.completeIfCurrent(
                nodeID: nodeID,
                mountEpoch: mountEpoch,
                property: .backgroundColor,
                token: token
            )
        }
        layer.add(animation, forKey: Property.backgroundColor.rawValue)
        CATransaction.commit()
        Log.on(
            .layer,
            "animate",
            host: host,
            generation: generation,
            node: nodeID,
            "property=backgroundColor"
        )
    }

    /// D61: scale/translation interpolate; rotation between the two matrix representations is
    /// undefined and snaps instead, a documented first-version limitation. Detected by
    /// decomposing each side's rotation the same way `cgAffineTransform(_:)` encoded it, so a
    /// pure scale/translation change (equal rotation on both sides, including the common
    /// zero/zero case) still animates normally.
    private func reconcileTransform(
        nodeID: NodeID,
        layer: CALayer,
        before: CGAffineTransform,
        mountEpoch: UInt64,
        intent: AnimationIntent?,
        host: UInt64?,
        generation: UInt64?
    ) {
        let after = layer.affineTransform()
        guard before != after else { return }
        let key = ActiveKey(mountEpoch: mountEpoch, nodeID: nodeID, property: .transform)
        let rotationChanged = Self.rotationRadians(of: before) != Self.rotationRadians(of: after)

        guard let intent, intent.animation.duration > .zero, !rotationChanged else {
            if active.removeValue(forKey: key) != nil {
                layer.removeAnimation(forKey: Property.transform.rawValue)
            }
            Log.on(
                .layer,
                "animate-snap",
                host: host,
                generation: generation,
                node: nodeID,
                "property=transform rotation-limit=\(rotationChanged)"
            )
            return
        }

        let hasActive = active[key] != nil
        let fromTransform: CGAffineTransform
        if hasActive, let presentation = layer.presentation() {
            fromTransform = presentation.affineTransform()
        } else {
            fromTransform = before
        }

        let token = nextToken
        nextToken &+= 1
        active[key] = ActiveAnimation(token: token)

        let animation = makeAnimation(
            keyPath: Property.transform.rawValue,
            timing: intent.animation
        )
        animation.fromValue = NSValue(
            caTransform3D: CATransform3DMakeAffineTransform(fromTransform)
        )
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(after))

        CATransaction.begin()
        CATransaction.setCompletionBlock { @MainActor [weak self] in
            self?.completeIfCurrent(
                nodeID: nodeID,
                mountEpoch: mountEpoch,
                property: .transform,
                token: token
            )
        }
        layer.add(animation, forKey: Property.transform.rawValue)
        CATransaction.commit()
        Log.on(
            .layer,
            "animate",
            host: host,
            generation: generation,
            node: nodeID,
            "property=transform"
        )
    }

    private static func rotationRadians(of transform: CGAffineTransform) -> Double {
        atan2(Double(transform.b), Double(transform.a))
    }

    /// D61's color-pair normalization: a missing side becomes the other side's own color with
    /// zero alpha, in the same color space, rather than `nil` — `CABasicAnimation` needs a real
    /// `CGColor` on both ends. `nil` on both sides is not a change worth animating.
    private static func normalizedColorPair(
        before: CGColor?,
        after: CGColor?
    ) -> (from: CGColor, to: CGColor)? {
        switch (before, after) {
        case let (before?, after?):
            return (before, after)
        case let (before?, nil):
            return (before, before.copy(alpha: 0) ?? before)
        case let (nil, after?):
            return (after.copy(alpha: 0) ?? after, after)
        case (nil, nil):
            return nil
        }
    }
}

private func timingFunctionName(for curve: AnimationCurve) -> CAMediaTimingFunctionName {
    switch curve {
    case .linear: .linear
    case .easeIn: .easeIn
    case .easeOut: .easeOut
    case .easeInOut: .easeInEaseOut
    case .spring: .linear  // never read — `makeAnimation` takes the `CASpringAnimation` branch.
    }
}

/// Builds the one explicit animation object every `reconcile*` path adds to `layer` — a plain
/// eased `CABasicAnimation` for D61's original four curves, or a real `CASpringAnimation` for
/// M09's `.spring` (never a `CABasicAnimation` with a timing function standing in for a spring,
/// the exact substitution defect #41 found in the ported source). `CASpringAnimation` is a
/// `CABasicAnimation` subclass, so every caller keeps setting `fromValue`/`toValue` and adding it
/// under the same key exactly as before — this factory is the only place the two paths diverge.
///
/// `mass`/`stiffness`/`damping` follow the standard `response`/`dampingFraction` → physical-
/// parameter conversion (the same one SwiftUI's own two-parameter spring API is built on): with
/// `mass` fixed at `1`, `stiffness = (2π/response)²` and `damping = 4π·dampingFraction/response`.
/// `duration` is read back from the constructed animation's own `settlingDuration` — the SDK's
/// computed estimate of when the spring's motion becomes imperceptible — never a value this
/// package guesses (M09's acceptance: "`CASpringAnimation` без подмены ease... проверяются на
/// SDK").
///
/// Ownership: returns a new, unattached animation. Isolation: MainActor (matches every caller).
/// Errors: none. Cancellation: not applicable.
/// The Core Animation animation for a Trellis `Animation` — shared with native adapters so a
/// scroll view's timed offset animation (R13) uses exactly the same curve as layer animations.
package func makeAnimation(keyPath: String, timing: Animation) -> CABasicAnimation {
    switch timing.curve {
    case .linear, .easeIn, .easeOut, .easeInOut:
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = timing.duration.trellisTimeInterval
        animation.timingFunction = CAMediaTimingFunction(
            name: timingFunctionName(for: timing.curve)
        )
        return animation
    case let .spring(response, dampingFraction):
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * Double.pi / response, 2) * spring.mass
        spring.damping = 4 * Double.pi * dampingFraction * spring.mass / response
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        return spring
    }
}

extension Duration {
    /// `CABasicAnimation.duration` takes a `CFTimeInterval` (seconds); `Duration` has no public
    /// second-count accessor of its own.
    fileprivate var trellisTimeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
