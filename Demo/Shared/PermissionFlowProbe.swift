import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import PermissionCore
import PermissionSystem
import StateCore

#if canImport(UIKit)
    import PermissionUIKit
#elseif canImport(AppKit)
    import PermissionAppKit
#endif

/// `PERMISSION_FLOW=1`: the screens an app puts around a permission, for the camera. What is shown
/// follows the status the system gives, and the status is read again when the app comes back to
/// the front, so a change made in Settings changes the screen:
///
/// - not asked yet: an explanation in the app's own words and a button that asks — the system's
///   window comes after the person has read why;
/// - granted: nothing more to do;
/// - denied: the system will not ask again, so the screen says what is off and offers Settings;
/// - restricted: the person cannot change it here either, and the screen says so instead of
///   offering a button that would do nothing;
/// - an error stops the request (a missing usage string, say) and is shown on the screen.
@MainActor
enum PermissionFlowProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Camera access")
    }

    /// What the screen shows for a status. Plain data, so that the wording is in one place.
    struct Screen: Equatable {
        var headline: String
        var body: String
        /// The button that goes forward, if the screen has one.
        var action: Action?

        enum Action: Equatable {
            case ask
            case openSettings
        }

        init(for status: PermissionStatus) {
            switch status {
            case .notDetermined:
                headline = "Scan with the camera"
                body = "The camera reads codes you point it at. Pictures stay on this device."
                action = .ask
            case .granted:
                headline = "The camera is on"
                body = "You can scan now."
                action = nil
            case .denied:
                headline = "The camera is off for this app"
                body = "You said no earlier. You can change that in Settings."
                action = .openSettings
            case .restricted:
                headline = "The camera is not available to you"
                body =
                    "This device does not let you change that, for example under parental controls."
                action = nil
            case .unavailable:
                headline = "No camera here"
                body = "This device has nothing to scan with."
                action = nil
            }
        }
    }

    private static func makeProvider() -> SystemPermissionProvider {
        #if canImport(UIKit)
            UIKitPermissions.makeProvider()
        #else
            AppKitPermissions.makeProvider()
        #endif
    }

    private static func foregroundChanges() -> AsyncStream<Bool> {
        #if canImport(UIKit)
            UIKitPermissions.foregroundChanges()
        #else
            AppKitPermissions.foregroundChanges()
        #endif
    }

    private static func describe(_ error: PermissionError) -> String {
        switch error {
        case .missingUsageDescription(let key): "The app is missing its explanation (\(key))."
        case .notInForeground: "Open the app to continue."
        case .unsupported: "This device cannot ask."
        case .system(let description): "The system failed: \(description)"
        case .cancelled: "Cancelled."
        }
    }

    private final class Page: Node {
        private let permissions = Permissions(provider: PermissionFlowProbe.makeProvider())
        private let status = State(PermissionStatus.notDetermined)
        private let failure = State("")
        private let headline = Text("", style: TextStyle(size: 22))
        private let message = Text("", style: TextStyle(size: 16))
        private let error = Text("", style: TextStyle(size: 15))
        private let ask = Button("Continue") {}
        private let settings = Button("Open Settings") {}
        private var tasks: [Task<Void, Never>] = []

        override init() {
            super.init()
            ask.onTap = { [weak self] in self?.request() }
            settings.onTap = {
                Task {
                    #if canImport(UIKit)
                        await UIKitPermissions.openSettings()
                    #else
                        _ = AppKitPermissions.openSettings()
                    #endif
                }
            }
            let permissions = permissions
            tasks = [
                // The status now, and every change found afterwards.
                Task { [weak self] in
                    for await next in await permissions.statusChanges(of: .camera) {
                        self?.status.value = next
                    }
                },
                // Coming back from Settings reads it again.
                Task { await permissions.follow(PermissionFlowProbe.foregroundChanges()) },
            ]
        }

        deinit {
            for task in tasks { task.cancel() }
        }

        private func request() {
            failure.value = ""
            Task { [weak self] in
                guard let self else { return }

                do throws(PermissionError) {
                    _ = try await permissions.request(.camera)
                } catch {
                    failure.value = PermissionFlowProbe.describe(error)
                }
            }
        }

        override func update() {
            let screen = Screen(for: status.value)
            headline.text = screen.headline
            message.text = screen.body
            error.text = failure.value
        }

        override func layoutSpec() -> LayoutSpec? {
            let action = Screen(for: status.value).action
            return FlexContainer(.column) {
                headline
                message
                if action == .ask { ask }
                if action == .openSettings { settings }
                error
            }
            .gap(12)
            .padding(24)
            .alignItems(.start)
        }
    }
}
