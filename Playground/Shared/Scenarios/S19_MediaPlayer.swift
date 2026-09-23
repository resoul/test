import TrellisCore

/// A reusable, self-arranging tile: the first scenario where an `Arrangement` owner is itself
/// a `Leaf` inside another owner's `Arrangement` (component composition). The parent decides
/// the tile's placement (`.grow(1)`), the tile decides its own inner layout.
final class TrackTileNode: Node {
    let thumb: Node
    let durationBadge = Node(
        appearance: VisualStyle(background: .color(Palette.canvas), cornerRadius: 4)
    )
    let title = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 3))
    let subtitle = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )

    init(accent: ThemeColor) {
        thumb = Node(appearance: VisualStyle(background: .color(accent), cornerRadius: 8))
        super.init(appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 12))
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 8,
            padding: DirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        ) {
            Overlay {
                Leaf(thumb).size(width: 76, height: 64)
                Leaf(durationBadge)
                    .size(width: 26, height: 12)
                    .offset(DirectionalEdgeOffsets(bottom: 4, trailing: 4))
            }
            .size(width: 76, height: 64)
            Leaf(title).size(height: 10)
            Leaf(subtitle).size(width: 44, height: 8)
        }
    }
}

/// "Now playing" card: header, artwork with overlaid pills, a row of three self-arranging
/// tiles, a nested-grow progress bar and evenly spaced transport controls. Exercises root
/// modifiers on `self`, `.align()` per item, `justify: .spaceEvenly`, grow inside grow, and
/// two levels of `Arrangement` ownership.
final class MediaPlayerNode: Node {
    // Header
    let backButton = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 14)
    )
    let headerTitle = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let menuButton = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 14)
    )

    // Artwork with overlays
    let artwork = Node(
        appearance: VisualStyle(background: .color(Palette.purple), cornerRadius: 16)
    )
    let livePill = Node(appearance: VisualStyle(background: .color(Palette.pink), cornerRadius: 8))
    let playBadge = Node(
        appearance: VisualStyle(background: .color(Palette.green), cornerRadius: 24)
    )

    // Track tiles — each one is an `Arrangement` owner of its own
    let tile1 = TrackTileNode(accent: Palette.blue)
    let tile2 = TrackTileNode(accent: Palette.orange)
    let tile3 = TrackTileNode(accent: Palette.cyan)

    // Progress
    let elapsed = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )
    let progressFill = Node(
        appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 2)
    )
    let progressRest = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 2)
    )
    let remaining = Node(
        appearance: VisualStyle(background: .color(Palette.textSecondary), cornerRadius: 3)
    )

    // Transport
    let shuffle = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 11)
    )
    let previous = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 15)
    )
    let play = Node(appearance: VisualStyle(background: .color(Palette.blue), cornerRadius: 28))
    let next = Node(
        appearance: VisualStyle(background: .color(Palette.cardLight), cornerRadius: 15)
    )
    let repeatButton = Node(
        appearance: VisualStyle(background: .color(Palette.border), cornerRadius: 11)
    )

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 22))
        style.width = .points(360)
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(
            spacing: 18,
            padding: DirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        ) {
            // Header: back / title / menu
            Row(spacing: 12, align: .center) {
                Leaf(backButton).size(width: 28, height: 28)
                Leaf(headerTitle).size(height: 12).grow(1)
                Leaf(menuButton).size(width: 28, height: 28)
            }

            // Artwork centred in the column, with a LIVE pill and a play badge overlaid
            Overlay {
                Leaf(artwork).size(width: 200, height: 200)
                Leaf(livePill)
                    .size(width: 44, height: 16)
                    .offset(DirectionalEdgeOffsets(top: 10, leading: 10))
                Leaf(playBadge)
                    .size(width: 48, height: 48)
                    .offset(DirectionalEdgeOffsets(bottom: 12, trailing: 12))
            }
            .size(width: 200, height: 200)
            .align(.center)

            // Three self-arranging tiles sharing the width equally
            Row(spacing: 10) {
                Leaf(tile1).grow(1)
                Leaf(tile2).grow(1)
                Leaf(tile3).grow(1)
            }

            // Progress: a growing row nested inside a growing slot
            Row(spacing: 10, align: .center) {
                Leaf(elapsed).size(width: 28, height: 8)
                Row {
                    Leaf(progressFill).grow(3)
                    Leaf(progressRest).grow(7)
                }
                .size(height: 4)
                .grow(1)
                Leaf(remaining).size(width: 28, height: 8)
            }

            // Transport controls, evenly spaced; shuffle/repeat pinned to the bottom edge
            Row(justify: .spaceEvenly, align: .center) {
                Leaf(shuffle).size(width: 22, height: 22).align(.end)
                Leaf(previous).size(width: 30, height: 30)
                Leaf(play).size(width: 56, height: 56)
                Leaf(next).size(width: 30, height: 30)
                Leaf(repeatButton).size(width: 22, height: 22).align(.end)
            }
        }
        .align(.center)
    }
}

@MainActor enum S19 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style.justifyContent = .center
        root.style.alignItems = .center
        let player = MediaPlayerNode()
        root.addSubnode(player)
        // No manual resolve: the host resolves the player and then the tiles it placed, in
        // that order, before the first snapshot (C32/D13).

        return ScenarioNodes.instance(
            .s19,
            root: root,
            inputs:
                "Media player card: root .align modifier, nested Arrangement owners (tiles), Overlay pills, grow-in-grow progress, spaceEvenly transport",
            expected:
                "tiles keep parent .grow(1) and their own Column layout; artwork and card centred; controls evenly spaced",
            paths: [
                "root",
                "root/player",
                "root/player/header",
                "root/player/artworkOverlay",
                "root/player/tiles",
                "root/player/tiles/tile1",
                "root/player/progress",
                "root/player/transport",
            ]
        )
    }
}
