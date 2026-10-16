// Engine-neutral description of the benchmark trees: each engine builds its own input from
// the same `Box`, so both lay out exactly the same thing.

/// A node of a benchmark tree: a flex container, a fixed-size leaf, or a text leaf.
struct Box: Sendable {
    enum Direction: Sendable {
        case row
        case column
    }

    /// Words of the given widths on lines of `lineHeight`, wrapped greedily.
    struct Text: Sendable {
        var lineHeight: Double
        var words: [Double]
    }

    var direction = Direction.row
    var wraps = false
    /// Gap along the main axis.
    var gap = 0.0
    var width: Double?
    var height: Double?
    var padding = 0.0
    var grow = 0.0
    var shrink = 1.0
    var centersItems = false
    var text: Text?
    var children: [Box] = []

    var count: Int { children.reduce(1) { $0 + $1.count } }
}

/// The widest line and the number of lines of `words` wrapped greedily at `width`.
func wrap(_ words: [Double], width: Double) -> (width: Double, lines: Int) {
    guard !words.isEmpty else { return (0, 0) }

    var lines = 1
    var used = 0.0
    var widest = 0.0
    for word in words {
        if used > 0 && used + word > width + 1e-9 {
            widest = max(widest, used)
            lines += 1
            used = word
        } else {
            used += word
        }
    }
    return (max(widest, used), lines)
}

/// Deterministic pseudo-random numbers, so that every run lays out the same trees.
struct Random {
    var state: UInt64

    mutating func next(_ upper: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(upper))
    }
}

// MARK: - Trees

/// `count` small boxes in a wrapping row.
func wideTree(count: Int, wraps: Bool = true, seed: UInt64 = 7) -> Box {
    var random = Random(state: seed)
    var root = Box(direction: .row, wraps: wraps, gap: 2)
    for _ in 0..<count {
        root.children.append(
            Box(width: Double(8 + random.next(24)), height: Double(8 + random.next(16)))
        )
    }
    return root
}

/// `depth` nested columns with 1pt padding, each holding `siblings` fixed leaves beside the
/// next level. Every level adds 14pt of natural height with four siblings.
func deepTree(depth: Int, siblings: Int = 4, levelsGrow: Bool = false) -> Box {
    var level = Box(direction: .column, padding: 1)
    level.children.append(Box(width: 6, height: 3))
    for _ in 0..<depth {
        var parent = Box(direction: .column, padding: 1)
        for _ in 0..<siblings {
            parent.children.append(Box(width: 6, height: 3))
        }
        if levelsGrow {
            level.grow = 1
        }
        parent.children.append(level)
        level = parent
    }
    return level
}

/// A column of `count` paragraphs of random words.
func textList(count: Int, seed: UInt64 = 11) -> Box {
    var random = Random(state: seed)
    var root = Box(direction: .column, gap: 4, padding: 16)
    for _ in 0..<count {
        let words = (0..<(3 + random.next(18))).map { _ in Double(20 + random.next(60)) }
        root.children.append(Box(text: Box.Text(lineHeight: 20, words: words)))
    }
    return root
}

/// A column of `count` cards: avatar, a column of title and subtitle that takes the rest of
/// the row, and a button.
func cardList(count: Int, seed: UInt64 = 13) -> Box {
    var random = Random(state: seed)
    var root = Box(direction: .column, gap: 8, padding: 16)
    for _ in 0..<count {
        let title = (0..<(2 + random.next(6))).map { _ in Double(30 + random.next(50)) }
        let subtitle = (0..<(3 + random.next(12))).map { _ in Double(20 + random.next(40)) }
        let texts = Box(
            direction: .column,
            gap: 4,
            grow: 1,
            children: [
                Box(text: Box.Text(lineHeight: 22, words: title)),
                Box(text: Box.Text(lineHeight: 16, words: subtitle)),
            ]
        )
        root.children.append(
            Box(
                direction: .row,
                gap: 12,
                padding: 12,
                centersItems: true,
                children: [Box(width: 48, height: 48), texts, Box(width: 72, height: 32)]
            )
        )
    }
    return root
}
