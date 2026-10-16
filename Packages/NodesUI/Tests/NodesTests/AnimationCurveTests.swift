import Testing

@testable import Nodes

@Test
func namedCurvesGoFromStartToEndAlongCoreAnimationsBeziers() {
    let linear = Animation.linear(duration: 2)
    let easeIn = Animation.easeIn(duration: 2)
    let easeOut = Animation.easeOut(duration: 2)
    let easeInOut = Animation.easeInOut(duration: 2)
    for animation in [linear, easeIn, easeOut, easeInOut] {
        #expect(animation.progress(at: 0) == 0)
        #expect(animation.progress(at: 2) == 1)
        #expect(animation.progress(at: 3) == 1)
    }

    #expect(linear.progress(at: 0.5) == 0.25)
    #expect(abs(easeInOut.progress(at: 1) - 0.5) < 1e-6)
    // The ease in and out of CSS and Core Animation at a quarter of the time.
    #expect(abs(easeInOut.progress(at: 0.5) - 0.1291) < 1e-3)
    #expect(easeIn.progress(at: 0.5) < 0.25)
    #expect(easeOut.progress(at: 0.5) > 0.25)
    #expect(abs(easeIn.progress(at: 0.5) + easeOut.progress(at: 1.5) - 1) < 1e-6)
}

@Test
func aSpringOvershootsOnlyBelowCriticalDamping() {
    for (damping, overshoots) in [(0.5, true), (1.0, false), (2.0, false)] {
        let spring = Animation.spring(response: 0.4, dampingRatio: damping)
        let samples = (0...200).map { spring.progress(at: spring.duration * Double($0) / 200) }

        #expect(samples.first == 0)
        #expect(samples.last == 1)
        #expect((samples.max()! > 1.001) == overshoots, "damping \(damping)")
        // By the time it ends, the swing is down to about a thousandth.
        #expect(abs(spring.progress(at: spring.duration * 0.999) - 1) < 0.01)
        if !overshoots {
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
        }
    }
}
