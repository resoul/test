#if canImport(AppKit)
    import AppKit
    import Testing

    @testable import TrellisAppKit
    @testable import TrellisCore

    // A08: real `NSEvent` key events through `TrellisHostView` — Tab/Shift-Tab/arrows move the
    // engine's focus, Return/Space activate the focused control once, and anything the engine
    // does not consume continues up the responder chain (no keyboard trap).

    @MainActor
    private func waitForAppKitCommit(_ hostLayer: CALayer) async {
        for _ in 0..<10_000 where hostLayer.sublayers?.isEmpty != false { await Task.yield() }
    }

    private func keyEvent(
        _ type: NSEvent.EventType,
        code: UInt16,
        shift: Bool = false,
        repeat isRepeat: Bool = false
    )
        -> NSEvent?
    {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: shift ? [.shift] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: isRepeat,
            keyCode: code
        )
    }

    /// Records what the responder chain above the host receives.
    @MainActor
    private final class Recorder: NSView {
        var downs: [UInt16] = []
        var ups: [UInt16] = []

        override func keyDown(with event: NSEvent) { downs.append(event.keyCode) }
        override func keyUp(with event: NSEvent) { ups.append(event.keyCode) }
    }

    /// Root 400×400 with three 80×80 controls in a row.
    @MainActor
    private func makeHost() -> (Recorder, TrellisHostView, [ControlNode]) {
        let recorder = Recorder(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let host = TrellisHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        recorder.addSubview(host)
        let root = Node()
        root.style {
            $0.flexDirection = .row; $0.gap = 20
        }
        let cards = (0..<3).map { _ in ControlNode() }
        for card in cards {
            card.style {
                $0.width = 80; $0.height = 80
            }
            root.addSubnode(card)
        }
        host.attach(root: root)
        return (recorder, host, cards)
    }

    @Test @MainActor
    func a08_appKitTabShiftTabArrowsAndReturnDriveTheEngine() async throws {
        let (recorder, host, cards) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))
        var activations: [ActivationSource] = []
        cards[1].activation = { [weak card = cards[1]] in
            if let source = card?.lastActivationSource { activations.append(source) }
        }
        #expect(host.acceptsFirstResponder)

        host.keyDown(with: try #require(keyEvent(.keyDown, code: 48)))  // Tab
        #expect(host.focusedID == cards[0].id)
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 124)))  // →
        #expect(host.focusedID == cards[1].id)
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 36)))  // Return down
        #expect(cards[1].isPressed)
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 36, repeat: true)))
        host.keyUp(with: try #require(keyEvent(.keyUp, code: 36)))
        #expect(activations == [.keyboard])
        #expect(!cards[1].isPressed)
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 49)))  // Space
        host.keyUp(with: try #require(keyEvent(.keyUp, code: 49)))
        #expect(activations == [.keyboard, .keyboard])
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 48, shift: true)))  // Shift-Tab
        #expect(host.focusedID == cards[0].id)
        #expect(recorder.downs.isEmpty)  // everything above was consumed
        #expect(recorder.ups.isEmpty)
    }

    @Test @MainActor
    func a08_appKitPassesUnconsumedKeysUpTheResponderChain() async throws {
        let (recorder, host, cards) = makeHost()
        await waitForAppKitCommit(try #require(host.layer))

        host.keyDown(with: try #require(keyEvent(.keyDown, code: 0)))  // "a": unmapped
        #expect(recorder.downs == [0])
        // Shift-Tab with no focus picks the last candidate.
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 48, shift: true)))
        #expect(host.focusedID == cards[2].id)
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 48)))  // Tab at the boundary
        #expect(host.focusedID == cards[2].id)
        #expect(recorder.downs == [0, 48])  // forwarded: AppKit's own key-view loop takes over
        host.keyUp(with: try #require(keyEvent(.keyUp, code: 48)))
        #expect(recorder.ups == [48])  // navigation key-ups are never consumed
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 124)))  // → at the boundary
        #expect(recorder.downs == [0, 48, 124])
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 36)))  // Return: consumed
        host.keyUp(with: try #require(keyEvent(.keyUp, code: 36)))
        #expect(recorder.downs == [0, 48, 124])
        #expect(recorder.ups == [48])

        host.detach()
        host.keyDown(with: try #require(keyEvent(.keyDown, code: 48)))
        #expect(recorder.downs == [0, 48, 124, 48])  // nothing attached: everything passes
    }

    @Test @MainActor
    func a08_appKitKeyMapping() throws {
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 48)))
                == KeyData(key: .tab)
        )
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 48, shift: true)))
                == KeyData(key: .tab, isShiftDown: true)
        )
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 126)))?.key
                == .upArrow
        )
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 125)))?.key
                == .downArrow
        )
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 123)))?.key
                == .leftArrow
        )
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 76)))?.key
                == .returnKey
        )
        #expect(
            TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 36, repeat: true)))?
                .isRepeat == true
        )
        // Escape is not mapped.
        #expect(TrellisHostView.keyData(for: try #require(keyEvent(.keyDown, code: 53))) == nil)
    }
#endif
