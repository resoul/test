import TrellisCore
import TrellisFlux
import TrellisRender

/// R05's external consumer: a real screen, driven end to end by the Flux integration built in
/// R02–R04 — not just operators exercised in unit tests. Three filter buttons drive
/// `FeedModel.select(_:)`, which runs a simulated, deliberately delayed "network" load through
/// `EffectOwner` (R04) and publishes the outcome through a Flux `CurrentValue` that
/// `NodeHostBridge.bindFlux` (R03) delivers to `FeedScreenNode.update(_:)`. Selecting "Even" the
/// first time fails once on purpose — tapping Retry recovers, proving R04's "ошибка не
/// завершает навсегда UI-подписку" on a real screen, not a fake-API test. Every state change
/// this scene shows (list appearing, error appearing, items re-filtering) goes through the
/// `animation` intent `bindFlux` computes, so the transition itself is native evidence, the
/// same convention S20/S27 already established for plain `StateSubject` scenes. No text-input
/// control is used — buttons are the only input, since N01's text field is out of scope.
enum FeedFilter: String, Sendable, CaseIterable {
    case all = "All"
    case even = "Even"
    case odd = "Odd"

    fileprivate func apply(to items: [Int]) -> [Int] {
        switch self {
        case .all: items
        case .even: items.filter { $0.isMultiple(of: 2) }
        case .odd: items.filter { !$0.isMultiple(of: 2) }
        }
    }
}

enum FeedState: Sendable, Equatable {
    case loading(FeedFilter)
    case loaded(filter: FeedFilter, items: [Int])
    case failed(filter: FeedFilter, message: String)

    var filter: FeedFilter {
        switch self {
        case .loading(let filter): filter
        case .loaded(let filter, _): filter
        case .failed(let filter, _): filter
        }
    }
}

/// Owns the simulated network load: one `EffectOwner` key ("load") so selecting a new filter
/// while a load is in flight cancels it (`.restart`) rather than racing two responses — R04's
/// own "запрос A завершается после B" guarantee applied to a real model instead of a fake one.
private let feedAllItems = Array(1...16)

@MainActor
final class FeedModel {
    private let stateSubject = CurrentValue<FeedState>(.loading(.all))
    private let effects = EffectOwner<String>()
    private var pendingFailure: FeedFilter?

    var stateFlux: Flux<FeedState> { stateSubject.flux }

    init() {
        // "Even" fails exactly once, the first time it is selected — a reproducible retry
        // demonstration rather than a random flake an evidence run could miss.
        pendingFailure = .even
        load(filter: .all)
    }

    func select(_ filter: FeedFilter) {
        load(filter: filter)
    }

    func retry(filter: FeedFilter) {
        load(filter: filter)
    }

    private func load(filter: FeedFilter) {
        let shouldFail = pendingFailure == filter
        if shouldFail { pendingFailure = nil }
        let stateSubject = stateSubject
        Task { await stateSubject.set(.loading(filter)) }
        effects.run(
            "load",
            onConflict: .restart,
            operation: { () async -> FeedState in
                // Simulated network latency — real `Task.sleep`, not a deterministic test
                // double: this is the interactive consumer, not `EffectOwnerTests.swift`.
                try? await Task.sleep(for: .milliseconds(700))
                if shouldFail {
                    return .failed(
                        filter: filter,
                        message: "Couldn't load \(filter.rawValue.lowercased()) numbers"
                    )
                }
                return .loaded(filter: filter, items: filter.apply(to: feedAllItems))
            },
            apply: { [stateSubject] result in
                Task { await stateSubject.set(result) }
            }
        )
    }
}

/// One filter button — highlighted while its filter is the one currently shown or loading.
private final class FilterButtonNode: ControlNode {
    let filter: FeedFilter
    private let label: TextNode
    private(set) var isSelected = false

    init(filter: FeedFilter) {
        self.filter = filter
        label = TextNode(
            text: filter.rawValue,
            textStyle: TextStyle(pointSize: 13, weight: .medium, color: Palette.textSecondary)
        )
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 10))
        addSubnode(label)
        // Explicit width with margin, not auto/content-sizing (defect #48: an auto-width
        // label whose natural width lands right at a pixel-rounding knife-edge between
        // measure() and rasterize() can drop its last glyph behind an ellipsis even with a
        // generous container — reproduced here by "Odd" specifically, at this weight/size,
        // regardless of how wide this button's own box is given).
        label.style.width = .points(48)
        style { $0.padding = DirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16) }
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        appearance.background = .color(selected ? Palette.blue : Palette.card)
        label.textStyle.color =
            selected ? ThemeColor(red: 1, green: 1, blue: 1) : Palette.textSecondary
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(align: .center) { Leaf(label) }
    }
}

private final class RetryButtonNode: ControlNode {
    private let label = TextNode(
        text: "Retry",
        textStyle: TextStyle(
            pointSize: 13,
            weight: .bold,
            color: ThemeColor(red: 1, green: 1, blue: 1)
        )
    )

    init() {
        super.init(appearance: VisualStyle(background: .color(Palette.pink), cornerRadius: 8))
        addSubnode(label)
        style { $0.padding = DirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14) }
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row(align: .center) { Leaf(label) }
    }
}

private final class ItemRowNode: Node {
    let label: TextNode

    init(item: Int) {
        label = TextNode(
            text: "Item \(item)",
            textStyle: TextStyle(pointSize: 13, color: Palette.textSecondary)
        )
        super.init(appearance: VisualStyle(background: .color(Palette.card), cornerRadius: 8))
        addSubnode(label)
        style { $0.padding = DirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12) }
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Row { Leaf(label) }
    }
}

final class FeedScreenNode: Node {
    private let model: FeedModel
    private let buttons: [FeedFilter: FilterButtonNode]
    private let statusText = TextNode(
        text: " ",
        textStyle: TextStyle(pointSize: 14, color: Palette.textSecondary)
    )
    private let retryButton = RetryButtonNode()
    private var itemRows: [Int: ItemRowNode] = [:]
    private(set) var shown: FeedState?
    /// Delivered-state count — the arrange trace's evidence that a burst/duplicate never
    /// reaches here more than once per genuinely distinct state (same convention as S20's
    /// `DownloadCardNode.updates`).
    private(set) var updateCalls = 0

    init(model: FeedModel) {
        self.model = model
        var buttons: [FeedFilter: FilterButtonNode] = [:]
        for filter in FeedFilter.allCases {
            let button = FilterButtonNode(filter: filter)
            button.activation = { [weak model] in model?.select(filter) }
            buttons[filter] = button
        }
        self.buttons = buttons
        super.init()
        style {
            $0.flexDirection = .column; $0.gap = 16
        }
        for filter in FeedFilter.allCases { addSubnode(buttons[filter]!) }
        addSubnode(statusText)
        addSubnode(retryButton)
        retryButton.activation = { [weak self, weak model] in
            guard let filter = self?.shown?.filter else { return }
            model?.retry(filter: filter)
        }
    }

    func update(_ state: FeedState, animation: Animation) {
        updateCalls += 1
        guard state != shown else { return }
        shown = state

        for (filter, button) in buttons { button.setSelected(filter == state.filter) }

        switch state {
        case .loading:
            statusText.text = "Loading \(state.filter.rawValue.lowercased()) numbers…"
        case .failed(_, let message):
            statusText.text = message
        case .loaded(_, let items):
            for item in items where itemRows[item] == nil {
                itemRows[item] = ItemRowNode(item: item)
            }
        }

        // The whole screen is the scope owner (D62): the status/error text fading and the
        // item list growing/shrinking are one visible transition, not independently snapped
        // pieces — `.none` on the very first (replay) delivery still runs through `animate`,
        // it is simply a zero-duration one (R03: "replay без анимации").
        animate(animation) { markArrangementDirty() }
    }

    override func arrangeSubnodes() -> (any Arrangement)? {
        Column(spacing: 16) {
            Row(spacing: 8) {
                for filter in FeedFilter.allCases {
                    Leaf(buttons[filter]!).size(width: 72, height: 32)
                }
            }
            switch shown {
            case .none, .loading:
                Leaf(statusText)
            case .failed:
                Column(spacing: 10) {
                    Leaf(statusText)
                    Leaf(retryButton).size(width: 80, height: 32)
                }
            case .loaded(_, let items):
                Column(spacing: 6) {
                    for item in items {
                        if let row = itemRows[item] { Leaf(row) }
                    }
                }
            }
        }
    }
}

@MainActor enum S32 {
    static func make(mode: ScenarioMode) -> ScenarioInstance {
        let root = ScenarioNodes.root(mode: mode)
        root.style.flexDirection = .column
        let model = FeedModel()
        let screen = FeedScreenNode(model: model)
        root.addSubnode(screen)

        return ScenarioNodes.instance(
            .s32,
            root: root,
            inputs: "FeedModel (Flux CurrentValue<FeedState> + EffectOwner<String>) bound via "
                + "NodeHostBridge.bindFlux; filter buttons All/Even/Odd, simulated 700ms load, "
                + "\"Even\" fails once then Retry recovers",
            expected: "selecting a filter shows Loading then the filtered list, animated; "
                + "selecting Even the first time shows an error with a Retry button; Retry "
                + "recovers and shows the even numbers; switching filters mid-load cancels the "
                + "stale request (R04) instead of racing it",
            paths: ["root", "root/screen"],
            onAttach: { host, bindings in
                guard let bridge = host.hostBridge else { return }
                let binding = bridge.bindFlux(
                    model.stateFlux,
                    initial: .loading(.all),
                    animation: { _, _ in .smooth }
                ) { [weak screen] state, animation in
                    screen?.update(state, animation: animation)
                }
                bindings.add(binding)
            }
        )
    }
}
