import AVFoundation
import AppShell
import CoreBluetooth
import CoreLocation
import Foundation
import LayoutCore
import Nodes
import NodesRender
import Photos
import StateCore
import UserNotifications

#if canImport(Contacts)
    import Contacts
#endif
#if canImport(EventKit)
    import EventKit
#endif

/// `PERMISSION_PROBE=1` for looking at what the system says about permissions, before any layer of ours
/// stands between: the raw status of each kind, read without asking, and a button to ask. The log
/// carries one `PERMISSIONPROBE` line per status read and per answer, so that a run can be read from
/// outside the app. `PERMISSION_AUTO=<kind>` asks for that kind as the screen opens, which is how a missing
/// `Info.plist` key is provoked on purpose: the system ends the app and says which key it wanted.
@MainActor
enum PermissionProbe {
    static func content(auto: String?) -> any SceneContent {
        NodeScreen(Page(auto: auto), title: "Permissions")
    }

    /// The kinds the probe can read and ask for, in the order the screen lists them.
    static let kinds = [
        "camera", "microphone", "photos", "notifications", "location", "bluetooth", "contacts",
        "calendar", "reminders",
    ]

    /// What the system says about `kind`, read without asking.
    static func status(of kind: String) async -> String {
        switch kind {
        case "camera":
            // The capture device exists on tvOS from 17, and the demo's minimum is 16.
            guard #available(tvOS 17, *) else { return "needs tvOS 17" }

            return describe(AVCaptureDevice.authorizationStatus(for: .video))
        case "microphone":
            guard #available(tvOS 17, *) else { return "needs tvOS 17" }

            return describe(AVCaptureDevice.authorizationStatus(for: .audio))
        case "photos":
            return describe(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case "notifications":
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return describe(settings.authorizationStatus)
        case "location":
            return describe(CLLocationManager().authorizationStatus)
        case "bluetooth":
            return describe(CBManager.authorization)
        #if canImport(Contacts)
            case "contacts":
                return describe(CNContactStore.authorizationStatus(for: .contacts))
        #endif
        #if canImport(EventKit)
            case "calendar":
                return describe(EKEventStore.authorizationStatus(for: .event))
            case "reminders":
                return describe(EKEventStore.authorizationStatus(for: .reminder))
        #endif
        default:
            return "not on this platform"
        }
    }

    /// Asks the system for `kind` and says what came back. The system's window is shown only when the
    /// status is not determined; a kind that was asked before answers at once.
    static func request(_ kind: String) async -> String {
        switch kind {
        case "camera":
            guard #available(tvOS 17, *) else { return "needs tvOS 17" }

            return await AVCaptureDevice.requestAccess(for: .video) ? "granted" : "refused"
        case "microphone":
            guard #available(tvOS 17, *) else { return "needs tvOS 17" }

            return await AVCaptureDevice.requestAccess(for: .audio) ? "granted" : "refused"
        case "photos":
            return describe(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        case "notifications":
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                return granted ? "granted" : "refused"
            } catch {
                return "error \(error)"
            }
        case "location":
            // The answer comes to a delegate later; the probe only starts the request and the
            // status is read again afterwards.
            let manager = CLLocationManager()
            manager.requestWhenInUseAuthorization()
            keep.append(manager)
            return "asked"
        case "bluetooth":
            // Making a central manager is what asks.
            keep.append(CBCentralManager())
            return "asked"
        #if canImport(Contacts)
            case "contacts":
                return (try? await CNContactStore().requestAccess(for: .contacts)) == true
                    ? "granted" : "refused"
        #endif
        #if canImport(EventKit)
            case "calendar":
                return (try? await EKEventStore().requestFullAccessToEvents()) == true
                    ? "granted" : "refused"
            case "reminders":
                return (try? await EKEventStore().requestFullAccessToReminders()) == true
                    ? "granted" : "refused"
        #endif
        default:
            return "not on this platform"
        }
    }

    /// Objects that must outlive the request they started.
    private static var keep: [AnyObject] = []

    @available(tvOS 17, *)
    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        // `.ephemeral` exists on iOS only; its raw value is the only way to name it elsewhere.
        default: "other(\(status.rawValue))"
        }
    }

    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "authorizedAlways"
        case .authorizedWhenInUse: "authorizedWhenInUse"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ status: CBManagerAuthorization) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .allowedAlways: "allowedAlways"
        @unknown default: "unknown"
        }
    }

    #if canImport(Contacts)
        private static func describe(_ status: CNAuthorizationStatus) -> String {
            switch status {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .authorized: "authorized"
            default: "other(\(status.rawValue))"
            }
        }
    #endif

    #if canImport(EventKit)
        private static func describe(_ status: EKAuthorizationStatus) -> String {
            switch status {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .fullAccess: "fullAccess"
            case .writeOnly: "writeOnly"
            default: "other(\(status.rawValue))"
            }
        }
    #endif

    private final class Page: Node {
        private let lines = State<[String: String]>([:])
        private let rows = PermissionProbe.kinds.map { _ in Text("", style: TextStyle(size: 15)) }
        private let refresh = Button("Refresh") {}
        private let askCamera = Button("Ask camera") {}
        private let askNotifications = Button("Ask notifications") {}

        init(auto: String?) {
            super.init()
            refresh.onTap = { [weak self] in self?.reload() }
            askCamera.onTap = { [weak self] in self?.ask("camera") }
            askNotifications.onTap = { [weak self] in self?.ask("notifications") }
            reload()
            if let auto, auto != "1" { ask(auto) }
        }

        private func reload() {
            Task { [weak self] in
                var result: [String: String] = [:]
                for kind in PermissionProbe.kinds {
                    let value = await PermissionProbe.status(of: kind)
                    result[kind] = value
                    NSLog("PERMISSIONPROBE status \(kind) = \(value)")
                }
                self?.lines.value = result
            }
        }

        private func ask(_ kind: String) {
            Task { [weak self] in
                NSLog("PERMISSIONPROBE asking \(kind)")
                let answer = await PermissionProbe.request(kind)
                NSLog("PERMISSIONPROBE answer \(kind) = \(answer)")
                self?.reload()
            }
        }

        override func update() {
            let values = lines.value
            for (index, kind) in PermissionProbe.kinds.enumerated() {
                rows[index].text = "\(kind): \(values[kind] ?? "…")"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for row in rows { row }
                FlexContainer(.row) {
                    refresh
                    askCamera
                    askNotifications
                }
                .gap(8)
            }
            .gap(8)
            .padding(24)
            .alignItems(.start)
        }
    }
}
