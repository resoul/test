#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore
    @testable import TrellisRender

    // M05 (implementation-plan-5.md §5, D67): `TrellisHostView` installs `ReduceMotionKey` on
    // the root at `attach` from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`,
    // and again whenever the system setting changes — mirrors T09's `LocaleKey` wiring
    // (`AppKitTextEnvironmentTests.swift`).

    @MainActor
    private func waitForAppKitRootLayer(_ hostLayer: CALayer) async {
        for _ in 0..<10_000 where hostLayer.sublayers?.isEmpty != false { await Task.yield() }
    }

    @Test @MainActor
    func m05_attachInstallsTheSystemReduceMotionValue() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let root = Node()
        let hostLayer = try #require(host.layer)

        host.attach(root: root)
        await waitForAppKitRootLayer(hostLayer)

        #expect(
            root.environment.reduceMotion
                == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        host.detach()
    }

    @Test @MainActor
    func m05_reduceMotionChangeNotificationUpdatesTheAttachedTree() async throws {
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let root = Node()
        let hostLayer = try #require(host.layer)

        host.attach(root: root)
        await waitForAppKitRootLayer(hostLayer)
        let revisionBefore = root.environmentSnapshot.revision

        // The host cannot control the real system setting in a test; it can only be told the
        // notification fired, exactly as it would react to a genuine change (the host's own
        // handler re-reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, so this
        // exercises the same code path a real System Settings-driven change would) — and this
        // notification posts on `NSWorkspace.shared.notificationCenter`, not the default center
        // (see `TrellisHostView.installReduceMotionObserver`'s own doc comment).
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        for _ in 0..<10_000 where root.environmentSnapshot.revision <= revisionBefore {
            await Task.yield()
        }

        #expect(root.environmentSnapshot.revision > revisionBefore)
        #expect(
            root.environment.reduceMotion
                == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        host.detach()
    }
#endif
