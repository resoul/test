import AppKit
import TrellisAppKit
import TrellisCore

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static var strongDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    private var window: NSWindow?
    private var host: TrellisHostView?
    private var instance: ScenarioInstance?
    private var currentScenarioIndex = 0
    private var popup: NSPopUpButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()

        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
        window.contentView = host

        self.window = window
        self.host = host

        setupToolbar(window: window)

        // R06 §6.1: `--perf-run` (see `PerfLaunchConfiguration`) skips scenario browsing and
        // runs the native performance harness instead, terminating once it has written its
        // report — every other launch path below is unchanged when the flag is absent.
        if runPerfHarnessIfRequested(host: host, terminate: { NSApp.terminate(nil) }) { return }

        if let exportIndex = CommandLine.arguments.firstIndex(of: "--export-all"),
            exportIndex + 1 < CommandLine.arguments.count
        {
            let exportPath = CommandLine.arguments[exportIndex + 1]
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await exportAllScreenshots(to: exportPath)
                NSApp.terminate(nil)
            }
            return
        }

        if let driveIndex = CommandLine.arguments.firstIndex(of: "--drive-focus"),
            driveIndex + 1 < CommandLine.arguments.count
        {
            let outputPath = CommandLine.arguments[driveIndex + 1]
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await driveFocus(to: outputPath)
                NSApp.terminate(nil)
            }
            return
        }

        currentScenarioIndex = Scenario.initialIndex
        switchScenario(to: currentScenarioIndex)

        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if Scenario.dumpsAccessibility {
            Task { @MainActor in
                await waitForFirstCommit()
                AccessibilityDump.print(host: host)
            }
        }
    }

    /// A11 evidence run: opens S22, feeds real `NSEvent` key events into the host's
    /// `keyDown`/`keyUp` (the same path a physical keyboard takes below the responder chain)
    /// and captures a screenshot after every step, plus the native accessibility tree of S23.
    /// This is a native automated run, not a physical-keyboard session — the report says so.
    private func driveFocus(to path: String) async {
        guard let host else { return }
        host.hostScaleOverride = 2
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let s22 = ScenarioName.allCases.firstIndex(of: .s22) else { return }
        switchScenario(to: s22)
        await waitForFirstCommit()
        for _ in 0..<30 { await Task.yield() }
        var step = 0
        func snap(_ name: String) {
            step += 1
            if let data = capture(host: host) {
                let file = dir.appendingPathComponent(String(format: "%02d-%@.png", step, name))
                try? data.write(to: file)
            }
            print(
                "A11DRIVE \(step) \(name) focused=\(String(describing: host.focusedID)) scope=\(String(describing: host.focusScopeID))"
            )
        }
        func key(_ code: UInt16, shift: Bool = false) async {
            let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
            if let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: code
            ) {
                host.keyDown(with: down)
            }
            if let up = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: code
            ) {
                host.keyUp(with: up)
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        snap("initial-focus")
        await key(48); snap("tab-to-card2")
        await key(48); snap("tab-to-card3")
        await key(48); snap("tab-to-card4")
        await key(48); snap("tab-skips-disabled-to-card6")
        await key(36); snap("return-activates-card6")
        await key(36); snap("return-activates-card6-again")
        await key(48, shift: true); snap("shift-tab-back-to-card4")
        await key(125); snap("down-to-card7")
        await key(36); snap("return-removes-card7-focus-falls-back")
        await key(124); snap("right-to-card9")
        await key(36); snap("return-opens-dialog-scope")
        await key(48); snap("tab-wraps-inside-dialog")
        await key(48); snap("tab-wraps-again")
        await key(36); snap("return-closes-dialog-restores-card9")
        await key(123); snap("left-to-card8")
        guard let s23 = ScenarioName.allCases.firstIndex(of: .s23) else { return }
        switchScenario(to: s23)
        await waitForFirstCommit()
        for _ in 0..<30 { await Task.yield() }
        AccessibilityDump.print(host: host)
        snap("s23-semantics")
    }

    private func setupToolbar(window: NSWindow) {
        let toolbar = NSToolbar(identifier: "PlaygroundToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        window.toolbar = toolbar
    }

    func switchScenario(to index: Int) {
        let cases = ScenarioName.allCases
        guard index >= 0, index < cases.count else { return }
        currentScenarioIndex = index
        let scenarioName = cases[index]

        instance?.teardown()
        host?.detach()

        let newInstance = scenarioName.make(mode: Scenario.mode)
        instance = newInstance
        window?.title = "Trellis Playground (\(scenarioName.rawValue) · \(Scenario.mode))"
        popup?.selectItem(at: index)

        if let host {
            host.attach(root: newInstance.root)
            newInstance.onAttach?(host, newInstance.bindings)
        }
    }

    @objc func scenarioSelected(_ sender: NSPopUpButton) {
        switchScenario(to: sender.indexOfSelectedItem)
    }

    @objc func previousScenario() {
        let prev =
            (currentScenarioIndex - 1 + ScenarioName.allCases.count) % ScenarioName.allCases.count
        switchScenario(to: prev)
    }

    @objc func nextScenario() {
        let next = (currentScenarioIndex + 1) % ScenarioName.allCases.count
        switchScenario(to: next)
    }

    @objc func captureCurrentScenario() {
        guard let host, let instance else { return }
        let dir = URL(fileURLWithPath: "docs/validation/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(instance.name.rawValue).png")
        if let data = capture(host: host) {
            try? data.write(to: fileURL)
            print("Saved snapshot to \(fileURL.path)")
        }
    }

    @objc func captureAllClicked() {
        Task { @MainActor in
            await exportAllScreenshots(to: "docs/validation/screenshots")
        }
    }

    /// Exports every scenario twice: as rendered, and with the debug overlay (C25) drawn on
    /// top as `<name>_overlay.png` — the overlay variant is reference evidence that the
    /// overlay tracks the committed frames of each scene without shifting them.
    func exportAllScreenshots(to path: String) async {
        guard let host else { return }
        // References are rendered at 2× regardless of the screen the window landed on: a
        // 1× external display would otherwise lay out with different pixel rounding and
        // capture at half the size (defect #17).
        let scaleWasOverridden = host.hostScaleOverride
        host.hostScaleOverride = 2
        // Dynamic scenes must be captured in phase 0 even if the first commit is slow.
        let firstTickWas = ScenarioSession.firstTickDelay
        ScenarioSession.firstTickDelay = .seconds(60)
        defer {
            host.hostScaleOverride = scaleWasOverridden
            ScenarioSession.firstTickDelay = firstTickWas
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let overlayWasEnabled = host.isDebugOverlayEnabled
        // Reference overlays name nodes by tree order, not runtime NodeID: the latter shifts
        // with every node created in an earlier scene (defect #11).
        let labelStyleWas = host.debugOverlayLabelStyle
        host.debugOverlayLabelStyle = .treeOrder
        defer {
            host.isDebugOverlayEnabled = overlayWasEnabled
            host.debugOverlayLabelStyle = labelStyleWas
        }

        for (index, scenario) in ScenarioName.allCases.enumerated() {
            host.isDebugOverlayEnabled = false
            switchScenario(to: index)
            await waitForFirstCommit()
            if let data = capture(host: host) {
                let fileURL = dir.appendingPathComponent("\(scenario.rawValue).png")
                try? data.write(to: fileURL)
                print("Exported [\(index + 1)/\(ScenarioName.allCases.count)] \(fileURL.path)")
            }
            host.isDebugOverlayEnabled = true
            if let data = capture(host: host) {
                let fileURL = dir.appendingPathComponent("\(scenario.rawValue)_overlay.png")
                try? data.write(to: fileURL)
            }
        }
        print("Export completed: all \(ScenarioName.allCases.count) scenarios saved to \(path)")
    }

    /// Waits until the current scenario's root has a committed frame (the layout coordinator
    /// commits asynchronously on the MainActor) *and* every `TextNode` under it has a current
    /// display artifact (T12), plus a short grace period for the layer tree, instead of a
    /// fixed delay that a cold first launch — or a scene whose CoreText raster is still in
    /// flight (D53/T06) — can miss. Bounded at 400 × 10 ms = 4 s, comfortably above what T11
    /// measured for a 200-row list (~50 ms), and well under the 1 s tick of a dynamic
    /// scenario's session, so a capture still shows phase 0.
    ///
    /// The host suspends its coordinator while the window is not key, so if another app takes
    /// focus mid-export a scene would never commit and the capture would be blank; the loop
    /// re-activates the window while it waits and reports a scene that still never committed —
    /// separately from one that committed but is still mid-raster, so the two failure shapes
    /// are not confused in the export log.
    private func waitForFirstCommit() async {
        guard let root = instance?.root, let host else { return }
        let ready = await waitForRenderReady(root: root, host: host, maxTicks: 400) { [weak self] tick in
            guard tick % 50 == 49 else { return }
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if root.calculatedFrame == nil {
            print("WARNING: \(instance?.name.rawValue ?? "?") never committed; capture will be blank")
        } else if !ready {
            print(
                "WARNING: \(instance?.name.rawValue ?? "?") committed but text is still mid-raster; capture may show stale/empty text"
            )
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    @objc func overlayToggled(_ sender: NSButton) {
        host?.isDebugOverlayEnabled = sender.state == .on
    }

    private func capture(host: TrellisHostView) -> Data? {
        let size = host.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard let layer = host.layer else { return nil }
        let scale = host.hostScale > 0 ? host.hostScale : 2.0
        let pixelWidth = Int(Double(size.width) * scale)
        let pixelHeight = Int(Double(size.height) * scale)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: context)

        guard let cgImage = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    func applicationWillTerminate(_ notification: Notification) {
        instance?.teardown(); host?.detach()
    }

    func windowWillClose(_ notification: Notification) {
        instance?.teardown()
        host?.detach()
        instance = nil
        host = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "ScenarioSelector":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Scenario"
            let popup = NSPopUpButton(
                frame: NSRect(x: 0, y: 0, width: 220, height: 28),
                pullsDown: false
            )
            for s in ScenarioName.allCases {
                popup.addItem(withTitle: s.rawValue)
            }
            popup.target = self
            popup.action = #selector(scenarioSelected(_:))
            self.popup = popup
            item.view = popup
            return item

        case "Navigation":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Navigate"
            let seg = NSSegmentedControl(
                labels: ["◀ Prev", "Next ▶"],
                trackingMode: .momentary,
                target: self,
                action: #selector(segClicked(_:))
            )
            item.view = seg
            return item

        case "Overlay":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Debug Overlay"
            let btn = NSButton(
                checkboxWithTitle: "🐞 Overlay",
                target: self,
                action: #selector(overlayToggled(_:))
            )
            btn.state = host?.isDebugOverlayEnabled == true ? .on : .off
            item.view = btn
            return item

        case "Capture":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Capture All"
            let btn = NSButton(
                title: "📸 Export All",
                target: self,
                action: #selector(captureAllClicked)
            )
            item.view = btn
            return item

        default:
            return nil
        }
    }

    @objc func segClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            previousScenario()
        } else {
            nextScenario()
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            NSToolbarItem.Identifier("Navigation"),
            NSToolbarItem.Identifier("ScenarioSelector"),
            .flexibleSpace,
            NSToolbarItem.Identifier("Overlay"),
            NSToolbarItem.Identifier("Capture"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
