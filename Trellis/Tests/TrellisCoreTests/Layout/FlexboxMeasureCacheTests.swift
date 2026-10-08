import Testing

@testable import TrellisCore

// Ported from Weave's FlexMeasureCacheTests.swift. Its fifth test,
// `test_layoutEngine_createsNewCachePerRequest`, exercises Weave's scheduler
// (`LayoutEngine(solver:)`) — Trellis's scheduler is `LayoutScheduler` (D11) and does not exist
// yet (C13), so that test is deferred there rather than ported now.

private func cacheKey(_ raw: UInt64, revision: UInt64 = 0, width: Double = 100)
    -> LayoutMeasureCacheKey
{
    LayoutMeasureCacheKey(
        treeIdentity: flexID(raw),
        contentRevision: revision,
        environmentRevision: 0,
        constraint: SizeConstraint(width: .exact(width)),
        direction: .leftToRight
    )
}

private func cachedResult(for key: LayoutMeasureCacheKey) -> FlexMeasureResult {
    FlexMeasureResult(parentSize: MeasuredSize(width: 1, height: 1), lines: [], cacheKey: key)
}

@Test
func test_measureCache_hitOnUnchangedSubtree_skipsRecursion() throws {
    let leaf = LayoutInputSnapshot(
        identity: flexID(2),
        style: flexStyle(width: .points(40), height: .points(20))
    )
    let root = LayoutInputSnapshot(
        identity: flexID(1),
        style: flexStyle(width: .points(100)),
        children: [leaf]
    )
    var cache = FlexMeasureCache()

    let first = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(100)),
        cache: &cache
    )
    let second = try FlexboxEngine.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .exact(100)),
        cache: &cache
    )

    #expect(first == second)
    #expect(cache.lookup(key: first.cacheKey) == first)
}

@Test
func test_measureCache_missOnContentRevisionChange() throws {
    let firstInput = LayoutInputSnapshot(identity: flexID(1), contentRevision: 1)
    let secondInput = LayoutInputSnapshot(identity: flexID(1), contentRevision: 2)
    var cache = FlexMeasureCache()

    let first = try FlexboxEngine.measureContainer(input: firstInput, cache: &cache)
    let second = try FlexboxEngine.measureContainer(input: secondInput, cache: &cache)

    #expect(first.cacheKey != second.cacheKey)
    #expect(cache.lookup(key: first.cacheKey) == first)
    #expect(cache.lookup(key: second.cacheKey) == second)
}

@Test
func test_measureCache_missOnConstraintChange() throws {
    let input = LayoutInputSnapshot(identity: flexID(1), style: flexStyle(width: .auto))
    var cache = FlexMeasureCache()

    let narrow = try FlexboxEngine.measureContainer(
        input: input,
        constraint: SizeConstraint(width: .exact(100)),
        cache: &cache
    )
    let wide = try FlexboxEngine.measureContainer(
        input: input,
        constraint: SizeConstraint(width: .exact(200)),
        cache: &cache
    )

    #expect(narrow.cacheKey != wide.cacheKey)
    #expect(cache.lookup(key: narrow.cacheKey) == narrow)
    #expect(cache.lookup(key: wide.cacheKey) == wide)
}

@Test
func test_measureCache_keepsEveryEntryOfARealisticRequest() {
    // ADR 0007: a request-local cache must not forget entries a tree of ordinary size still
    // needs — the old 64-entry LRU did, and nesting cost 2^depth. The remaining bound is a
    // guard far above any real request (a depth-200 chain misses ~100k times, see #14) and
    // is not exercised here.
    var cache = FlexMeasureCache()
    for identity in 0..<100_000 {
        let key = cacheKey(UInt64(identity))
        cache.store(key: key, result: cachedResult(for: key))
    }
    #expect(cache.lookup(key: cacheKey(0)) != nil)
    #expect(cache.lookup(key: cacheKey(99_999)) != nil)
    #expect(FlexMeasureCache.capacity > 100_000)
}

@Test
func test_measureCache_statisticsCountLookupsHitsAndStatesPerNode() {
    var cache = FlexMeasureCache()
    #expect(
        cache.statistics
            == FlexMeasureCache.Statistics(lookups: 0, hits: 0, entries: 0, maxEntriesPerNode: 0)
    )

    _ = cache.lookup(key: cacheKey(1))
    cache.store(key: cacheKey(1), result: cachedResult(for: cacheKey(1)))
    cache.store(key: cacheKey(1, width: 50), result: cachedResult(for: cacheKey(1, width: 50)))
    cache.store(key: cacheKey(2), result: cachedResult(for: cacheKey(2)))
    _ = cache.lookup(key: cacheKey(1))
    _ = cache.lookup(key: cacheKey(3))

    #expect(
        cache.statistics
            == FlexMeasureCache.Statistics(lookups: 3, hits: 1, entries: 3, maxEntriesPerNode: 2)
    )
}
