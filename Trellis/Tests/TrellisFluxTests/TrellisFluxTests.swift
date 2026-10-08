import Testing
@testable import TrellisFlux

/// R02 acceptance: a consumer of this target uses the *real* Flux from the pinned
/// dependency, not a stub. These are not R03's state-binding/lifecycle tests.
@Suite
struct TrellisFluxTests {
    @Test func fluxVersionMatchesThePinnedPackageDependency() {
        #expect(TrellisFlux.fluxVersion == "1.2.1")
    }

    @Test func reExportedFluxCurrentValueDeliversRealUpdates() async {
        let state = CurrentValue(0)
        await state.set(1)
        #expect(await state.value == 1)
        var iterator = state.stream.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        await state.set(2)
        #expect(await iterator.next() == 2)
    }
}
