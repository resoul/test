import TrellisCore
import TrellisRender

/// The displayed state of the download card — a small `Equatable` model published through a
/// `StateSubject` (C29). Each field maps to a different update path in `update(_:)`:
/// `progress` → geometry (`style`), `accent` → paint only (`appearance`), `files` → structure
/// (`markArrangementDirty()`).
struct DownloadModel: Equatable, Sendable {
    var progress: Double
    var accent: ThemeColor
    var files: [String]
}

/// A card that shows a `DownloadModel`: title, a progress bar whose fill grows with
/// `progress`, and one row per file. `update(_:)` compares with what is shown and touches only
/// what changed — no base `Node` protocol, just a method on this one class.
final class DownloadCardNode: Node {
    let title = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 4)
    )
    let track = Node(appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 4))
    let fill = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 4))
    let percent = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 4))
    private var fileRows: [String: Node] = [:]
    private(set) var shown: DownloadModel?
    /// Delivered model count — visible in the arrange trace; the scene's session sends far
    /// more than this because equal state and bursts collapse before they reach here.
    private(set) var updates = 0

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 18))
        style.width = .points(360)
        style.alignSelf = .center
    }

    func update(_ model: DownloadModel) {
        updates += 1
        guard model != shown else { return }
        let previous = shown
        shown = model

        if previous?.progress != model.progress {
            // Geometry: the fill is a fraction of the track — expressed through `flexGrow`
            // against the remainder, so no measured width is needed (D03).
            fill.style.flexGrow = max(0.001, model.progress)
            track.style.flexGrow = max(0.001, 1 - model.progress)
        }
        if previous?.accent != model.accent {
            // Paint only: the host repaints committed layers without a layout pass.
            fill.appearance.background = .color(model.accent)
            percent.appearance.background = .color(model.accent)
        }
        if previous?.files != model.files {
            // Structure: rows are keyed by file name so an existing row keeps its node (and
            // its CALayer) across reorders and insertions; the arrangement is re-resolved
            // by the host before its next snapshot.
            for name in model.files where fileRows[name] == nil {
                fileRows[name] = Node(
                    appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 8)
                )
            }
            markArrangementDirty()
        }
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 14,
            padding: DirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        ) {
            Row(spacing: 12, align: .center) {
                Leaf(title).size(height: 14).grow(1)
                Leaf(percent).size(width: 44, height: 14)
            }
            Row(spacing: 0) {
                Leaf(fill).size(height: 8)
                Leaf(track).size(height: 8)
            }
            Column(spacing: 8) {
                for name in shown?.files ?? [] {
                    if let row = fileRows[name] {
                        Leaf(row).size(height: 32)
                    }
                }
            }
        }
    }
}

@MainActor enum S20 {
    static let initial = DownloadModel(
        progress: 0.3,
        accent: Palette.blue,
        files: ["design.sketch", "build.log"]
    )

    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style.justifyContent = .center
        root.style.alignItems = .center
        let card = DownloadCardNode()
        root.addSubnode(card)

        let subject = StateSubject(initial)
        let session = ScenarioSession()
        var phase = 0
        session.start {
            phase = (phase + 1) % 5
            switch phase {
            case 0:
                // Back to the initial state — the screenshot phase.
                subject.send(initial)
            case 1:
                // Equal state: the subject drops it, nothing downstream runs.
                subject.send(subject.current)
            case 2:
                // Burst of 30 distinct models in one turn: one update, one layout, last value.
                for step in 1...30 {
                    var model = subject.current
                    model.progress = 0.3 + 0.02 * Double(step)
                    subject.send(model)
                }
            case 3:
                // Paint only: accent changes, no layout pass.
                var model = subject.current
                model.accent = Palette.green
                subject.send(model)
            case 4:
                // Structure: a file appears in the middle; existing rows keep their nodes.
                var model = subject.current
                model.files = ["design.sketch", "assets.zip", "build.log"]
                subject.send(model)
            default:
                break
            }
        }

        return ScenarioNodes.instance(
            .s20,
            root: root,
            inputs:
                "StateSubject<DownloadModel> bound to DownloadCardNode.update; phases: same, burst×30, paint-only, structure",
            expected:
                "equal state does nothing; burst yields one update and one layout; accent repaints without Flex; rows keep identity; detach stops delivery, reattach shows latest",
            paths: ["root", "root/card", "root/card/progress", "root/card/files"],
            session: session,
            onAttach: { host, bindings in
                bindings.add(host.bindState(subject) { [weak card] model in card?.update(model) })
            }
        )
    }
}
