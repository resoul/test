import Foundation
import PermissionCore
import Testing
import os

@testable import PermissionSystem

/// A backend that stands for one framework, and counts what it is asked.
private final class SpyBackend: PermissionBackend, Sendable {
    private struct State {
        var statuses = 0
        var requests = 0
        var current: PermissionStatus
        var answer: PermissionStatus
        var holds = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(current: PermissionStatus = .notDetermined, answer: PermissionStatus = .granted(.full)) {
        state = OSAllocatedUnfairLock(initialState: State(current: current, answer: answer))
    }

    var statusReads: Int { state.withLock { $0.statuses } }
    var requests: Int { state.withLock { $0.requests } }

    func setHolding(_ holds: Bool) { state.withLock { $0.holds = holds } }

    func status() async -> PermissionStatus {
        state.withLock {
            $0.statuses += 1
            return $0.current
        }
    }

    func request() async throws(PermissionError) -> PermissionStatus {
        state.withLock { $0.requests += 1 }
        while state.withLock({ $0.holds }) { try? await Task.sleep(for: .milliseconds(2)) }
        return state.withLock { state in
            state.current = state.answer
            return state.answer
        }
    }
}

private let allKeys: @Sendable (String) -> String? = { _ in "Because the app needs it." }

private func provider(
    backend: SpyBackend?,
    keys: @escaping @Sendable (String) -> String? = allKeys,
    foreground: @escaping @Sendable () async -> Bool = { true }
) -> SystemPermissionProvider {
    SystemPermissionProvider(
        isInForeground: foreground,
        usageDescription: keys,
        backends: { _ in backend }
    )
}

@Test
func readingAStatusAsksNothingAndNeedsNeitherKeyNorForeground() async {
    let backend = SpyBackend(current: .denied)
    let system = provider(backend: backend, keys: { _ in nil }, foreground: { false })

    let status = await system.status(of: .camera)

    #expect(status == .denied)
    #expect(backend.requests == 0)
}

@Test
func aRequestAsksTheSystemOnlyAfterTheKeysAndTheForegroundAreChecked() async throws {
    let backend = SpyBackend()
    let system = provider(backend: backend)

    #expect(try await system.request(.camera) == .granted(.full))
    #expect(backend.requests == 1)
}

@Test
func aMissingOrEmptyUsageStringIsAnErrorAndTheSystemIsNotAsked() async {
    for text in [nil, "", "   ", "\n"] as [String?] {
        let backend = SpyBackend()
        let system = provider(backend: backend, keys: { _ in text })

        await #expect(
            throws: PermissionError.missingUsageDescription(key: "NSCameraUsageDescription")
        ) {
            try await system.request(.camera)
        }
        #expect(
            backend.requests == 0,
            "the system must not be asked without the string: \(String(describing: text))"
        )
    }
}

@Test
func everyKeyAKindNeedsIsCheckedAndTheFirstMissingOneIsNamed() async {
    let backend = SpyBackend()
    // "Always" needs two strings; only one is there.
    let system = provider(
        backend: backend,
        keys: { $0 == "NSLocationWhenInUseUsageDescription" ? "Why." : nil }
    )

    await #expect(
        throws: PermissionError.missingUsageDescription(
            key: "NSLocationAlwaysAndWhenInUseUsageDescription"
        )
    ) {
        try await system.request(.location(.always))
    }
    #expect(backend.requests == 0)
}

@Test
func aKindThatNeedsNoKeyIsNotStoppedByTheKeyCheck() async throws {
    let backend = SpyBackend()
    let system = provider(backend: backend, keys: { _ in nil })

    #expect(try await system.request(.notifications) == .granted(.full))
    #expect(backend.requests == 1)
}

@Test
func anAppNotInFrontIsNotAskedAndTheSystemIsNotCalled() async {
    let backend = SpyBackend()
    let system = provider(backend: backend, foreground: { false })

    await #expect(throws: PermissionError.notInForeground) { try await system.request(.microphone) }

    #expect(backend.requests == 0)
}

@Test
func aMissingStringIsReportedEvenWhenTheAppIsBehind() async {
    let system = provider(backend: SpyBackend(), keys: { _ in nil }, foreground: { false })

    // The string is the app's mistake whatever the app is doing; being behind would hide it.
    await #expect(
        throws: PermissionError.missingUsageDescription(key: "NSMicrophoneUsageDescription")
    ) {
        try await system.request(.microphone)
    }
}

@Test
func aKindWithoutAFrameworkHereIsUnavailableAndCannotBeAsked() async {
    let system = provider(backend: nil)

    #expect(await system.status(of: .camera) == .unavailable(.platform))
    await #expect(throws: PermissionError.unsupported(.platform)) {
        try await system.request(.camera)
    }
}

@Test(.timeLimit(.minutes(1)))
func twoCallersAskingAtOnceReachTheSystemOnceThroughThePermissionsLayer() async throws {
    let backend = SpyBackend()
    backend.setHolding(true)
    let permissions = Permissions(provider: provider(backend: backend))

    let first = Task { try await permissions.request(.camera) }
    let second = Task { try await permissions.request(.camera) }
    for _ in 0..<500 where backend.requests == 0 { try await Task.sleep(for: .milliseconds(2)) }
    try await Task.sleep(for: .milliseconds(30))
    backend.setHolding(false)

    #expect(try await first.value == .granted(.full))
    #expect(try await second.value == .granted(.full))
    #expect(backend.requests == 1, "one window for two callers")
}

@Test
func aKindAlreadyAnsweredIsNotAskedAgainThroughThePermissionsLayer() async throws {
    let backend = SpyBackend(current: .denied)
    let permissions = Permissions(provider: provider(backend: backend))

    #expect(try await permissions.request(.camera) == .denied)

    #expect(backend.requests == 0)
}

@Test
func theMissingStringIsAnErrorThroughThePermissionsLayerAndNotRemembered() async throws {
    let backend = SpyBackend()
    let present = OSAllocatedUnfairLock(initialState: false)
    let permissions = Permissions(
        provider: provider(backend: backend, keys: { _ in present.withLock { $0 } ? "Why." : nil })
    )

    await #expect(throws: PermissionError.missingUsageDescription(key: "NSCameraUsageDescription"))
    {
        try await permissions.request(.camera)
    }
    present.withLock { $0 = true }

    // The app fixed its Info.plist; asking again asks for real.
    #expect(try await permissions.request(.camera) == .granted(.full))
    #expect(backend.requests == 1)
}

// MARK: What each framework's answer stands for

#if canImport(AVFoundation)
    import AVFoundation

    @Test
    func theCaptureStatusesAreTheirOwnKindsOfAnswer() {
        #expect(CaptureBackend.map(.notDetermined) == .notDetermined)
        #expect(CaptureBackend.map(.restricted) == .restricted)
        #expect(CaptureBackend.map(.denied) == .denied)
        #expect(CaptureBackend.map(.authorized) == .granted(.full))
    }
#endif

#if canImport(Photos)
    import Photos

    @Test
    func thePhotoStatusesIncludeAccessToSomeOfTheLibrary() {
        #expect(PhotosBackend.map(.notDetermined) == .notDetermined)
        #expect(PhotosBackend.map(.restricted) == .restricted)
        #expect(PhotosBackend.map(.denied) == .denied)
        #expect(PhotosBackend.map(.authorized) == .granted(.full))
        #expect(PhotosBackend.map(.limited) == .granted(.limited))
    }
#endif

#if canImport(UserNotifications)
    import UserNotifications

    @Test
    func theNotificationStatusesIncludeQuietDeliveryWithoutAPrompt() {
        #expect(NotificationsBackend.map(.notDetermined) == .notDetermined)
        #expect(NotificationsBackend.map(.denied) == .denied)
        #expect(NotificationsBackend.map(.authorized) == .granted(.full))
        #expect(NotificationsBackend.map(.provisional) == .granted(.provisional))
        #expect(
            NotificationsBackend.map(UNAuthorizationStatus(rawValue: 4) ?? .notDetermined)
                != .denied
        )
    }
#endif

#if canImport(CoreLocation)
    import CoreLocation

    @Test
    func theLocationStatusesSayHowMuchWasGranted() {
        #expect(LocationBackend.map(.notDetermined) == .notDetermined)
        #expect(LocationBackend.map(.restricted) == .restricted)
        #expect(LocationBackend.map(.denied) == .denied)
        #if canImport(UIKit)
            // The Mac has no "when in use": its location is allowed or it is not.
            #expect(LocationBackend.map(.authorizedWhenInUse) == .granted(.whenInUse))
        #endif
        #expect(LocationBackend.map(.authorizedAlways) == .granted(.always))
    }
#endif
