import Testing

@testable import TrellisCore

@Test @MainActor
func test_layoutPlacement_storesIdentityAndFrame() {
    let identity = NodeIDAllocator.allocate()
    let frame = LayoutFrame(width: 100, height: 50)

    let placement = LayoutPlacement(identity: identity, frame: frame)

    #expect(placement.identity == identity)
    #expect(placement.frame == frame)
}

@Test @MainActor
func test_layoutResult_storesPlacementsAndTreeIdentity() {
    let root = NodeIDAllocator.allocate()
    let child = NodeIDAllocator.allocate()
    let placements = [
        LayoutPlacement(identity: root, frame: LayoutFrame(width: 390, height: 844)),
        LayoutPlacement(identity: child, frame: LayoutFrame(width: 200, height: 100)),
    ]

    let result = LayoutResult(placements: placements, treeIdentity: root)

    #expect(result.placements == placements)
    #expect(result.treeIdentity == root)
}

@Test @MainActor
func test_layoutResult_equalContentIsEqualValue() {
    let root = NodeIDAllocator.allocate()
    let a = LayoutResult(
        placements: [LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10))],
        treeIdentity: root
    )
    let b = LayoutResult(
        placements: [LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10))],
        treeIdentity: root
    )

    #expect(a == b)
}

@Test @MainActor
func test_placement_returnsPlacementForExistingIdentity() {
    let root = NodeIDAllocator.allocate()
    let child = NodeIDAllocator.allocate()
    let childFrame = LayoutFrame(width: 20, height: 30)
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root, frame: LayoutFrame(width: 100, height: 100)),
            LayoutPlacement(identity: child, frame: childFrame),
        ],
        treeIdentity: root
    )

    #expect(result.placement(for: child)?.frame == childFrame)
}

@Test @MainActor
func test_placement_returnsNilForMissingIdentity() {
    let root = NodeIDAllocator.allocate()
    let missing = NodeIDAllocator.allocate()
    let result = LayoutResult(
        placements: [LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10))],
        treeIdentity: root
    )

    #expect(result.placement(for: missing) == nil)
}

@Test @MainActor
func test_isWellFormed_trueAndDuplicateIdentitiesEmptyForOrdinaryResult() {
    let root = NodeIDAllocator.allocate()
    let child = NodeIDAllocator.allocate()
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10)),
            LayoutPlacement(identity: child, frame: LayoutFrame(width: 5, height: 5)),
        ],
        treeIdentity: root
    )

    #expect(result.isWellFormed)
    #expect(result.duplicateIdentities.isEmpty)
}

@Test @MainActor
func test_duplicateIdentities_detectsARepeatedIdentity() {
    let root = NodeIDAllocator.allocate()
    let duplicated = NodeIDAllocator.allocate()
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10)),
            LayoutPlacement(identity: duplicated, frame: LayoutFrame(width: 1, height: 1)),
            LayoutPlacement(identity: duplicated, frame: LayoutFrame(width: 2, height: 2)),
        ],
        treeIdentity: root
    )

    #expect(result.isWellFormed == false)
    #expect(result.duplicateIdentities == [duplicated])
}

@Test @MainActor
func test_placement_forDuplicatedIdentityDeterministicallyReturnsFirstOccurrenceNotLast() {
    let root = NodeIDAllocator.allocate()
    let duplicated = NodeIDAllocator.allocate()
    let firstFrame = LayoutFrame(width: 1, height: 1)
    let lastFrame = LayoutFrame(width: 2, height: 2)
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10)),
            LayoutPlacement(identity: duplicated, frame: firstFrame),
            LayoutPlacement(identity: duplicated, frame: lastFrame),
        ],
        treeIdentity: root
    )

    #expect(result.placement(for: duplicated)?.frame == firstFrame)
}

@Test @MainActor
func test_duplicateIdentities_onlyNamesIdentitiesThatActuallyRepeat() {
    let root = NodeIDAllocator.allocate()
    let unique = NodeIDAllocator.allocate()
    let duplicated = NodeIDAllocator.allocate()
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root, frame: LayoutFrame(width: 10, height: 10)),
            LayoutPlacement(identity: unique, frame: LayoutFrame(width: 1, height: 1)),
            LayoutPlacement(identity: duplicated, frame: LayoutFrame(width: 2, height: 2)),
            LayoutPlacement(identity: duplicated, frame: LayoutFrame(width: 3, height: 3)),
        ],
        treeIdentity: root
    )

    #expect(result.duplicateIdentities == [duplicated])
}

@Test @MainActor
func test_placement_lookupIsCorrectAcrossManyPlacements() {
    // Ordinary correctness check, not a timing benchmark — this does not stand in for proof
    // of O(1) lookup, only that the index agrees with the array for every entry.
    let identities = (0..<500).map { _ in NodeIDAllocator.allocate() }
    let placements = identities.enumerated().map {
        LayoutPlacement(identity: $1, frame: LayoutFrame(width: Double($0), height: Double($0)))
    }
    let result = LayoutResult(placements: placements, treeIdentity: identities[0])

    for (offset, identity) in identities.enumerated() {
        #expect(result.placement(for: identity)?.frame.width == Double(offset))
    }
}
