import FlexEngine
import Foundation
import LayoutCore
import NetworkCore
import PermissionCore
import StateCore
import StorageCore
import Testing
import ThemeCore

import BasicsExamples
import DataExamples
import DatabaseExamples
import LayoutExamples
import NodesUIExamples
import PermissionsExamples
import StreamsExamples
import TogetherExamples

// Each test runs one example of the packages' guides and checks what the guide says it does.

// MARK: - Layout

@Test
func theEngineLaysOutARowWithoutViews() throws {
    let wide = try layoutProfileRow(name: "Ann Lee", width: 320)
    #expect(wide.frame(for: ProfileRowID.avatar) == LayoutRect(x: 16, y: 16, width: 48, height: 48))
    #expect(wide.frame(for: ProfileRowID.name) == LayoutRect(x: 76, y: 30, width: 146, height: 20))
    #expect(
        wide.frame(for: ProfileRowID.button) == LayoutRect(x: 234, y: 24, width: 70, height: 32)
    )

    // Short of room, the name shrinks and wraps into three lines.
    let narrow = try layoutProfileRow(name: "Ann Lee", width: 200)
    #expect(narrow.frame(for: ProfileRowID.name) == LayoutRect(x: 76, y: 10, width: 26, height: 60))
}

@Test
func theEngineRunsOffTheMainActorAndStopsWhenCancelled() async throws {
    let result = try await layoutProfileRowInBackground(name: "Ann Lee", width: 320)
    #expect(result.frame(for: ProfileRowID.name)?.size.width == 146)

    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await layoutProfileRowInBackground(name: "Ann Lee", width: 320)
    }
    await #expect(throws: LayoutCancelled.self) { try await cancelled.value }
}

@Test @MainActor
func aSpecPicksItsBranchByTheWidth() {
    let wide = Card()
    layoutCard(wide, in: LayoutRect(x: 0, y: 0, width: 480, height: 100))
    #expect(wide.avatar.frame == LayoutRect(x: 16, y: 26, width: 48, height: 48))
    #expect(wide.title.frame == LayoutRect(x: 76, y: 30, width: 306, height: 20))
    #expect(wide.follow.frame == LayoutRect(x: 394, y: 34, width: 70, height: 32))

    let narrow = Card()
    layoutCard(narrow, in: LayoutRect(x: 0, y: 0, width: 320, height: 300))
    #expect(narrow.avatar.frame == LayoutRect(x: 16, y: 16, width: 64, height: 64))
    #expect(narrow.title.frame == LayoutRect(x: 16, y: 88, width: 120, height: 20))
    #expect(narrow.follow.frame == LayoutRect(x: 16, y: 140, width: 70, height: 32))
}

@Test @MainActor
func aSpecSolvedInTheBackgroundGivesTheSameFrames() async throws {
    let card = Card()
    try await layoutCardInBackground(card, in: LayoutRect(x: 0, y: 0, width: 480, height: 100))
    #expect(card.title.frame == LayoutRect(x: 76, y: 30, width: 306, height: 20))
}

@Test @MainActor
func theThemeGivesValuesForTheConditionsAndItsSpacingToLayouts() {
    let values = themedValues(dark: true, textScale: 1.5)
    #expect(values.accent == Color(red: 0.4, green: 0.6, blue: 1))
    #expect(values.bodySize == 17 * 1.5)
    #expect(values.gap == 16)

    let card = Card()
    layoutThemedCard(card, in: LayoutRect(x: 0, y: 0, width: 480, height: 100))
    #expect(card.avatar.frame == LayoutRect(x: 20, y: 26, width: 48, height: 48))
    #expect(card.title.frame == LayoutRect(x: 84, y: 28, width: 290, height: 20))
    #expect(card.follow.frame?.origin.x == 390)
}

// MARK: - Basics

@Test @MainActor
func anEffectSeesTheWritesOfAStretchOnce() {
    #expect(runCart() == ["Total: 250", "Total: 900"])
}

@Test
func richTextIsEditedAsAValue() {
    #expect(boldFirstWord(of: "Hello world") == "**Hello** world")
}

@Test
func aTextIsFoundForTheLanguageAndItsPluralForm() {
    #expect(unreadText(1, localeIdentifier: "en_US") == "1 unread message")
    #expect(unreadText(5, localeIdentifier: "ru_RU") == "5 непрочитанных")
    #expect(unreadText(21, localeIdentifier: "ru_RU") == "21 непрочитанное")
    #expect(unreadText(3, localeIdentifier: "de_DE") == "3 unread messages")
}

@Test
func aMeasuredStretchIsRecordedAsItsBeginningAndEnd() {
    #expect(traceDecoding() == [.begin, .end])
}

// MARK: - Data

@Test
func preferencesAreReadAndWrittenThroughTheProtocol() async throws {
    let values = try await updateSettings(in: MemoryPreferences())
    #expect(values.compact)
    #expect(values.width == 1024)
}

@Test
func aFileIsWrittenUnderACheckedPath() async throws {
    #expect(try await saveNote("milk", in: MemoryFileStore()) == ["notes/today.txt"])
    #expect(throws: FileError.self) { try FilePath("../outside") }
}

@Test
func theClientDecodesAnswersAndDownloadsIntoAStore() async throws {
    let body = Data(#"[{"id":1,"title":"Milk"}]"#.utf8)
    let client = itemsClient(transport: CannedTransport(body: body))
    #expect(try await loadItems(with: client) == [Item(id: 1, title: "Milk")])

    let store = MemoryFileStore()
    #expect(try await cacheItems(with: client, in: store) == body.count)
    #expect(try await store.read(FilePath("cache/items.json")) == body)
}

// MARK: - Database

@Test
func theDatabaseMigratesWritesAndIsFollowed() async throws {
    let run = try await runTodos()
    #expect(run.seen == [[], ["Milk", "Bread"], ["Bread"]])
    #expect(run.total == 2)
}

// MARK: - Permissions

@Test
func theCameraIsAskedForOnlyWhenAskingCanChangeSomething() async throws {
    #expect(try await prepareCamera(with: testPermissions(answer: .granted(.full))) == .ready)
    #expect(try await prepareCamera(with: testPermissions(answer: .denied)) == .sendToSettings)
}

// MARK: - Nodes UI

@Test @MainActor
func aNodeTreeFollowsItsState() {
    let frames = runCounter()
    // The column starts at its top, so without the hint the button moves up into its place.
    #expect(frames.after.origin.y < frames.before.origin.y)
    #expect(frames.after.size == frames.before.size)
}

@Test @MainActor
func aStackKeepsThePathWithoutAPlatformContainer() {
    let paths = browseMail(makeMailStack())
    #expect(paths == [[.inbox], [.inbox, .message(id: 7)], [.inbox]])
}

// MARK: - Streams

@Test @MainActor
func streamsFeedStatesUntilStopped() async throws {
    let preferences = MemoryPreferences()
    let provider = InMemoryPermissionProvider(statuses: [.camera: .granted(.full)])
    let model = SettingsModel()
    model.bind(preferences: preferences, permissions: Permissions(provider: provider))

    try await preferences.set(true, for: PreferenceKey("settings.compactRows", default: false))
    await waitUntil { model.compactRows.value && model.camera.value == .granted(.full) }
    #expect(model.compactRows.value)
    #expect(model.camera.value == .granted(.full))
    model.stop()
}

@Test @MainActor
func aStateIsAStreamOfItsValues() async {
    let count = State(1)
    let watching = Task { await watchCount(count, values: 2) }
    // The stream gives the value at subscription first, then a later one.
    var next = 2
    for _ in 0..<400 {
        try? await Task.sleep(for: .milliseconds(5))
        count.value = next
        next += 1
        StateUpdates.flush()
    }
    let values = await watching.value
    #expect(values.count == 2)
    #expect(values.first.map { $0 >= 1 } == true)
    #expect(values == values.sorted())
}

// MARK: - Together

@Test @MainActor
func aStoredPreferenceReachesTheLayoutThroughAState() async throws {
    let heights = try await runDensityList()
    #expect(heights.regular == 44 * 3 + 8 * 2)
    #expect(heights.compact == 32 * 3 + 2 * 2)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
