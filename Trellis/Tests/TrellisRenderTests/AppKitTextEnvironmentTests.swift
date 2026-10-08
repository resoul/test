#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // T09 (implementation-plan-4.md §5): `TrellisHostView` installs `TextRendererKey`
    // (`CoreTextRenderer` from `TrellisRender`) and `LocaleKey` on the root at `attach`, and
    // `LocaleKey` again whenever the system locale changes — every `TextNode` in the subtree
    // then measures with real CoreText instead of the headless `PortableTextMeasurer` fallback
    // (D51/#40).

    @MainActor
    private func waitForAppKitRootLayer(_ hostLayer: CALayer) async {
        for _ in 0..<10_000 where hostLayer.sublayers?.isEmpty != false { await Task.yield() }
    }

    @Test @MainActor
    func t09_attachInstallsCoreTextRendererAndTheSystemLocale() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let root = Node()
        let hostLayer = try #require(host.layer)

        host.attach(root: root)
        await waitForAppKitRootLayer(hostLayer)

        #expect(root.environment.textRenderer is CoreTextRenderer)
        #expect(root.environment.localeIdentifier == Locale.current.identifier)

        host.detach()
    }

    @Test @MainActor
    func t09_localeChangeNotificationRemeasuresTheAttachedTree() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let root = Node()
        let hostLayer = try #require(host.layer)

        host.attach(root: root)
        await waitForAppKitRootLayer(hostLayer)
        let revisionBefore = root.environmentSnapshot.revision

        // The host cannot control the real system locale in a test; it can only be told the
        // notification fired, exactly as it would react to a genuine change (T09's own
        // `localeDidChange` re-reads `Locale.current`, so this exercises the same code path a
        // real System Settings-driven change would).
        NotificationCenter.default.post(
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
        for _ in 0..<10_000 where root.environmentSnapshot.revision <= revisionBefore {
            await Task.yield()
        }

        #expect(root.environmentSnapshot.revision > revisionBefore)
        #expect(root.environment.localeIdentifier == Locale.current.identifier)

        host.detach()
    }

    @Test @MainActor
    func t09_hostedTextNodeMeasuresDifferentlyFromTheHeadlessFallback() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let root = Node()
        let label = TextNode(text: "Hosted CoreText measurement wraps across several lines")
        root.style.flexDirection = .column
        root.style.width = 150
        root.addSubnode(label)
        let hostLayer = try #require(host.layer)

        host.attach(root: root)
        await waitForAppKitRootLayer(hostLayer)
        let hostedHeight = try #require(label.calculatedFrame?.height)

        let headlessRoot = Node()
        let headlessLabel = TextNode(
            text: "Hosted CoreText measurement wraps across several lines"
        )
        headlessRoot.style.flexDirection = .column
        headlessRoot.style.width = 150
        headlessRoot.addSubnode(headlessLabel)
        let headlessHostLayer = CALayer()
        let headlessBridge = NodeHostBridge(hostLayer: headlessHostLayer)
        #expect(
            headlessBridge.attach(
                root: headlessRoot,
                bounds: LayoutFrame(width: 300, height: 200),
                scale: 2
            )
        )
        for _ in 0..<10_000 where headlessBridge.committedCount < 1 { await Task.yield() }
        let headlessHeight = try #require(headlessLabel.calculatedFrame?.height)

        // Real CoreText line-wrapping and `PortableTextMeasurer`'s character-count model
        // diverge for real text (D51/#40, T05) — this end-to-end difference is exactly what
        // T09 wires the host to produce, closing the "без хоста — fallback, с хостом —
        // CoreText" acceptance line.
        #expect(hostedHeight != headlessHeight)

        host.detach()
    }
#endif
