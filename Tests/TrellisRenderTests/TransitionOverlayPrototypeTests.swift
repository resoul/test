import Foundation
import QuartzCore
import Testing

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// M10 — контракт составного перехода и ранний прототип (implementation-plan-5.md §6,
// docs/validation/m10-transition-contract.md). Как и M02
// (AnimationPrototypeTests.swift) и T02 (TextRasterPrototypeTests.swift), код здесь не
// претендует на production API — ничего в `TrellisCore`/`TrellisRender` не меняется этой
// карточкой (M11+). Проверяется только платформенный механизм, которым предлагается
// закрыть D70–D74: один overlay-слой с двумя endpoint-растрами заголовка и crossfade
// (D71), общий ручной progress через `speed = 0` + `timeOffset` без display-link и без
// повторного solve/raster на кадр (D72), и непрерывность (no-jump) при развороте
// направления посреди движения тем же presentation-retarget приёмом, что и D66 —
// применённым не к одному свойству одного слоя (M02), а согласованно к нескольким
// слоям одной transition-сессии сразу.
//
// Как и в AnimationPrototypeTests.swift, каждый слой монтируется под
// `WindowHost.containerLayer` (реальное окно) — без монтирования `presentation()`
// ненадёжен (см. M02 §2); `WindowHost` здесь — независимая копия того же паттерна, не
// импорт из соседнего файла (обе копии `private`, тот же прецедент, что и в M02).

/// A real, on-screen window+view. See AnimationPrototypeTests.swift's `WindowHost` doc
/// comment for why a bare, unmounted `CALayer` graph is not sufficient here — the same
/// reasoning applies verbatim to a transition overlay's layers.
@MainActor
private final class WindowHost {
    let containerLayer: CALayer
    #if canImport(AppKit)
        private let window: NSWindow
    #elseif canImport(UIKit)
        private let window: UIWindow
    #endif

    init() {
        #if canImport(AppKit)
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            view.wantsLayer = true
            window = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            containerLayer = view.layer!
        #elseif canImport(UIKit)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            let view = UIView(frame: window.bounds)
            window.addSubview(view)
            window.makeKeyAndVisible()
            containerLayer = view.layer
        #endif
    }

    /// Spins a real run loop briefly — see `AnimationPrototypeTests.swift`'s `WindowHost`
    /// doc comment (M02 §2) for why `swift test` needs this pumped explicitly. Manual
    /// `timeOffset` scrubbing needs it too: a freshly created window's very first
    /// `presentation()` read is only reliable after the window has completed at least one
    /// real display pass, found while writing this file — without it, the first
    /// `presentation()` read after `setManualProgress` can still reflect the pre-scrub
    /// (progress 0) state even though the model/`timeOffset` was already updated and
    /// flushed.
    func pump(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

/// One endpoint (source card or destination page) of a composite transition — D70's
/// "исходное и целевое представление": geometry in host space, corner radius, and the
/// width its own title raster wraps at. `text` is a local fixture, not a network
/// `ImageNode` (D71: "сетевой loader, ImageNode и весь N02 не становятся скрытой
/// зависимостью").
private struct TransitionEndpoint {
    let frame: CGRect
    let cornerRadius: CGFloat
    let title: String
    let titleWidth: CGFloat

    var position: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
}

/// D71's "один переход, несколько согласованных частей" (D70) reduced to the minimum
/// that exercises the mechanism: one hero container (geometry: position/bounds/
/// cornerRadius, D61's own table — no new CALayer property required, matching M01 §4a's
/// sketch) plus two endpoint title rasters that crossfade in place (D71's "два
/// endpoint-растра с согласованным положением и crossfade", not a re-wrap on every
/// frame). Every animated layer here shares one `duration` and is driven by the same
/// `timeOffset`, which is the concrete shape of D70's "все части используют единый
/// progress 0…1, собственные интервалы и кривые внутри него" — shared progress driver,
/// per-layer timing function.
@MainActor
private final class TransitionOverlayHarness {
    let hero = CALayer()
    let sourceTitle = CALayer()
    let destinationTitle = CALayer()

    private(set) var rasterCallCount = 0
    private var duration: CFTimeInterval = 0
    private let host: WindowHost

    init(mountedUnder host: WindowHost, source: TransitionEndpoint, destination: TransitionEndpoint)
    {
        self.host = host
        let container = host.containerLayer
        hero.addSublayer(sourceTitle)
        hero.addSublayer(destinationTitle)
        container.addSublayer(hero)
        // Warms up the window's real display pass once, before any scrub — see `pump`'s
        // doc comment.
        host.pump(for: 0.05)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hero.position = source.position
        hero.bounds = source.bounds
        hero.cornerRadius = source.cornerRadius
        sourceTitle.frame = source.bounds.insetBy(dx: 8, dy: 8)
        destinationTitle.frame = source.bounds.insetBy(dx: 8, dy: 8)
        sourceTitle.opacity = 1
        destinationTitle.opacity = 0
        sourceTitle.contents = raster(text: source.title, width: source.titleWidth)
        destinationTitle.contents = raster(text: destination.title, width: destination.titleWidth)
        CATransaction.commit()
    }

    private func raster(text: String, width: CGFloat) -> CGImage {
        rasterCallCount += 1
        return RasterProbe.run(text: text, pointSize: 17, maxWidth: width, scale: 2).image
    }

    /// D71/D72: measures/prepares once (both title rasters already exist from `init`,
    /// modelling "destination measured and readied before motion starts"), then arms one
    /// explicit `CABasicAnimation` per geometry key plus the title crossfade, all with
    /// `fillMode = .both`/`isRemovedOnCompletion = false` and `speed = 0` — the D72 shape
    /// for "renderer применяет progress от входных событий... без solve/raster на каждое
    /// событие": no animation is re-created per progress sample, only `timeOffset` moves.
    func prepareOpen(
        from source: TransitionEndpoint,
        to destination: TransitionEndpoint,
        duration: CFTimeInterval
    ) {
        self.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        addGeometryAnimations(from: source, to: destination, duration: duration)

        let sourceFade = CABasicAnimation(keyPath: "opacity")
        sourceFade.fromValue = Float(1)
        sourceFade.toValue = Float(0)
        sourceFade.duration = duration
        sourceFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        applyManualDriver(sourceFade)
        sourceTitle.add(sourceFade, forKey: "opacity")

        let destinationFade = CABasicAnimation(keyPath: "opacity")
        destinationFade.fromValue = Float(0)
        destinationFade.toValue = Float(1)
        destinationFade.duration = duration
        destinationFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        applyManualDriver(destinationFade)
        destinationTitle.add(destinationFade, forKey: "opacity")

        // Model values already sit at the destination (D66 step 2: final value written with
        // actions disabled before the explicit animation is added) — presentation is what
        // manual `timeOffset` scrubbing exposes below.
        hero.position = destination.position
        hero.bounds = destination.bounds
        hero.cornerRadius = destination.cornerRadius
        sourceTitle.opacity = 0
        destinationTitle.opacity = 1

        for layer in [hero, sourceTitle, destinationTitle] {
            layer.speed = 0
            layer.timeOffset = 0
        }
        CATransaction.commit()
    }

    private func addGeometryAnimations(
        from source: TransitionEndpoint,
        to destination: TransitionEndpoint,
        duration: CFTimeInterval
    ) {
        let pairs: [(String, CGFloat, CGFloat)] = [
            ("position.x", source.position.x, destination.position.x),
            ("position.y", source.position.y, destination.position.y),
            ("bounds.size.width", source.bounds.width, destination.bounds.width),
            ("bounds.size.height", source.bounds.height, destination.bounds.height),
            ("cornerRadius", source.cornerRadius, destination.cornerRadius),
        ]
        for (keyPath, from, to) in pairs {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            applyManualDriver(animation)
            hero.add(animation, forKey: keyPath)
        }
    }

    private func applyManualDriver(_ animation: CABasicAnimation) {
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
    }

    /// Manual scrub (D72's interactive phase): moves every part of the session together by
    /// setting the same `timeOffset` on every animated layer — the single shared progress
    /// D70 requires, not one progress per layer. `CATransaction.flush()` forces the
    /// presentation tree to recompute synchronously so a deterministic test can read it back
    /// immediately, the same real-window requirement M02 §2 documents for plain
    /// `presentation()` reads.
    func setManualProgress(_ progress: Double) {
        let clamped = max(0, min(1, progress))
        let offset = duration * clamped
        for layer in [hero, sourceTitle, destinationTitle] {
            layer.timeOffset = offset
        }
        CATransaction.flush()
        host.pump(for: 0.02)
    }

    /// D72's "повторное действие во время движения меняет направление текущей session, не
    /// создаёт вторую копию слоёв" — reverses towards 0 (cancel) starting from whatever
    /// `timeOffset`/progress the session is currently scrubbed to, continuously (D66's
    /// "новая цель начинается от видимого значения" applied to the whole session's shared
    /// driver, not per-property): no snap back to progress 0 before playing backward.
    func reverseToward(progress target: Double, from current: Double) -> [CGFloat] {
        let before = currentPositionX()
        setManualProgress(target)
        let after = currentPositionX()
        // Both samples returned so the caller can assert continuity itself — this harness
        // does not hide the jump/no-jump distinction behind a boolean.
        return [before, after]
    }

    func currentPositionX() -> CGFloat {
        (hero.presentation()?.value(forKeyPath: "position.x") as? CGFloat) ?? hero.position.x
    }

    func currentCornerRadius() -> CGFloat {
        hero.presentation()?.cornerRadius ?? hero.cornerRadius
    }

    func currentOpacity(of layer: CALayer) -> Float {
        layer.presentation()?.opacity ?? layer.opacity
    }

    func titleContentsIdentity(_ layer: CALayer) -> ObjectIdentifier? {
        guard let contents = layer.contents else { return nil }
        return ObjectIdentifier(contents as! CGImage)
    }
}

private let sourceEndpoint = TransitionEndpoint(
    frame: CGRect(x: 20, y: 480, width: 300, height: 120),
    cornerRadius: 16,
    title: "Composite transition prototype card",
    titleWidth: 260
)

private let destinationEndpoint = TransitionEndpoint(
    frame: CGRect(x: 0, y: 0, width: 390, height: 700),
    cornerRadius: 0,
    title:
        "Composite transition prototype card, now on its own page with much more room to breathe",
    titleWidth: 350
)

@Test @MainActor
func m10_manualProgressAtZeroHalfAndOneInterpolatesHeroGeometryWithoutRestartingItEachTime() {
    let host = WindowHost()
    let harness = TransitionOverlayHarness(
        mountedUnder: host,
        source: sourceEndpoint,
        destination: destinationEndpoint
    )
    harness.prepareOpen(from: sourceEndpoint, to: destinationEndpoint, duration: 1.0)

    harness.setManualProgress(0)
    let atStart = harness.currentPositionX()
    #expect(abs(atStart - sourceEndpoint.position.x) < 1)

    harness.setManualProgress(0.5)
    let atHalf = harness.currentPositionX()
    let expectedHalf = (sourceEndpoint.position.x + destinationEndpoint.position.x) / 2
    #expect(abs(atHalf - expectedHalf) < 2)
    #expect(
        atHalf > atStart,
        "halfway sample must sit strictly between the endpoints, not repeat 0"
    )

    harness.setManualProgress(1)
    let atEnd = harness.currentPositionX()
    #expect(abs(atEnd - destinationEndpoint.position.x) < 1)

    // cornerRadius travels the same shared driver (D70: one progress, several parts).
    harness.setManualProgress(0.5)
    let radiusAtHalf = harness.currentCornerRadius()
    let expectedRadius = (sourceEndpoint.cornerRadius + destinationEndpoint.cornerRadius) / 2
    #expect(abs(radiusAtHalf - expectedRadius) < 1)
}

@Test @MainActor
func m10_titleCrossfadeUsesTwoEndpointRastersNotARepeatedRewrap() {
    let host = WindowHost()
    let harness = TransitionOverlayHarness(
        mountedUnder: host,
        source: sourceEndpoint,
        destination: destinationEndpoint
    )
    // Two rasters made during `init` — one per endpoint width, D71's "два endpoint-растра".
    #expect(harness.rasterCallCount == 2)
    let sourceIdentity = harness.titleContentsIdentity(harness.sourceTitle)
    let destinationIdentity = harness.titleContentsIdentity(harness.destinationTitle)
    #expect(sourceIdentity != nil)
    #expect(destinationIdentity != nil)
    #expect(
        sourceIdentity != destinationIdentity,
        "two distinct bitmaps at two distinct widths, not one bitmap stretched across both"
    )

    harness.prepareOpen(from: sourceEndpoint, to: destinationEndpoint, duration: 1.0)

    // Crossfade opacity, not a raster call, carries the transition — scrubbing progress
    // must not trigger any additional raster job (D71: "промежуточный текст не
    // перемеряется каждый кадр").
    for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
        harness.setManualProgress(progress)
    }
    #expect(harness.rasterCallCount == 2, "manual progress scrubbing must not re-raster")

    harness.setManualProgress(0)
    #expect(harness.currentOpacity(of: harness.sourceTitle) > 0.9)
    #expect(harness.currentOpacity(of: harness.destinationTitle) < 0.1)

    harness.setManualProgress(1)
    #expect(harness.currentOpacity(of: harness.sourceTitle) < 0.1)
    #expect(harness.currentOpacity(of: harness.destinationTitle) > 0.9)

    // Identity unchanged by the crossfade itself — only opacity moved.
    #expect(harness.titleContentsIdentity(harness.sourceTitle) == sourceIdentity)
    #expect(harness.titleContentsIdentity(harness.destinationTitle) == destinationIdentity)
}

@Test @MainActor
func m10_reverseMotionContinuesFromTheVisiblePositionWithoutAJump() {
    let host = WindowHost()
    let harness = TransitionOverlayHarness(
        mountedUnder: host,
        source: sourceEndpoint,
        destination: destinationEndpoint
    )
    harness.prepareOpen(from: sourceEndpoint, to: destinationEndpoint, duration: 1.0)

    // Drive forward to 0.7 (an in-flight interactive open), then reverse — D72's "решение
    // finish/cancel учитывает progress" reduced to its geometric core: the reversed sample
    // must equal the last forward sample, not the session's original (progress 0) position.
    harness.setManualProgress(0.7)
    let beforeReverse = harness.currentPositionX()

    let samples = harness.reverseToward(progress: 0.4, from: 0.7)
    let sampledBeforeReverse = samples[0]
    let afterReverseStep = samples[1]

    #expect(
        abs(sampledBeforeReverse - beforeReverse) < 0.001,
        "reverse must sample the driver before moving it, not after"
    )
    #expect(
        afterReverseStep < beforeReverse,
        "moving back toward the source must decrease position.x, not jump ahead"
    )

    // Continue reversing all the way to the source — still the same hero layer, same
    // session, no second copy of the transition's layers (D72).
    harness.setManualProgress(0)
    #expect(abs(harness.currentPositionX() - sourceEndpoint.position.x) < 1)
}

@Test @MainActor
func m10_repeatedOpenReversesTheSameSessionRatherThanCreatingASecondCopyOfItsLayers() {
    let host = WindowHost()
    let harness = TransitionOverlayHarness(
        mountedUnder: host,
        source: sourceEndpoint,
        destination: destinationEndpoint
    )
    harness.prepareOpen(from: sourceEndpoint, to: destinationEndpoint, duration: 1.0)
    let heroBefore = harness.hero
    let sourceTitleBefore = harness.sourceTitle
    let destinationTitleBefore = harness.destinationTitle

    harness.setManualProgress(0.3)
    harness.setManualProgress(0.6)
    harness.setManualProgress(0.2)  // direction reversed mid-session

    // D72: "не создаёт вторую копию слоёв" — same three CALayer instances throughout, only
    // one hero layer under the mounted container.
    #expect(harness.hero === heroBefore)
    #expect(harness.sourceTitle === sourceTitleBefore)
    #expect(harness.destinationTitle === destinationTitleBefore)
    #expect(host.containerLayer.sublayers?.filter { $0 === harness.hero }.count == 1)
}
