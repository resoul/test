import Testing

@testable import Nodes

@Test
func aSpringGivenByPhysicalNumbersHasTheResponseAndDampingRatioTheyMake() {
    // The keyboard's spring on current systems: unit mass, critically damped.
    let keyboard = Animation.spring(mass: 1, stiffness: 555.0265, damping: 47.118, duration: 0.658)
    guard case .spring(let response, let ratio) = keyboard.curve else {
        Issue.record("not a spring")
        return
    }

    #expect(abs(response - 0.2667) < 0.001)
    #expect(abs(ratio - 1) < 0.001)
    #expect(keyboard.duration == 0.658)

    // The same motion with twice the mass: twice the stiffness and damping.
    let heavy = Animation.spring(mass: 2, stiffness: 1110.053, damping: 94.236, duration: 0.658)
    guard case .spring(let heavyResponse, let heavyRatio) = heavy.curve else {
        Issue.record("not a spring")
        return
    }
    #expect(abs(heavyResponse - response) < 0.001)
    #expect(abs(heavyRatio - ratio) < 0.001)

    // A softer one swings past its end: a ratio under 1.
    let bouncy = Animation.spring(mass: 1, stiffness: 400, damping: 10, duration: 1)
    guard case .spring(_, let bouncyRatio) = bouncy.curve else {
        Issue.record("not a spring")
        return
    }
    #expect(abs(bouncyRatio - 0.25) < 0.001)
}

@Test
func aCriticallyDampedSpringComesToItsEndWithoutPassingItAndIsNearlyThereWhenTheSystemSaysSo() {
    let keyboard = Animation.spring(mass: 1, stiffness: 555.0265, damping: 47.118, duration: 0.658)

    var previous = 0.0
    for step in 1...20 {
        let progress = keyboard.progress(at: 0.658 * Double(step) / 20)
        #expect(progress >= previous)
        #expect(progress <= 1.0001)
        previous = progress
    }
    // Most of the way in the first third of the time, as the keyboard moves.
    #expect(keyboard.progress(at: 0.2) > 0.85)
    #expect(keyboard.progress(at: 0.65) > 0.99)
}
