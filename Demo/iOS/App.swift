// The demo screen on iPhone and iPad, and on the Mac through Mac Catalyst, in a stack of
// screens: the `LayoutDemoiOS` scheme of `Demo.xcodeproj`. SwiftUI is used only here, as the
// app's shell: the screens are made of nodes, whose `Text`, `Color` and `Button` would clash
// with SwiftUI's names in one file.
import AppShell
import AppShellUIKit
import LayoutUIKit
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

/// The demo's stack of screens in its navigation controller: the node screen at the root, a
/// message over it when one is opened in the inbox.
struct DemoScreenView: UIViewControllerRepresentable {
    @MainActor
    final class Coordinator {
        let model = DemoModel()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let model = context.coordinator.model
        model.openMessages(from: ProcessInfo.processInfo.environment)
        return model.stack.makeViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
