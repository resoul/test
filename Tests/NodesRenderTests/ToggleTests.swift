#if canImport(CoreText)
    import LayoutCore
    import Nodes
    import Testing

    @testable import NodesRender

    /// A switch and a check box side by side: the switch at x 10–61, the box at x 71–93, both
    /// at y 10.
    @MainActor
    private final class Row: Node {
        let toggle: Switch
        let box: Checkbox

        init(isOn: Bool = false, state: CheckState = .off) {
            toggle = Switch(isOn: isOn, label: "Notifications")
            box = Checkbox(state, label: "Select all")
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                toggle
                box
            }
            .gap(10)
            .padding(10)
            .alignItems(.start)
        }
    }

    private let onSwitch = LayoutPoint(x: 35, y: 25)
    private let onBox = LayoutPoint(x: 82, y: 21)

    @MainActor
    private func host(_ row: Row) -> NodeHost {
        let host = NodeHost(root: row, size: LayoutSize(width: 200, height: 60))
        host.layoutIfNeeded()
        return host
    }

    @MainActor
    private func tap(_ host: NodeHost, at point: LayoutPoint) {
        host.pointerDown(at: point)
        host.pointerUp(at: point)
        host.layoutIfNeeded()
    }

    /// What assistive tools see of the node with `label`.
    @MainActor
    private func item(_ host: NodeHost, _ label: String) throws -> AccessibilityItem {
        for entry in host.accessibilityEntries() {
            if case .element(let item) = entry, item.label == label { return item }
        }
        throw NotFound()
    }

    private struct NotFound: Error {}

    @Test @MainActor
    func aSwitchTurnsOverOnATapAndTellsTheUsersChangeOnly() {
        let row = Row()
        var changes: [Bool] = []
        row.toggle.onChange = { changes.append($0) }
        let host = host(row)

        #expect(!row.toggle.isOn)
        tap(host, at: onSwitch)
        #expect(row.toggle.isOn)
        tap(host, at: onSwitch)
        #expect(!row.toggle.isOn)
        #expect(changes == [true, false])

        // From code: the value changes, nobody is told.
        row.toggle.isOn = true
        #expect(row.toggle.isOn)
        #expect(changes == [true, false])
    }

    @Test @MainActor
    func theKnobSlidesToTheEndAndTheTrackTakesTheAccentColorWhenOn() {
        let row = Row()
        let host = host(row)
        let track = row.toggle.appearance.background
        #expect(row.toggle.knob.appearance.offset == LayoutPoint(x: 0, y: 0))

        row.toggle.isOn = true
        host.layoutIfNeeded()
        #expect(row.toggle.knob.appearance.offset == LayoutPoint(x: 20, y: 0))
        #expect(row.toggle.appearance.background != track)
        #expect(row.toggle.appearance.background == row.toggle.theme.color(.accent))
    }

    @Test @MainActor
    func aSwitchIsAToggleWithOnAndOffForAssistiveTools() throws {
        let row = Row()
        let host = host(row)

        var switchItem = try item(host, "Notifications")
        #expect(switchItem.traits.contains(.toggle))
        #expect(switchItem.value == "0")
        row.toggle.isOn = true
        host.layoutIfNeeded()
        switchItem = try item(host, "Notifications")
        #expect(switchItem.value == "1")
        // 51 by 31 points, where it is placed.
        #expect(switchItem.frame == LayoutRect(x: 10, y: 10, width: 51, height: 31))
    }

    @Test @MainActor
    func aDisabledSwitchDoesNotTurnOver() {
        let row = Row()
        row.toggle.isEnabled = false
        var changes = 0
        row.toggle.onChange = { _ in changes += 1 }
        let host = host(row)

        tap(host, at: onSwitch)
        #expect(!row.toggle.isOn)
        #expect(changes == 0)
        #expect(!host.activate(row.toggle.id))
    }

    @Test @MainActor
    func theKeyboardAndTheRemoteActivateAFocusedSwitch() {
        let row = Row()
        let host = host(row)

        host.focus(row.toggle.id)
        #expect(host.activate(row.toggle.id))
        #expect(row.toggle.isOn)
    }

    @Test @MainActor
    func aCheckboxCyclesOffOnOffAndMixedBecomesOn() {
        let row = Row()
        var changes: [CheckState] = []
        row.box.onChange = { changes.append($0) }
        let host = host(row)

        tap(host, at: onBox)
        #expect(row.box.value == .on)
        tap(host, at: onBox)
        #expect(row.box.value == .off)
        row.box.value = .mixed
        #expect(changes == [.on, .off])
        tap(host, at: onBox)
        #expect(row.box.value == .on)
        #expect(changes == [.on, .off, .on])
    }

    @Test @MainActor
    func aCheckboxShowsItsValueInItsMarkAndReportsItToAssistiveTools() throws {
        let row = Row()
        let host = host(row)
        #expect(row.box.mark.text == "")
        #expect(try item(host, "Select all").value == "0")

        row.box.value = .on
        host.layoutIfNeeded()
        #expect(row.box.mark.text == "✓")
        #expect(row.box.appearance.background == row.box.theme.color(.accent))
        #expect(try item(host, "Select all").value == "1")

        row.box.value = .mixed
        host.layoutIfNeeded()
        #expect(row.box.mark.text == "–")
        #expect(try item(host, "Select all").value == "2")
        #expect(try item(host, "Select all").traits.contains(.toggle))
        // The mark is not an element of its own.
        #expect(host.accessibilityEntries().count == 2)
    }

    @Test @MainActor
    func aCheckboxIs22PointsSquare() throws {
        let row = Row()
        let host = host(row)

        #expect(
            try item(host, "Select all").frame == LayoutRect(x: 71, y: 10, width: 22, height: 22)
        )
    }
#endif
