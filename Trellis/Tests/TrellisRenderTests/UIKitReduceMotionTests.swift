#if canImport(UIKit)
    import Testing
    import UIKit

    @testable import TrellisCore
    @testable import TrellisRender
    @testable import TrellisUIKit

    // M05 (implementation-plan-5.md §5, D67): `TrellisHostView` installs `ReduceMotionKey` on
    // the root at `attach` from `UIAccessibility.isReduceMotionEnabled`, and again whenever the
    // system setting changes — mirrors T09's `LocaleKey` wiring
    // (`UIKitTextEnvironmentTests.swift`). Only really executes on iOS/tvOS Simulator; this
    // file compiles to nothing under a macOS `swift test` run.

    @MainActor
    private func waitForCommit(_ host: TrellisHostView) async {
        for _ in 0..<10_000 where host.layer.sublayers?.isEmpty != false { await Task.yield() }
    }

    @Test @MainActor
    func m05_attachInstallsTheSystemReduceMotionValue() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let host = TrellisHostView()
        host.frame = window.bounds
        window.addSubview(host)
        window.makeKeyAndVisible()
        let root = Node()

        host.attach(root: root)
        await waitForCommit(host)

        #expect(root.environment.reduceMotion == UIAccessibility.isReduceMotionEnabled)

        host.detach()
    }

    @Test @MainActor
    func m05_reduceMotionChangeNotificationUpdatesTheAttachedTree() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let host = TrellisHostView()
        host.frame = window.bounds
        window.addSubview(host)
        window.makeKeyAndVisible()
        let root = Node()

        host.attach(root: root)
        await waitForCommit(host)
        let revisionBefore = root.environmentSnapshot.revision

        // The host cannot control the real system setting in a test; it can only be told the
        // notification fired, exactly as it would react to a genuine change (the host's own
        // handler re-reads `UIAccessibility.isReduceMotionEnabled`, so this exercises the same
        // code path a real Settings-driven change would).
        NotificationCenter.default.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        for _ in 0..<10_000 where root.environmentSnapshot.revision <= revisionBefore {
            await Task.yield()
        }

        #expect(root.environmentSnapshot.revision > revisionBefore)
        #expect(root.environment.reduceMotion == UIAccessibility.isReduceMotionEnabled)

        host.detach()
    }
#endif
