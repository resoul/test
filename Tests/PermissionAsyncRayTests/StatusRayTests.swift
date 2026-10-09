import AsyncRay
import PermissionCore
import Testing
import os

@testable import PermissionAsyncRay

private final class Collected: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [PermissionStatus]())

    var all: [PermissionStatus] { values.withLock { $0 } }

    func add(_ value: PermissionStatus) { values.withLock { $0.append(value) } }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<2500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

@Test(.timeLimit(.minutes(1)))
func theRayGivesTheStatusNowAndEachChangeFoundLater() async throws {
    let provider = InMemoryPermissionProvider(statuses: [.camera: .notDetermined])
    let permissions = Permissions(provider: provider)
    let seen = Collected()
    let subscription = permissions.statusRay(of: .camera).sink { seen.add($0) }

    #expect(await waitUntil { seen.all == [.notDetermined] })
    await provider.setStatus(.denied, for: .camera)
    await permissions.refresh()
    #expect(await waitUntil { seen.all == [.notDetermined, .denied] })
    // Reading again with no change is not a change.
    await permissions.refresh()
    try await Task.sleep(for: .milliseconds(30))
    #expect(seen.all == [.notDetermined, .denied])
    subscription.cancel()
}

@Test(.timeLimit(.minutes(1)))
func eachSubscriptionObservesOnItsOwnAndOtherKindsAreNotMixedIn() async throws {
    let provider = InMemoryPermissionProvider(statuses: [
        .camera: .denied, .microphone: .notDetermined,
    ])
    let permissions = Permissions(provider: provider)
    let camera = Collected()
    let microphone = Collected()
    let ray = permissions.statusRay(of: .camera)
    let first = ray.sink { camera.add($0) }
    let second = permissions.statusRay(of: .microphone).sink { microphone.add($0) }

    #expect(await waitUntil { camera.all == [.denied] && microphone.all == [.notDetermined] })
    await provider.setStatus(.granted(.full), for: .microphone)
    await permissions.refresh()
    #expect(await waitUntil { microphone.all == [.notDetermined, .granted(.full)] })
    #expect(camera.all == [.denied])
    first.cancel()
    second.cancel()
}

@Test(.timeLimit(.minutes(1)))
func cancellingTheSubscriptionStopsTheObservation() async throws {
    let provider = InMemoryPermissionProvider(statuses: [.camera: .denied])
    let permissions = Permissions(provider: provider)
    let seen = Collected()
    let subscription = permissions.statusRay(of: .camera).sink { seen.add($0) }
    #expect(await waitUntil { seen.all == [.denied] })

    subscription.cancel()
    // Give the stream's termination the turn it needs to release the observer.
    try await Task.sleep(for: .milliseconds(50))
    let readsBefore = await provider.statusReads
    await provider.setStatus(.granted(.full), for: .camera)
    await permissions.refresh()

    #expect(seen.all == [.denied])
    #expect(await provider.statusReads == readsBefore, "no observer is left to read for")
}
