#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore

    @MainActor
    private func waitForAppKitRootLayer(_ hostLayer: CALayer) async {
        for _ in 0..<10_000 where hostLayer.sublayers?.isEmpty != false { await Task.yield() }
    }

    @Test
    @MainActor
    func test_appKitHostView_usesFlippedLayerBackedAsymmetricTree() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let root = Node()
        let upper = Node()
        let lower = Node()
        root.style.flexDirection = .column
        upper.style.width = 60
        upper.style.height = 20
        lower.style.width = 80
        lower.style.height = 40
        root.addSubnode(upper)
        root.addSubnode(lower)
        let hostLayer = try #require(host.layer)

        #expect(host.wantsLayer)
        #expect(host.isFlipped)
        host.attach(root: root)
        await waitForAppKitRootLayer(hostLayer)

        let rootLayer = try #require(hostLayer.sublayers?.last)
        let upperLayer = try #require(rootLayer.sublayers?.first)
        let lowerLayer = try #require(rootLayer.sublayers?.last)
        #expect(rootLayer.bounds.size == CGSize(width: 180, height: 120))
        #expect(upperLayer.position.y < lowerLayer.position.y)
        #expect(upperLayer.bounds.size == CGSize(width: 60, height: 20))
        #expect(lowerLayer.bounds.size == CGSize(width: 80, height: 40))

        host.detach()
        #expect(hostLayer.sublayers?.isEmpty != false)
    }
#endif
