import Foundation
import PermissionCore
import Testing
import os

private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

@Test
func readingAStatusAsksNothingAndHasNoEffect() async {
    let provider = InMemoryPermissionProvider(statuses: [.camera: .denied])
    let permissions = Permissions(provider: provider)

    let camera = await permissions.status(of: .camera)
    let microphone = await permissions.status(of: .microphone)

    #expect(camera == .denied)
    #expect(microphone == .notDetermined)
    #expect(await provider.requests.isEmpty)
}

@Test
func askingForAKindNotAskedAboutShowsTheWindowOnceAndReturnsTheAnswer() async throws {
    let provider = InMemoryPermissionProvider()
    let permissions = Permissions(provider: provider)

    let result = try await permissions.request(.camera)

    #expect(result == .granted(.full))
    #expect(await provider.requests == [.camera])
    #expect(await permissions.status(of: .camera) == .granted(.full))
}

@Test
func aPersonsNoIsAStatusNotAnError() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.willAnswer(.denied, for: .microphone)
    let permissions = Permissions(provider: provider)

    #expect(try await permissions.request(.microphone) == .denied)
}

@Test
func askingAgainAfterAnyAnswerReturnsItWithoutAskingTheSystem() async throws {
    let provider = InMemoryPermissionProvider(statuses: [
        .camera: .denied,
        .microphone: .granted(.full),
        .photos(.readWrite): .granted(.limited),
        .notifications: .restricted,
        .location(.always): .unavailable(.platform),
    ])
    let permissions = Permissions(provider: provider)

    #expect(try await permissions.request(.camera) == .denied)
    #expect(try await permissions.request(.microphone) == .granted(.full))
    #expect(try await permissions.request(.photos(.readWrite)) == .granted(.limited))
    #expect(try await permissions.request(.notifications) == .restricted)
    #expect(try await permissions.request(.location(.always)) == .unavailable(.platform))

    #expect(await provider.requests.isEmpty)
}

@Test
func levelsOfOneKindAreDifferentPermissions() async throws {
    let provider = InMemoryPermissionProvider(statuses: [.photos(.addOnly): .granted(.full)])
    let permissions = Permissions(provider: provider)

    #expect(try await permissions.request(.photos(.addOnly)) == .granted(.full))
    // Add-only access is granted; read and write is a separate question and is still open.
    #expect(try await permissions.request(.photos(.readWrite)) == .granted(.full))
    #expect(await provider.requests == [.photos(.readWrite)])
}

@Test(.timeLimit(.minutes(1)))
func callersAskingForTheSameKindShareOneRequestAndOneResult() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.holdRequests(true)
    let permissions = Permissions(provider: provider)

    let callers = (0..<5).map { _ in Task { try await permissions.request(.camera) } }
    #expect(await waitUntil { await provider.requests.count == 1 })
    try await Task.sleep(for: .milliseconds(30))
    await provider.holdRequests(false)

    for caller in callers { #expect(try await caller.value == .granted(.full)) }
    #expect(await provider.requests == [.camera])
}

@Test(.timeLimit(.minutes(1)))
func differentKindsAreAskedOneAtATimeInTheOrderTheyCame() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.holdRequests(true)
    let permissions = Permissions(provider: provider)

    let first = Task { try await permissions.request(.camera) }
    #expect(await waitUntil { await provider.requests == [.camera] })
    let second = Task { try await permissions.request(.microphone) }
    let third = Task { try await permissions.request(.notifications) }
    try await Task.sleep(for: .milliseconds(50))

    // The first window is open; the others wait for it.
    #expect(await provider.requests == [.camera])

    await provider.holdRequests(false)
    _ = try await first.value
    _ = try await second.value
    _ = try await third.value

    #expect(await provider.requests == [.camera, .microphone, .notifications])
    #expect(await provider.mostOpenRequests == 1)
}

@Test(.timeLimit(.minutes(1)))
func cancellingACallerEndsItsWaitAndLeavesTheRequestAndTheOthersAlone() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.holdRequests(true)
    let permissions = Permissions(provider: provider)
    let leaving = Task { try await permissions.request(.camera) }
    let staying = Task { try await permissions.request(.camera) }
    #expect(await waitUntil { await provider.requests.count == 1 })
    try await Task.sleep(for: .milliseconds(30))

    leaving.cancel()

    await #expect(throws: PermissionError.cancelled) { try await leaving.value }
    // The window is still open and the person still answers it.
    await provider.holdRequests(false)
    #expect(try await staying.value == .granted(.full))
    #expect(await provider.requests == [.camera])
}

@Test(.timeLimit(.minutes(1)))
func theAnswerToACancelledRequestIsNotLost() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.holdRequests(true)
    let permissions = Permissions(provider: provider)
    let stream = await permissions.statusChanges(of: .camera)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .notDetermined)

    let only = Task { try await permissions.request(.camera) }
    #expect(await waitUntil { await provider.requests.count == 1 })
    only.cancel()
    await #expect(throws: PermissionError.cancelled) { try await only.value }

    // The person answers after the caller has gone; the answer is kept and observers are told.
    await provider.holdRequests(false)
    #expect(await iterator.next() == .granted(.full))
    #expect(await permissions.status(of: .camera) == .granted(.full))
}

@Test
func aTaskCancelledBeforeAskingNeverAsks() async throws {
    let provider = InMemoryPermissionProvider()
    let permissions = Permissions(provider: provider)

    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await permissions.request(.camera)
    }
    task.cancel()

    await #expect(throws: PermissionError.cancelled) { try await task.value }
    #expect(await provider.requests.isEmpty)
}

@Test
func anErrorFromTheProviderReachesEveryCallerAndIsNotRemembered() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.holdRequests(true)
    await provider.failNextRequest(with: .missingUsageDescription(key: "NSCameraUsageDescription"))
    let permissions = Permissions(provider: provider)
    let callers = (0..<3).map { _ in Task { try await permissions.request(.camera) } }
    #expect(await waitUntil { await provider.requests.count == 1 })
    try await Task.sleep(for: .milliseconds(30))
    await provider.holdRequests(false)

    for caller in callers {
        await #expect(
            throws: PermissionError.missingUsageDescription(key: "NSCameraUsageDescription")
        ) {
            try await caller.value
        }
    }
    // The status did not change, and asking again asks again.
    #expect(await permissions.status(of: .camera) == .notDetermined)
    #expect(try await permissions.request(.camera) == .granted(.full))
    #expect(await provider.requests.count == 2)
}

@Test
func aFailedRequestDoesNotHoldUpTheNextKind() async throws {
    let provider = InMemoryPermissionProvider()
    await provider.failNextRequest(with: .notInForeground)
    let permissions = Permissions(provider: provider)

    await #expect(throws: PermissionError.notInForeground) {
        try await permissions.request(.camera)
    }

    #expect(try await permissions.request(.microphone) == .granted(.full))
}

/// What a consumer that takes every element at once has received.
private final class Received: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [PermissionStatus]())

    var all: [PermissionStatus] { stored.withLock { $0 } }

    func add(_ status: PermissionStatus) { stored.withLock { $0.append(status) } }
}

@Test(.timeLimit(.minutes(1)))
func observingGivesTheCurrentStatusThenEachDifferentOneAndNoRepeats() async throws {
    let provider = InMemoryPermissionProvider()
    let permissions = Permissions(provider: provider)
    let received = Received()
    let stream = await permissions.statusChanges(of: .camera)
    let consumer = Task { for await status in stream { received.add(status) } }
    #expect(await waitUntil { received.all == [.notDetermined] })

    // Reading what is already known, again and again, reports nothing.
    _ = await permissions.status(of: .camera)
    await permissions.refresh()
    await permissions.refresh()
    try await Task.sleep(for: .milliseconds(30))
    #expect(received.all == [.notDetermined])

    _ = try await permissions.request(.camera)
    #expect(await waitUntil { received.all.count == 2 })

    // Settings: the person takes the permission back; the app notices when it is asked to look.
    await provider.setStatus(.denied, for: .camera)
    await permissions.refresh()
    #expect(await waitUntil { received.all.count == 3 })
    await permissions.refresh()
    await provider.setStatus(.granted(.full), for: .camera)
    await permissions.refresh()
    #expect(await waitUntil { received.all.count == 4 })
    try await Task.sleep(for: .milliseconds(30))

    #expect(received.all == [.notDetermined, .granted(.full), .denied, .granted(.full)])
    consumer.cancel()
}

@Test(.timeLimit(.minutes(1)))
func aStatusThatChangedAndChangedBackBetweenReadingsIsNotSeen() async throws {
    let provider = InMemoryPermissionProvider(statuses: [.camera: .granted(.full)])
    let permissions = Permissions(provider: provider)
    let stream = await permissions.statusChanges(of: .camera)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .granted(.full))

    await provider.setStatus(.denied, for: .camera)
    await provider.setStatus(.granted(.full), for: .camera)
    await permissions.refresh()
    await provider.setStatus(.denied, for: .camera)
    await permissions.refresh()

    // Only the reading that differed produced an element: this is re-reading, not a log.
    #expect(await iterator.next() == .denied)
}

@Test(.timeLimit(.minutes(1)))
func observersOfOneKindAreIndependentAndOtherKindsAreNotTold() async throws {
    let provider = InMemoryPermissionProvider()
    let permissions = Permissions(provider: provider)
    let first = await permissions.statusChanges(of: .camera)
    let second = await permissions.statusChanges(of: .camera)
    let other = await permissions.statusChanges(of: .microphone)
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()
    var otherIterator = other.makeAsyncIterator()
    _ = await firstIterator.next()
    _ = await secondIterator.next()
    _ = await otherIterator.next()

    await provider.setStatus(.denied, for: .camera)
    await permissions.refresh()
    await provider.setStatus(.restricted, for: .microphone)
    await permissions.refresh()

    #expect(await firstIterator.next() == .denied)
    #expect(await secondIterator.next() == .denied)
    #expect(await otherIterator.next() == .restricted)
}

@Test(.timeLimit(.minutes(1)))
func aSlowObserverSeesTheLatestStatusNotEveryOne() async throws {
    let provider = InMemoryPermissionProvider()
    let permissions = Permissions(provider: provider)
    let stream = await permissions.statusChanges(of: .camera)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .notDetermined)

    await provider.setStatus(.granted(.full), for: .camera)
    await permissions.refresh()
    await provider.setStatus(.denied, for: .camera)
    await permissions.refresh()

    #expect(await iterator.next() == .denied)
}

@Test(.timeLimit(.minutes(1)))
func anEndedObserverIsReleasedAndTheRestKeepWorking() async throws {
    let provider = InMemoryPermissionProvider()
    let permissions = Permissions(provider: provider)
    let leaving = Task {
        for await _ in await permissions.statusChanges(of: .camera) { break }
    }
    let staying = await permissions.statusChanges(of: .camera)
    var iterator = staying.makeAsyncIterator()
    _ = await iterator.next()
    _ = await leaving.value

    await provider.setStatus(.denied, for: .camera)
    await permissions.refresh()

    #expect(await iterator.next() == .denied)
}

@Test
func everyKindNamesTheKeysItNeedsAndNotificationsNeedNone() {
    #expect(PermissionKind.camera.usageDescriptionKeys == ["NSCameraUsageDescription"])
    #expect(PermissionKind.microphone.usageDescriptionKeys == ["NSMicrophoneUsageDescription"])
    #expect(
        PermissionKind.photos(.readWrite).usageDescriptionKeys == ["NSPhotoLibraryUsageDescription"]
    )
    #expect(
        PermissionKind.photos(.addOnly).usageDescriptionKeys == [
            "NSPhotoLibraryAddUsageDescription"
        ]
    )
    #expect(PermissionKind.notifications.usageDescriptionKeys.isEmpty)
    #expect(
        PermissionKind.location(.whenInUse).usageDescriptionKeys == [
            "NSLocationWhenInUseUsageDescription"
        ]
    )
    #expect(
        Set(PermissionKind.location(.always).usageDescriptionKeys)
            == [
                "NSLocationAlwaysAndWhenInUseUsageDescription",
                "NSLocationWhenInUseUsageDescription",
            ]
    )
}

@Test
func onlyAGrantIsGranted() {
    #expect(PermissionStatus.granted(.limited).isGranted)
    #expect(PermissionStatus.granted(.provisional).isGranted)
    for status in [PermissionStatus.notDetermined, .denied, .restricted, .unavailable(.hardware)] {
        #expect(!status.isGranted)
    }
}

// MARK: Following the app to the front

@Test(.timeLimit(.minutes(1)))
func comingBackToTheFrontReadsTheObservedKindsAgain() async throws {
    let provider = InMemoryPermissionProvider(statuses: [.camera: .denied])
    let permissions = Permissions(provider: provider)
    var changes = await permissions.statusChanges(of: .camera).makeAsyncIterator()
    #expect(await changes.next() == .denied)
    let (foreground, input) = AsyncStream.makeStream(of: Bool.self)
    let following = Task { await permissions.follow(foreground) }

    // The person changes the permission in Settings and comes back.
    await provider.setStatus(.granted(.full), for: .camera)
    input.yield(false)
    input.yield(true)

    #expect(await changes.next() == .granted(.full))
    input.finish()
    await following.value
}

@Test(.timeLimit(.minutes(1)))
func leavingTheFrontReadsNothing() async throws {
    let provider = InMemoryPermissionProvider(statuses: [.camera: .denied])
    let permissions = Permissions(provider: provider)
    // The observer lives as long as its stream does, so the stream is kept to the end.
    let changes = await permissions.statusChanges(of: .camera)
    let readsAfterObserving = await provider.statusReads
    let (foreground, input) = AsyncStream.makeStream(of: Bool.self)
    let following = Task { await permissions.follow(foreground) }

    input.yield(false)
    input.yield(false)
    input.finish()
    await following.value

    #expect(await provider.statusReads == readsAfterObserving)
    withExtendedLifetime(changes) {}
}

@Test(.timeLimit(.minutes(1)))
func followingEndsWhenItsTaskIsCancelled() async {
    let permissions = Permissions(provider: InMemoryPermissionProvider())
    let (foreground, input) = AsyncStream.makeStream(of: Bool.self)
    _ = input
    let following = Task { await permissions.follow(foreground) }

    following.cancel()
    await following.value
}
