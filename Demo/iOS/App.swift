// The demo screen on iPhone and iPad, and on the Mac through Mac Catalyst: the
// `LayoutDemoiOS` scheme of `Demo.xcodeproj`. SwiftUI is used only here, as the app's shell:
// the screen itself is made of nodes, whose `Text`, `Color` and `Button` would clash with
// SwiftUI's names in one file.
import LayoutUIKit
import NodesUIKit
import SwiftUI
import ThemeCore

@main
struct LayoutDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoScreenView()
                // The screen's own gray, under the status bar and the home indicator too.
                .background(SwiftUI.Color(uiColor: UIColor(Palette.standard.background)).ignoresSafeArea())
        }
    }
}

/// The node screen in a `NodeView`.
struct DemoScreenView: UIViewRepresentable {
    @MainActor
    final class Coordinator {
        let model = DemoModel()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NodeView {
        let view = NodeView(root: context.coordinator.model.screen)
        view.host.solvesInBackground = true
        return view
    }

    func updateUIView(_ view: NodeView, context: Context) {}

    /// The screen takes all the space it is offered.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NodeView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
