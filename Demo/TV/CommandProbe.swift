import LayoutCore
import Nodes
import NodesRender
import ThemeCore

/// A screen for the remote's buttons as commands, for UI tests: a row to focus and press,
/// under a line that counts what the buttons did. Menu goes back twice, and then leaves the
/// app; select held down is a long press. `COMMAND_PROBE` in the launch environment shows it.
@MainActor
final class CommandProbe: Node {
    let status = Text("", style: TextStyle(size: 15))
    private var depth = 2
    private var counts = (backs: 0, plays: 0, holds: 0, taps: 0)
    private lazy var row = Button("Row") { [weak self] in
        self?.counts.taps += 1
        self?.show()
    }

    override init() {
        super.init()
        handle(.back, isEnabled: { [weak self] in (self?.depth ?? 0) > 0 }) { [weak self] in
            guard let self else { return }

            depth -= 1
            counts.backs += 1
            show()
        }
        handle(.playPause) { [weak self] in
            self?.counts.plays += 1
            self?.show()
        }
        handle(.longPress) { [weak self] in
            self?.counts.holds += 1
            self?.show()
        }
        show()
    }

    private func show() {
        status.text =
            "Back \(counts.backs) Play \(counts.plays) Hold \(counts.holds) Tap \(counts.taps)"
    }

    override func layoutSpec() -> LayoutSpec? {
        FlexContainer(.column) {
            status
            row
        }
        .gap(16)
        .alignItems(.start)
    }
}
