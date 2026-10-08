import QuartzCore

/// M11's explicit-animation path for one `TransitionSession`'s overlay geometry — parallel to
/// `LayerAnimator` (D64/D66), not built on top of it.
///
/// `docs/validation/m10-transition-contract.md` §3 found that a temporary overlay layer has no
/// `NodeID` and does not fit `LayerAnimator.active`'s `(mountEpoch, NodeID, property)`
/// addressing, and that a session's several layers move under one shared progress driver (D70),
/// not as independent per-property D61 animations. This type reuses `LayerAnimator`'s two safety
/// properties without going through it: **retarget from the live presentation value** (D66 —a
/// second `present`/close while the first motion is still in flight continues from where the
/// layer visually is, never restarts from the model's old value) and **stale-completion
/// cleanup** (D66 point 3 — a completion captured under a superseded token is ignored). Both are
/// keyed by one `UInt64` per session (D71), not per `(layer, property)`, because D72 requires a
/// retarget to reverse the *whole* layer set atomically, not one property independently of the
/// others.
///
/// M12 adds manual (gesture-driven) control over the same driver: `arm`/`freezeForGesture` park
/// a motion at `speed = 0` instead of playing it, `scrub` moves `timeOffset` directly from a
/// gesture's own progress input (D72/D73 — never per-frame solve/raster, never reading a moving
/// layer's own presentation geometry as gesture input), and handing control back to automatic
/// settling is simply a fresh `play` call, which already retargets from the live (frozen)
/// presentation value.
///
/// Ownership: touches only layers handed to it by its caller (`TransitionEngine`); retains none
/// of them past a call beyond `armedLayers`. Isolation: MainActor — `CALayer` is native mutable
/// state. Errors: none. Cancellation: `finishInPlace(on:)` removes every explicit animation this
/// instance is tracking (automatic or manual) and invalidates its own token, so a completion
/// already queued on the run loop becomes a no-op.
@MainActor
final class TransitionAnimator {
    /// One layer/keyPath pair this session's automatic motion targets, and the value it must
    /// land on. `layer`'s own model value is written to `to` before the explicit animation is
    /// added (D66 step 2), exactly like `LayerAnimator.reconcile*` does per property.
    struct Target {
        let layer: CALayer
        let keyPath: String
        let to: Any

        /// This target's own sub-range of the session's unified `0...1` progress (D70: "все
        /// части используют единый progress 0…1, собственные интервалы и кривые внутри него",
        /// M14) — before `beginProgress` the target holds its starting value, after
        /// `endProgress` it holds `to`. Defaults to the full range, which reproduces exactly
        /// M11–M13's single shared timeline for every existing caller (S29's `.expand`, and
        /// every deterministic test predating M14): `play`/`arm` below fall back to a plain
        /// `CABasicAnimation` — unchanged from before this field existed — whenever a target's
        /// range is still the default full one.
        var beginProgress: Double = 0
        var endProgress: Double = 1
    }

    /// Explicit animations this instance currently has in flight, for `isActive`/D69's
    /// second readiness source (see `NodeHostBridge.sceneReadiness`).
    private(set) var isActive = false

    /// M12: `true` while this instance's layers are paused (`speed = 0`) under direct gesture
    /// control (`arm`/`freezeForGesture` armed them, `scrub` is moving them) rather than
    /// playing automatically. Mutually exclusive with `isActive` — a driver is either playing
    /// for real or parked for a gesture, never both.
    private(set) var isManual = false

    private var currentToken: UInt64 = 0

    /// The unique layers `play`/`arm`/`freezeForGesture` last armed, in first-seen order —
    /// `scrub`/`freezeForGesture` move each of these once via `timeOffset`, not once per
    /// `Target` (several `Target`s commonly share one layer, e.g. `hero`'s five geometry
    /// keyPaths).
    private var armedLayers: [CALayer] = []

    /// Wall-clock time `play` last started real playback at — `freezeForGesture` uses this,
    /// together with `automaticDuration`, to compute exactly how far a live automatic motion
    /// has gotten when a gesture grabs it (M12).
    private var automaticStartTime: CFTimeInterval = 0

    /// The duration `play` last armed real playback with.
    private var automaticDuration: CFTimeInterval = 0

    /// The duration `arm`/`freezeForGesture` last parked manual control at — `scrub` maps
    /// `0...1` progress onto `0...manualDuration` of `timeOffset` against this value.
    private var manualDuration: CFTimeInterval = 0

    /// First-seen-order-preserving dedup of `targets`' layers — several `Target`s commonly
    /// share one `CALayer` (`hero`'s five geometry keyPaths), and `speed`/`timeOffset` are
    /// layer-level, not per-keyPath, so each layer must be touched once, not once per target.
    private static func uniqueLayers(_ targets: [Target]) -> [CALayer] {
        var seen = Set<ObjectIdentifier>()
        var result: [CALayer] = []
        for target in targets {
            if seen.insert(ObjectIdentifier(target.layer)).inserted { result.append(target.layer) }
        }
        return result
    }

    /// The key every explicit animation this instance adds is stored under, distinct from any
    /// key `LayerAnimator` or ordinary layer code might use on the same layer — a session's
    /// overlay layers are exclusively owned by the transition engine, but a shared prefix keeps
    /// `finishInPlace(on:)` addressed rather than a blanket `removeAllAnimations()`.
    private static func animationKey(for keyPath: String) -> String {
        "trellis.transition.\(keyPath)"
    }

    /// Builds one target's explicit animation, spanning the *whole* `duration` in local
    /// (`timeOffset`-compatible) time either way (M14) — a target confined to a sub-range
    /// (`beginProgress`/`endProgress` inside `0...1`) holds its `fromValue` until that range
    /// starts and `to` after it ends, via `CAKeyframeAnimation`'s `keyTimes`, rather than a
    /// shorter animation placed at a `beginTime` offset: every target in one session must keep
    /// the exact same `duration`, because `TransitionAnimator.scrub(_:)` moves every armed
    /// layer's `timeOffset` by one shared `manualDuration * progress` value — a target-local
    /// `beginTime` offset (the usual CA staggering idiom, which needs `CACurrentMediaTime()` to
    /// mean anything under real-time playback) would desynchronize from that shared scrub
    /// domain the moment a gesture takes over. A target whose range is still the untouched
    /// default (`0...1`) gets a plain `CABasicAnimation` — byte-for-byte the animation `play`/
    /// `arm` built before this field existed, zero behavior change for M11–M13 callers.
    private static func makeAnimation(
        target: Target,
        duration: CFTimeInterval,
        fromValue: Any?,
        activeTimingFunction: CAMediaTimingFunctionName
    ) -> CAPropertyAnimation {
        guard target.beginProgress > 0 || target.endProgress < 1 else {
            let animation = CABasicAnimation(keyPath: target.keyPath)
            animation.fromValue = fromValue
            animation.toValue = target.to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: activeTimingFunction)
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            return animation
        }

        let begin = max(0, min(1, target.beginProgress))
        let end = max(begin, min(1, target.endProgress))

        // Built without a duplicate keyTime at either boundary (0 or 1) — a repeated final
        // keyTime produced a zero-width last segment that made the *previous* segment's
        // interpolation misbehave in manual (`timeOffset`-scrubbed) mode (found writing this
        // card's own M14TransitionCompositionTests.swift, before this shipped). Only the
        // segments that actually exist are added.
        var keyTimes: [NSNumber] = []
        var values: [Any] = []
        var timingFunctions: [CAMediaTimingFunction] = []

        if begin > 0 {
            keyTimes.append(0)
            values.append(fromValue as Any)
            timingFunctions.append(CAMediaTimingFunction(name: .linear))
        }
        keyTimes.append(NSNumber(value: begin))
        values.append(fromValue as Any)
        keyTimes.append(NSNumber(value: end))
        values.append(target.to)
        timingFunctions.append(CAMediaTimingFunction(name: activeTimingFunction))
        if end < 1 {
            keyTimes.append(1)
            values.append(target.to)
            timingFunctions.append(CAMediaTimingFunction(name: .linear))
        }

        let animation = CAKeyframeAnimation(keyPath: target.keyPath)
        animation.keyTimes = keyTimes
        animation.values = values
        animation.timingFunctions = timingFunctions
        animation.calculationMode = .linear
        animation.duration = duration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Arms one real (speed = 1) playback across every target at once, under one
    /// `CATransaction`/completion — M11's `.expand` is button-driven automatic motion, not a
    /// manually scrubbed gesture (M12), so this plays for real rather than parking at
    /// `timeOffset`. A target whose layer already has an animation from a previous call under
    /// the same key retargets **from the live presentation value** rather than the (now stale)
    /// `before` the caller no longer has — D66's rule, applied at the whole-session token, not
    /// per property. `completion` fires once, only if no later `play`/`finishInPlace` call has
    /// since bumped the token (the stale-completion rule).
    ///
    /// Ownership: writes `to` onto each target's model value; retains no layer. Isolation:
    /// MainActor. Errors: none. Cancellation: superseded by a later `play`/`finishInPlace` call,
    /// which bumps the token this call's completion is guarded by.
    func play(
        token: UInt64,
        targets: [Target],
        duration: CFTimeInterval,
        timingFunction: CAMediaTimingFunctionName,
        completion: @escaping @MainActor () -> Void
    ) {
        currentToken = token
        isActive = true
        isManual = false
        armedLayers = Self.uniqueLayers(targets)
        automaticStartTime = CACurrentMediaTime()
        automaticDuration = duration

        CATransaction.begin()
        CATransaction.setCompletionBlock { @MainActor [weak self] in
            guard let self, self.currentToken == token else { return }
            self.isActive = false
            completion()
        }
        for target in targets {
            let key = Self.animationKey(for: target.keyPath)
            let fromValue =
                target.layer.presentation()?.value(forKeyPath: target.keyPath)
                ?? target.layer.value(forKeyPath: target.keyPath)
            let animation = Self.makeAnimation(
                target: target,
                duration: duration,
                fromValue: fromValue,
                activeTimingFunction: timingFunction
            )
            target.layer.setValue(target.to, forKeyPath: target.keyPath)
            target.layer.add(animation, forKey: key)
        }
        // M13 fix (found running S29's real pan gesture in the iOS Simulator, `docs/defects.md`):
        // a layer handed back from manual/gesture control (`arm`/`freezeForGesture` parked it at
        // `speed = 0`) never had its own media clock un-paused before. The `fromValue`/`toValue`
        // pair captured above is correct either way (read from `presentation()` while still
        // paused, above), but a still-`speed = 0` layer never advances the freshly-added
        // animation at all — it stays frozen at `fromValue` forever, so `completion` never fires.
        // Every `play()` call — automatic-from-rest or handing control back from a gesture — must
        // leave its layers running at normal speed; resetting unconditionally here is a no-op for
        // a layer that was already at `speed = 1`/`timeOffset = 0`.
        for layer in armedLayers {
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
        }
        CATransaction.commit()
    }

    /// D67-style immediate finish, reused here for `NodeHostBridge.suspend()`/Reduce Motion
    /// mid-transition (D73: "незавершённый interactiveClosing → presented", "Reduce Motion...
    /// немедленно к текущему логическому endpoint"): removes every explicit animation this
    /// instance added, on the given layers, at whatever `keyPath`s were last armed by `play`.
    /// Each target's model value is already the committed target (`play` writes it before
    /// adding the animation) — removing the explicit animation is the entire "finish" here,
    /// mirroring `LayerAnimator.finishAllActive`/`snapAll`. Bumps the token so a completion
    /// already scheduled from the animation just removed becomes a no-op instead of firing
    /// after the caller has already moved the session past it.
    ///
    /// Ownership: mutates only the layers passed in. Isolation: MainActor. Errors: none.
    /// Cancellation: this call is one.
    func finishInPlace(on layers: [CALayer], keyPaths: [String]) {
        guard isActive || isManual else { return }
        for layer in layers {
            for keyPath in keyPaths {
                layer.removeAnimation(forKey: Self.animationKey(for: keyPath))
            }
        }
        isActive = false
        isManual = false
        currentToken &+= 1
    }

    // MARK: - M12 gesture-driven progress (D72/D73)

    /// Arms every target's explicit animation exactly like `play` — including the D66
    /// retarget-from-presentation rule when a target's layer already carries an animation under
    /// the same key — but parks it at the start of the newly-armed motion (`speed = 0`,
    /// `timeOffset = 0`) instead of committing to real-time playback. The entry point for a
    /// gesture that begins a fresh interactive motion with nothing already in flight to take
    /// over (D72: a dismiss gesture starting from `.presented`). No completion is scheduled —
    /// nothing finishes on its own until `play` is called again to settle automatically.
    ///
    /// Ownership: writes `to` onto each target's model value; retains no layer past the call
    /// beyond `armedLayers`. Isolation: MainActor. Errors: none. Cancellation: superseded by a
    /// later `play`/`arm`/`finishInPlace` call, which each replace or remove this instance's
    /// explicit animations.
    func arm(token: UInt64, targets: [Target], duration: CFTimeInterval) {
        currentToken = token
        isActive = false
        isManual = true
        armedLayers = Self.uniqueLayers(targets)
        manualDuration = duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for target in targets {
            let key = Self.animationKey(for: target.keyPath)
            let fromValue =
                target.layer.presentation()?.value(forKeyPath: target.keyPath)
                ?? target.layer.value(forKeyPath: target.keyPath)
            // Linear, unlike `play`'s `.easeInEaseOut`: while a gesture is directly scrubbing
            // `timeOffset`, the visible motion should track the input 1:1 — an eased curve here
            // would make equal-sized gesture deltas produce unequal-sized visual steps. `play`
            // re-applies the eased curve once control returns to automatic settling. A target
            // with its own sub-range (M14) keeps that linear tracking inside its own interval —
            // only the interval's width/position differs from the whole-session default.
            let animation = Self.makeAnimation(
                target: target,
                duration: duration,
                fromValue: fromValue,
                activeTimingFunction: .linear
            )
            target.layer.setValue(target.to, forKeyPath: target.keyPath)
            target.layer.add(animation, forKey: key)
        }
        for layer in armedLayers {
            layer.speed = 0
            layer.timeOffset = 0
        }
        CATransaction.commit()
    }

    /// Freezes an already-playing automatic motion (armed by `play`) into manual/gesture
    /// control, in place: no visual jump, and — per D72's explicit continuity requirement
    /// (`docs/validation/m10-transition-contract.md` §1.3: "progress продолжает расти от
    /// текущего, не сбрасывается") — no numeric jump in the caller's own progress bookkeeping
    /// either. The returned value is this motion's own elapsed fraction (wall-clock elapsed
    /// since `play` started, divided by its duration); the caller must keep this as the
    /// session's `progress` rather than resetting it to `0`. Returns `nil`, changing nothing,
    /// when nothing is actively auto-playing under `token` — a caller must not enter interactive
    /// mode from a driver that was not actually moving.
    ///
    /// Ownership: mutates only the layers `play` last armed. Isolation: MainActor. Errors: `nil`
    /// covers rejection. Cancellation: this call is one — it stops automatic playback for good;
    /// the paused animation stays attached (`isRemovedOnCompletion = false`), so a later `play`
    /// retargets from exactly this frozen presentation value.
    func freezeForGesture(token: UInt64) -> Double? {
        guard isActive, currentToken == token else { return nil }

        let elapsed = CACurrentMediaTime() - automaticStartTime
        let progress = automaticDuration > 0 ? max(0, min(1, elapsed / automaticDuration)) : 1
        for layer in armedLayers {
            layer.speed = 0
            layer.timeOffset = automaticDuration * progress
        }
        isActive = false
        isManual = true
        manualDuration = automaticDuration
        return progress
    }

    /// Moves every layer this instance currently has armed (whichever of `play`/`arm`/
    /// `freezeForGesture` ran last) to `progress` at once — the single shared driver D70
    /// requires, the same `timeOffset`-scrubbing mechanism `docs/validation/
    /// m10-transition-contract.md` §2's prototype proved (`speed = 0` + `timeOffset`, no
    /// display-link, no re-animation per call — no `add(_:forKey:)` happens here at all). A
    /// no-op outside manual mode.
    ///
    /// Ownership: mutates only the layers already armed. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable — each call fully determines the resulting position, so
    /// there is nothing an interruption could leave half-applied.
    func scrub(_ progress: Double) {
        guard isManual else { return }
        let clamped = max(0, min(1, progress))
        for layer in armedLayers {
            layer.timeOffset = manualDuration * clamped
        }
        CATransaction.flush()
    }

    /// Removes this instance's explicit animations for specific keyPaths only, on specific
    /// layers — used when a rebuild intentionally drops a keyPath from the newly-armed target
    /// set (M13: a role that stops animating geometry and starts fading instead — D72's "closing
    /// использует fade вместо полёта в устаревший прямоугольник" — must not leave a stale,
    /// still-attached geometry animation (`isRemovedOnCompletion = false`) overriding the fresh
    /// model value the next `buildTransitionVisuals` call just wrote). Unlike
    /// `finishInPlace(on:keyPaths:)` this does not touch `isActive`/`isManual`/the token — the
    /// caller is always about to call `play`/`arm` again in the same reconcile pass, and a
    /// keyPath that *is* being kept (e.g. a still-valid geometry retarget, or another role's
    /// crossfade) is untouched because it is simply not passed here.
    ///
    /// Ownership: mutates only the layers passed in. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func clearStaleAnimations(keyPaths: [String], on layers: [CALayer]) {
        for layer in layers {
            for keyPath in keyPaths {
                layer.removeAnimation(forKey: Self.animationKey(for: keyPath))
            }
        }
    }

    /// Leaves manual mode without moving anything. The caller is about to call `play` again to
    /// settle automatically; `play` retargets from each layer's current (frozen) presentation
    /// value on its own, so nothing needs to move here. Safe to call when not in manual mode.
    ///
    /// Ownership: touches no layer. Isolation: MainActor. Errors: none. Cancellation: not
    /// applicable.
    func endManual() {
        isManual = false
    }
}
