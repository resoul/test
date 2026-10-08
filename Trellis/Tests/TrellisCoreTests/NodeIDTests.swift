import Testing

@testable import TrellisCore

@Test @MainActor
func test_allocator_issuesDistinctIdentities() {
    let issued = (0..<128).map { _ in NodeIDAllocator.allocate() }

    #expect(Set(issued).count == issued.count)
}

@Test @MainActor
func test_allocator_neverReissuesAcrossSeparateCalls() {
    let first = NodeIDAllocator.allocate()
    let second = NodeIDAllocator.allocate()

    #expect(first != second)
}

@Test
func test_equality_followsUnderlyingValue() {
    #expect(NodeID(rawValue: 7) == NodeID(rawValue: 7))
    #expect(NodeID(rawValue: 7) != NodeID(rawValue: 8))
}

@Test
func test_hashing_letsIdentityActAsDictionaryKey() {
    var storage: [NodeID: String] = [:]
    storage[NodeID(rawValue: 1)] = "root"
    storage[NodeID(rawValue: 2)] = "child"

    #expect(storage[NodeID(rawValue: 1)] == "root")
    #expect(storage[NodeID(rawValue: 2)] == "child")
    #expect(storage[NodeID(rawValue: 3)] == nil)
}

@Test
func test_description_isCompactAndPrefixed() {
    #expect("\(NodeID(rawValue: 42))" == "#42")
}
