import LayoutCore
import StateCore
import Testing

@testable import Nodes

extension Command {
    fileprivate static let archive = Command("archive", title: "Archive")
}

/// A control that remembers every state it showed.
@MainActor
private final class Chip: Control {
    var shown: [ControlState] = []

    override var layoutContent: LeafContent? { .size(LayoutSize(width: 100, height: 40)) }

    override func stateChanged(from previous: ControlState) {
        shown.append(state)
    }
}

/// A row with a tap of its own, a chip in it, and a second chip beside.
@MainActor
private final class Row: Node {
    let chip = Chip()
    let other = Chip()

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.row) {
            chip
            other
        }
        .padding(10)
    }
}

@MainActor
private func host(_ row: Row) -> NodeHost {
    let host = NodeHost(root: row, size: LayoutSize(width: 400, height: 60))
    host.layoutIfNeeded()
    return host
}

/// Points in the root: the chip at x 10–110, the other at 110–210, both at y 10–50.
private let onChip = LayoutPoint(x: 50, y: 30)
private let onOther = LayoutPoint(x: 150, y: 30)
private let onRow = LayoutPoint(x: 300, y: 30)

@Test @MainActor
func aControlShowsPressHoverAndFocusTogether() {
    let row = Row()
    var taps = 0
    row.chip.onTap = { taps += 1 }
    let host = host(row)
    #expect(row.chip.shown == [[]])

    host.pointerMoved(to: onChip)
    #expect(row.chip.state == .hovered)
    host.pointerDown(at: onChip)
    #expect(row.chip.state == [.hovered, .pressed])
    host.pointerUp(at: onChip)
    #expect(taps == 1)
    #expect(row.chip.state == .hovered)
    host.focus(row.chip.id)
    #expect(row.chip.state == [.hovered, .focused])
    host.pointerMoved(to: nil)
    #expect(row.chip.state == .focused)
    row.chip.isSelected = true
    #expect(row.chip.state == [.focused, .selected])
    // One call for each change, none for a change to the same state.
    row.chip.isSelected = true
    #expect(row.chip.shown.count == 7)
}

@Test @MainActor
func thePointerMovingOverTheTreeHoversTheNodeAPressWouldGoTo() {
    let row = Row()
    row.onTap = {}
    row.chip.onTap = {}
    let host = host(row)

    host.pointerMoved(to: onChip)
    #expect(row.chip.state.contains(.hovered))
    // The other chip has no tap: a press there goes to the row.
    host.pointerMoved(to: onOther)
    #expect(!row.chip.state.contains(.hovered))
    #expect(!row.other.state.contains(.hovered))
    #expect(row.isHovered)
    host.detach()
    #expect(!row.isHovered)
}

@Test @MainActor
func aControlTurnedOffTakesNoPressFocusOrPointerAndSaysSo() throws {
    let row = Row()
    var rowTaps = 0
    var chipTaps = 0
    row.onTap = { rowTaps += 1 }
    row.chip.onTap = { chipTaps += 1 }
    row.chip.isEnabled = false
    let host = host(row)
    #expect(row.chip.state == .disabled)

    // The press stops at the chip: the row behind it is not tapped either.
    #expect(host.pointerDown(at: onChip))
    host.pointerUp(at: onChip)
    #expect(chipTaps == 0)
    #expect(rowTaps == 0)
    #expect(row.chip.state == .disabled)
    host.pointerMoved(to: onChip)
    #expect(row.chip.state == .disabled)
    #expect(!row.isHovered)

    host.focus(row.chip.id)
    #expect(host.focusedNode == nil)
    #expect(!host.focusItems().contains { $0.node == row.chip.id })
    #expect(!host.activate(row.chip.id))
    // A row with a tap would speak for the chip inside it.
    row.onTap = nil
    let element = try #require(host.accessibilityItems().first { $0.node == row.chip.id })
    #expect(element.traits.contains(.notEnabled))
    #expect(element.traits.contains(.button))

    row.chip.isEnabled = true
    host.pointerDown(at: onChip)
    host.pointerUp(at: onChip)
    #expect(chipTaps == 1)
}

@Test @MainActor
func turningAControlOffTakesItsFocusAndPressAway() {
    let row = Row()
    var taps = 0
    row.chip.onTap = { taps += 1 }
    row.other.onTap = {}
    let host = host(row)
    host.focus(row.chip.id)

    row.chip.isEnabled = false
    #expect(host.focusedNode == nil)
    #expect(row.chip.state == .disabled)

    row.chip.isEnabled = true
    host.pointerDown(at: onChip)
    row.chip.isEnabled = false
    host.pointerUp(at: onChip)
    #expect(taps == 0)
    #expect(row.chip.state == .disabled)

    // The select button of a remote, or a key, over a focused control turned off in between.
    row.chip.isEnabled = true
    host.focus(row.chip.id)
    #expect(host.selectBegan())
    row.chip.isEnabled = false
    host.selectEnded()
    #expect(taps == 0)
}

@Test @MainActor
func aControlsCommandGoesWhereTheControlIsAndTurnsItOnAndOff() {
    let row = Row()
    let canArchive = State(false)
    var archived: [String] = []
    row.handle(.archive, isEnabled: { canArchive.value }) { archived.append("row") }
    row.other.handle(.archive) { archived.append("other") }
    row.chip.command = .archive
    let host = host(row)
    #expect(row.chip.state == .disabled)

    canArchive.value = true
    StateUpdates.flush()
    #expect(row.chip.state == [])
    // With the other chip focused, the press still starts at the chip, and the row carries
    // the command out, not the focused chip.
    host.focus(row.other.id)
    host.pointerDown(at: onChip)
    host.pointerUp(at: onChip)
    #expect(archived == ["row"])

    canArchive.value = false
    StateUpdates.flush()
    #expect(row.chip.state == .disabled)

    // A command removed takes the tap it gave away with it.
    row.chip.command = nil
    #expect(row.chip.onTap == nil)
    #expect(row.chip.state == [])
}

@Test @MainActor
func aControlsCommandTurnsOnWhenAHandlerIsAddedLaterAndOffWhenItIsTakenAway() {
    let row = Row()
    let outer = CommandResponder()
    row.chip.command = .archive
    let host = NodeHost(root: row, size: LayoutSize(width: 400, height: 60))
    host.outerResponder = outer
    host.layoutIfNeeded()
    // Nothing carries the command out yet: an app registers its handlers once its window is up.
    #expect(row.chip.state == .disabled)

    outer.handle(.archive) {}
    StateUpdates.flush()
    #expect(row.chip.state == [])

    outer.removeHandler(for: .archive)
    StateUpdates.flush()
    #expect(row.chip.state == .disabled)

    // A node's own handler, added after the control mounted, counts as well.
    row.handle(.archive) {}
    StateUpdates.flush()
    #expect(row.chip.state == [])
    host.detach()
}

@Test @MainActor
func theInnermostTipShowsAndAControlTakesItsCommandsTitle() throws {
    let row = Row()
    row.toolTip = "A row"
    row.chip.command = .archive
    let host = host(row)

    #expect(host.toolTip(at: onChip)?.text == "Archive")
    #expect(host.toolTip(at: onOther)?.text == "A row")
    let tip = try #require(host.toolTip(at: onRow))
    #expect(tip.node == row.id)
    #expect(tip.frame == LayoutRect(x: 0, y: 0, width: 400, height: 60))

    row.chip.toolTip = "Archive the message"
    #expect(host.toolTip(at: onChip)?.text == "Archive the message")
    #expect(host.toolTipItems().map(\.text) == ["A row", "Archive the message"])
    row.chip.appearance.opacity = 0
    host.layoutIfNeeded()
    #expect(host.toolTipItems().map(\.text) == ["A row"])
}
