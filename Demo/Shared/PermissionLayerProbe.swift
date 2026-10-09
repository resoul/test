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

/// `PERMISSION_LAYER=1` for UI tests and for looking at the permission layer over the system: each
/// kind with the status the system gives it, and a button to ask through `Permissions` and the
/// system's provider. A line says what the last ask came to — the status, or the error that stopped it,
/// such as a usage string the app does not have: the system is then not asked and the app does not end.
@MainActor
enum PermissionLayerProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Permission layer")
    }

    /// The kinds on the screen, with the name the screen and its tests call each by.
    private static let kinds: [(name: String, kind: PermissionKind)] = [
        ("camera", .camera),
        ("microphone", .microphone),
        ("photos", .photos(.readWrite)),
        ("photosAddOnly", .photos(.addOnly)),
        ("notifications", .notifications),
        ("location", .location(.whenInUse)),
        ("locationAlways", .location(.always)),
    ]

    private static func makeProvider() -> SystemPermissionProvider {
        #if canImport(UIKit)
            UIKitPermissions.makeProvider()
        #else
            AppKitPermissions.makeProvider()
        #endif
    }

    private static func describe(_ status: PermissionStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .granted(let grant): "granted(\(grant))"
        case .denied: "denied"
        case .restricted: "restricted"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    private static func describe(_ error: PermissionError) -> String {
        switch error {
        case .missingUsageDescription(let key): "missing \(key)"
        case .notInForeground: "not in foreground"
        case .unsupported(let reason): "unsupported(\(reason))"
        case .system(let description): "system \(description)"
        case .cancelled: "cancelled"
        }
    }

    private final class Page: Node {
        private let permissions = Permissions(provider: PermissionLayerProbe.makeProvider())
        private let statuses = State<[String: String]>([:])
        private let result = State("")
        private let rows = PermissionLayerProbe.kinds.map { _ in Text("", style: TextStyle(size: 15)) }
        private let outcome = Text("", style: TextStyle(size: 15))
        private let askButtons: [Button]
        private let refresh = Button("Refresh") {}
        private let settings = Button("Open Settings") {}

        override init() {
            askButtons = PermissionLayerProbe.kinds.map { Button("Ask \($0.name)") {} }
            super.init()
            for (index, entry) in PermissionLayerProbe.kinds.enumerated() {
                askButtons[index].onTap = { [weak self] in self?.ask(entry.name, entry.kind) }
            }
            refresh.onTap = { [weak self] in self?.reload() }
            settings.onTap = {
                Task {
                    #if canImport(UIKit)
                        await UIKitPermissions.openSettings()
                    #else
                        _ = AppKitPermissions.openSettings()
                    #endif
                }
            }
            reload()
        }

        private func reload() {
            Task { [weak self] in
                guard let self else { return }

                var values: [String: String] = [:]
                for entry in PermissionLayerProbe.kinds {
                    values[entry.name] = PermissionLayerProbe.describe(
                        await permissions.status(of: entry.kind)
                    )
                }
                statuses.value = values
            }
        }

        private func ask(_ name: String, _ kind: PermissionKind) {
            Task { [weak self] in
                guard let self else { return }
                do throws(PermissionError) {
                    let status = try await permissions.request(kind)
                    result.value = "\(name): \(PermissionLayerProbe.describe(status))"
                } catch {
                    result.value = "\(name): error \(PermissionLayerProbe.describe(error))"
                }
                reload()
            }
        }

        override func update() {
            let values = statuses.value
            for (index, entry) in PermissionLayerProbe.kinds.enumerated() {
                rows[index].text = "\(entry.name): \(values[entry.name] ?? "…")"
            }
            outcome.text = "result: \(result.value)"
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for index in rows.indices {
                    FlexContainer(.row) {
                        rows[index]
                        askButtons[index]
                    }
                    .gap(12)
                    .alignItems(.center)
                }
                outcome
                FlexContainer(.row) {
                    refresh
                    settings
                }
                .gap(8)
            }
            .gap(8)
            .padding(24)
            .alignItems(.start)
        }
    }
}
