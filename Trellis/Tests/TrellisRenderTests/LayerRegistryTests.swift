import QuartzCore
import Testing

@testable import TrellisCore
@testable import TrellisRender

// These tests run under `swift test` on macOS, without a simulator and without NSView:
// CALayer is directly available on macOS. This proves that the shared platform-neutral
// renderer works on a second platform well before the AppKit host appears.

@Test @MainActor
func test_registry_returnsNilForUnknownIdentity() {
    let registry = LayerRegistry()

    #expect(registry.layer(for: NodeIDAllocator.allocate()) == nil)
    #expect(registry.count == 0)
}

@Test @MainActor
func test_registry_storesAndReturnsSameLayerInstance() {
    let registry = LayerRegistry()
    let identity = NodeIDAllocator.allocate()
    let layer = CALayer()

    registry.set(layer, for: identity)

    #expect(registry.layer(for: identity) === layer)
    #expect(registry.count == 1)
    #expect(registry.identities == [identity])
}

@Test @MainActor
func test_registry_replacingEntryHandsBackPreviousLayer() {
    let registry = LayerRegistry()
    let identity = NodeIDAllocator.allocate()
    let first = CALayer()
    let second = CALayer()

    registry.set(first, for: identity)
    let displaced = registry.set(second, for: identity)

    #expect(displaced === first)
    #expect(registry.layer(for: identity) === second)
    #expect(registry.count == 1)
}

@Test @MainActor
func test_registry_removeHandsBackLayerAndForgetsIdentity() {
    let registry = LayerRegistry()
    let identity = NodeIDAllocator.allocate()
    let layer = CALayer()
    registry.set(layer, for: identity)

    let removed = registry.remove(identity)

    #expect(removed === layer)
    #expect(registry.layer(for: identity) == nil)
    #expect(registry.remove(identity) == nil)
}

@Test @MainActor
func test_registry_removeAllHandsBackEveryLayer() {
    let registry = LayerRegistry()
    let identities = (0..<3).map { _ in NodeIDAllocator.allocate() }
    let layers = identities.map { identity -> CALayer in
        let layer = CALayer()
        registry.set(layer, for: identity)
        return layer
    }

    let removed = registry.removeAll()

    #expect(removed.count == 3)
    #expect(layers.allSatisfy { layer in removed.contains { $0 === layer } })
    #expect(registry.count == 0)
}
