import Foundation
import TrellisCore
import TrellisFlux
import TrellisRender

#if canImport(AppKit)
    import TrellisAppKit
#else
    import TrellisUIKit
#endif

/// The reproducible scenario selected for every Playground target.
///
/// Change only this constant when collecting device evidence. `fixedInput` makes the tree use
/// the documented 320×640 canvas; `nativeBounds` leaves the root sized by its real host.
@MainActor
enum Scenario {
    static let current = ScenarioName.s01
    static let mode = ScenarioMode.nativeBounds

    static func makeCurrent() -> ScenarioInstance {
        current.make(mode: mode)
    }

    /// The scene the apps open first: `--scene <name>` on the command line (A11 evidence runs
    /// on the Simulators start straight at S22/S23), else the first scene.
    static var initialIndex: Int {
        guard let flag = CommandLine.arguments.firstIndex(of: "--scene"),
            flag + 1 < CommandLine.arguments.count,
            let index = ScenarioName.allCases.firstIndex(where: {
                $0.rawValue == CommandLine.arguments[flag + 1]
            })
        else { return 0 }
        return index
    }

    /// `--dump-accessibility`: the UIKit/AppKit apps print the native accessibility tree of
    /// the host after the first commit — evidence that the platform API, not only Trellis,
    /// sees labels, traits/roles and frames.
    static var dumpsAccessibility: Bool { CommandLine.arguments.contains("--dump-accessibility") }
}

enum ScenarioName: String, CaseIterable {
    case s01 = "S01_SingleNode"
    case s02 = "S02_RowOfThree"
    case s03 = "S03_Column"
    case s04 = "S04_Justify"
    case s05 = "S05_Align"
    case s06 = "S06_Gap"
    case s07 = "S07_PaddingMargin"
    case s08 = "S08_Grow"
    case s09 = "S09_Sizes"
    case s10 = "S10_Nesting"
    case s11 = "S11_Absolute"
    case s12 = "S12_Wrap"
    case s13 = "S13_RTL"
    case s14 = "S14_SafeArea"
    case s15 = "S15_DynamicMutation"
    case s16 = "S16_ProfileCard"
    case s17 = "S17_AnalyticsDashboard"
    case s18 = "S18_ChatFeed"
    case s19 = "S19_MediaPlayer"
    case s20 = "S20_ReactiveUpdates"
    case s21 = "S21_TapCounter"
    case s22 = "S22_FocusGrid"
    case s23 = "S23_Semantics"
    case s24 = "S24_Typography"
    case s25 = "S25_TextList"
    case s26 = "S26_LabeledSemantics"
    case s27 = "S27_Disclosure"
    case s28 = "S28_AnimationScopesAndReduceMotion"
    case s29 = "S29_ExpandTransitionPlatforms"
    case s30 = "S30_EditorialCardToArticle"
    case s31 = "S31_ProfileCardToProfile"
    case s32 = "S32_FluxFilterFeed"
    case s33 = "S33_ScrollNodeInteraction"
    case s34 = "S34_NestedScrollArticle"
    case s35 = "S35_ListNodeFeed"
    case s36 = "S36_GridNodeMedia"
    case s37 = "S37_TableNodeInbox"
    case s38 = "S38_PagerTabs"

    @MainActor
    func make(mode: ScenarioMode) -> ScenarioInstance {
        switch self {
        case .s01: S01.make(mode: mode)
        case .s02: S02.make(mode: mode)
        case .s03: S03.make(mode: mode)
        case .s04: S04.make(mode: mode)
        case .s05: S05.make(mode: mode)
        case .s06: S06.make(mode: mode)
        case .s07: S07.make(mode: mode)
        case .s08: S08.make(mode: mode)
        case .s09: S09.make(mode: mode)
        case .s10: S10.make(mode: mode)
        case .s11: S11.make(mode: mode)
        case .s12: S12.make(mode: mode)
        case .s13: S13.make(mode: mode)
        case .s14: S14.make(mode: mode)
        case .s15: S15.make(mode: mode)
        case .s16: S16.make(mode: mode)
        case .s17: S17.make(mode: mode)
        case .s18: S18.make(mode: mode)
        case .s19: S19.make(mode: mode)
        case .s20: S20.make(mode: mode)
        case .s21: S21.make(mode: mode)
        case .s22: S22.make(mode: mode)
        case .s23: S23.make(mode: mode)
        case .s24: S24.make(mode: mode)
        case .s25: S25.make(mode: mode)
        case .s26: S26.make(mode: mode)
        case .s27: S27.make(mode: mode)
        case .s28: S28.make(mode: mode)
        case .s29: S29.make(mode: mode)
        case .s30: S30.make(mode: mode)
        case .s31: S31.make(mode: mode)
        case .s32: S32.make(mode: mode)
        case .s33: S33.make(mode: mode)
        case .s34: S34.make(mode: mode)
        case .s35: S35.make(mode: mode)
        case .s36: S36.make(mode: mode)
        case .s37: S37.make(mode: mode)
        case .s38: S38.make(mode: mode)
        }
    }
}

enum ScenarioMode: Equatable {
    case fixedInput
    case nativeBounds
}

@MainActor
struct ScenarioInstance {
    let name: ScenarioName
    let root: Node
    let specification: ScenarioSpecification
    let session: ScenarioSession?
    /// Runs once the app has attached `root` to its host — the place a reactive scenario
    /// binds its `StateSubject` (C29). Bindings go into `bindings` so `teardown()` can cancel
    /// them: the host keeps one bridge across scenes, so a binding left behind would keep
    /// driving a detached tree.
    let onAttach: ((TrellisHostView, ScenarioBindings) -> Void)?
    let bindings = ScenarioBindings()

    /// Stops the session and cancels every state binding — called by the apps before a
    /// scene is replaced or the window closes.
    func teardown() {
        session?.cancel()
        bindings.cancelAll()
    }
}

/// Owned state bindings of one scenario instance.
@MainActor
final class ScenarioBindings {
    private var items: [StateBinding] = []

    private var fluxCancellations: [() -> Void] = []

    func add(_ binding: StateBinding?) {
        guard let binding else { return }
        items.append(binding)
    }

    /// R05: a `TrellisFlux` `FluxStateBinding` is a different type than `StateBinding` (it
    /// wraps both a bridge registration and a Flux pump, ADR 0022) but needs the exact same
    /// "cancel every binding a scene owns on teardown" treatment.
    func add<Value>(_ binding: FluxStateBinding<Value>?) {
        guard let binding else { return }
        fluxCancellations.append { binding.cancel() }
    }

    func cancelAll() {
        for binding in items { binding.cancel() }
        items.removeAll()
        for cancel in fluxCancellations { cancel() }
        fluxCancellations.removeAll()
    }
}

struct ScenarioSpecification: Sendable, Equatable {
    let inputs: String
    let expectedRule: String
    let semanticPaths: [String]
}

@MainActor
final class ScenarioSession {
    /// Delay before a dynamic scene's first mutation. The screenshot export raises it so a
    /// capture on a busy machine (first commit arriving late) still shows phase 0.
    static var firstTickDelay: Duration = .seconds(1)

    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func start(_ operation: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: Self.firstTickDelay)
            while !Task.isCancelled {
                operation()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
enum ScenarioNodes {
    static func root(mode: ScenarioMode, direction: LayoutDirection = .leftToRight) -> Node {
        let root = node("root", color: Palette.canvas)
        root.style {
            $0.flexDirection = .column
            $0.padding = DirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            if mode == .fixedInput {
                $0.width = 320
                $0.height = 640
            }
        }
        root.setLayoutDirection(direction)
        root.setEnvironment(ThemeKey.self, to: Palette.theme)
        return root
    }

    static func node(_ name: String, color: ThemeColor = Palette.blue) -> Node {
        let node = Node(appearance: VisualStyle(background: .color(color), cornerRadius: 8))
        node.style { $0.minHeight = 24 }
        return node
    }

    static func fixed(_ name: String, width: Double, height: Double, color: ThemeColor) -> Node {
        let node = self.node(name, color: color)
        node.style {
            $0.width = .points(width); $0.height = .points(height)
        }
        return node
    }

    static func instance(
        _ name: ScenarioName,
        root: Node,
        inputs: String,
        expected: String,
        paths: [String],
        session: ScenarioSession? = nil,
        onAttach: ((TrellisHostView, ScenarioBindings) -> Void)? = nil
    ) -> ScenarioInstance {
        ScenarioInstance(
            name: name,
            root: root,
            specification: ScenarioSpecification(
                inputs: inputs,
                expectedRule: expected,
                semanticPaths: paths
            ),
            session: session,
            onAttach: onAttach
        )
    }
}

/// Every `TextNode` under `root` that will actually receive a raster job — the set a caller
/// must have a current `DisplayArtifact` for before a scene is considered fully rendered
/// (T12). Excludes a node with no committed frame yet or a zero-area one (an empty-string
/// `TextNode`, S24's edge case, commits at zero/near-zero size): `NodeHostBridge.
/// scanForDisplayWork` itself never schedules those (`guard frame.width > 0, frame.height >
/// 0`), so `displayArtifact(for:)` would never become non-nil for one — waiting on it would
/// wait forever instead of recognizing the scene as ready.
@MainActor
func collectTextNodeIDs(_ root: Node) -> [NodeID] {
    var ids: [NodeID] = []
    func visit(_ node: Node) {
        if let text = node as? TextNode, let frame = text.calculatedFrame, frame.width > 0,
            frame.height > 0
        {
            ids.append(text.id)
        }
        for child in node.subnodes { visit(child) }
    }
    visit(root)
    return ids
}

/// Whether `root` has committed geometry and every `TextNode` under it has a current display
/// artifact (T12) — a fixed delay after the geometry commit is not a bound on when CoreText
/// rasterization actually finishes (a separate, asynchronous step, D53/T06): a scene with real
/// text can commit its layout and still be mid-raster when a caller wants to capture it. `host`
/// resolves to whichever platform's `TrellisHostView` this file is compiled against (AppKit or
/// UIKit) — the same reason `ScenarioInstance.onAttach` already takes one. M07
/// (implementation-plan-5.md) extends this same readiness contract with an animation-settled
/// check; this function is the seam that extension hangs off.
///
/// Bounded by `maxTicks` × `tickMilliseconds` (default 2s): returns whatever the state actually
/// is at that point rather than hanging, so a caller can warn instead of silently exporting a
/// blank or stale capture. `onTick` runs once per unsuccessful poll before the sleep — the
/// macOS export uses it to periodically re-activate its window, since the host suspends its
/// coordinator while the window is not key.
/// M08 fills in the seam the comment above anticipated: `host.sceneReadiness?.animationReady`
/// (M07, D69) folds in as a third condition alongside layout/display — `true`/`nil` when a
/// scene never calls `Node.animate` at all (S01–S26, and most of S27/S28's own frames), so this
/// changes nothing for any scene that predates M04. A scene mid-explicit-transition (S27's
/// disclosure card, S28's retarget demo) is not "ready" by this definition even though its
/// layout and display are both settled — matching D69's "отсутствие активных переходов сцены".
/// The screenshot capture itself (`CALayer.render(in:)`) always draws model values regardless —
/// this gate is about not treating a scene as settled while `LayerAnimator` still owns an active
/// `CABasicAnimation` on it, not about what a single capture would visually show.
@MainActor
@discardableResult
func waitForRenderReady(
    root: Node,
    host: TrellisHostView,
    maxTicks: Int = 200,
    tickMilliseconds: Int = 10,
    onTick: ((Int) -> Void)? = nil
) async -> Bool {
    func isReady() -> Bool {
        root.calculatedFrame != nil
            && collectTextNodeIDs(root).allSatisfy { host.displayArtifact(for: $0) != nil }
            // `displayReady` (not just "an artifact exists") matters for a scene whose layout
            // solver settles in more than one commit (a multi-pass flex resolve, or this
            // scene's own scope/list transitions): an intermediate, narrower-width raster can
            // already exist and pass the `allSatisfy` check above while a newer, final-width
            // raster for the same node is still active/queued (D53 supersedes it, but only once
            // it actually commits) — sampling in that window would capture the stale bitmap
            // clipped into the final box (D65), not a wrong contract, just the wrong moment.
            && (host.sceneReadiness?.displayReady ?? true)
            && (host.sceneReadiness?.animationReady ?? true)
    }
    for tick in 0..<maxTicks {
        if isReady() { return true }
        onTick?(tick)
        try? await Task.sleep(for: .milliseconds(tickMilliseconds))
    }
    return isReady()
}

enum Palette {
    static let canvas = ThemeColor(red: 0.08, green: 0.1, blue: 0.15)
    static let card = ThemeColor(red: 0.12, green: 0.15, blue: 0.22)
    static let cardLight = ThemeColor(red: 0.18, green: 0.22, blue: 0.3)
    static let blue = ThemeColor(red: 0.2, green: 0.55, blue: 0.95)
    static let cyan = ThemeColor(red: 0.2, green: 0.8, blue: 0.9)
    static let green = ThemeColor(red: 0.2, green: 0.75, blue: 0.48)
    static let orange = ThemeColor(red: 0.98, green: 0.58, blue: 0.2)
    static let pink = ThemeColor(red: 0.9, green: 0.3, blue: 0.55)
    static let purple = ThemeColor(red: 0.65, green: 0.38, blue: 0.95)
    static let textSecondary = ThemeColor(red: 0.48, green: 0.54, blue: 0.65)
    static let border = ThemeColor(red: 0.22, green: 0.27, blue: 0.38)

    /// Installed on every scenario root (T12): S01–S23 never read `environment.theme` (every
    /// color is an explicit `ThemeColor` literal above), so this changes nothing for their
    /// existing references — it only gives a `TextNode` with no `textStyle.color` override a
    /// sensible default against this dark canvas instead of the library default `Theme.
    /// defaultValue`'s near-black text (invisible here).
    static let theme = Theme(
        id: "playground-dark",
        colors: ThemeColors(
            background: canvas,
            surface: card,
            primary: blue,
            secondary: purple,
            accent: cyan,
            text: ThemeColor(red: 0.92, green: 0.94, blue: 0.97),
            textSecondary: textSecondary,
            border: border,
            error: pink,
            success: green,
            warning: orange
        )
    )
}
