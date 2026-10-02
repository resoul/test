#if canImport(AVFoundation) && canImport(QuartzCore)
    import AVFoundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import StateCore
    import Testing
    import ThemeCore

    #if canImport(UIKit)
        import UIKit
        import NodesUIKit
    #elseif canImport(AppKit)
        import AppKit
        import NodesAppKit
    #endif

    @testable import NodesRender

    /// A session that does nothing but record what it is asked, and lets the test report for it.
    @MainActor
    private final class FakeSession: VideoSession {
        let url: URL
        let report: @MainActor (VideoSessionEvent) -> Void
        var calls: [String] = []
        var seconds: Double? = nil
        var isStopped = false

        init(url: URL, report: @escaping @MainActor (VideoSessionEvent) -> Void) {
            self.url = url
            self.report = report
        }

        func play() { calls.append("play") }
        func pause() { calls.append("pause") }
        func seek(toSeconds seconds: Double) { calls.append("seek \(seconds)") }
        func setMuted(_ isMuted: Bool) { calls.append("muted \(isMuted)") }
        func setVolume(_ volume: Double) { calls.append("volume \(volume)") }
        func setLooping(_ isLooping: Bool) { calls.append("loop \(isLooping)") }
        var currentSeconds: Double? { seconds }
        func stop() { isStopped = true }
    }

    /// A page with a spacer above the video: the spacer's height decides whether the video is in
    /// the 300-point window or below it.
    @MainActor
    private final class Page: Node {
        let video: Video
        let spacer = State(0.0)
        var sessions: [FakeSession] = []

        init(source: VideoSource?, placeholder: Node? = nil) {
            video = Video(source: source)
            super.init()
            video.placeholder = placeholder
            video.makeSession = { [unowned self] url, _, report in
                let session = FakeSession(url: url, report: report)
                sessions.append(session)
                return session
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                Box(height: spacer.value)
                video
            }
            .alignItems(.stretch)
        }
    }

    @MainActor
    private final class Box: Node {
        let height: Double
        init(height: Double) {
            self.height = height
            super.init()
        }
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 10, height: height)) }
    }

    @MainActor
    private final class Poster: Node {
        override var layoutContent: LeafContent? { .size(LayoutSize(width: 10, height: 10)) }
    }

    /// A feed of videos under a spacer, all in the tree and showing; the first is in the 300-point
    /// window, the others are below it, which is where a feed keeps what it prepares.
    @MainActor
    private final class Feed: Node {
        let videos: [Video]
        var sessions: [[FakeSession]]
        var metadataReads: [URL] = []
        /// Which video each session was made for, in the order they were made.
        var madeFor: [Int] = []
        let budget: VideoPreparationBudget

        /// The height between two videos: 300 keeps all but the first out of the window; 0 puts the
        /// second in it, which a test of playing needs.
        let gap: Double

        init(
            count: Int,
            budget: VideoPreparationBudget,
            preload: VideoPreload = .none,
            gap: Double = 300
        ) {
            self.budget = budget
            self.gap = gap
            videos = (0..<count).map { _ in Video(source: nil) }
            sessions = Array(repeating: [], count: count)
            super.init()
            for (index, video) in videos.enumerated() {
                video.preparationBudget = budget
                video.preload = preload
                video.aspectRatio = nil
                video.makeSession = { [unowned self] url, _, report in
                    let session = FakeSession(url: url, report: report)
                    sessions[index].append(session)
                    madeFor.append(index)
                    return session
                }
                video.readMetadata = { [unowned self] url in
                    await MainActor.run { metadataReads.append(url) }
                    return (LayoutSize(width: 640, height: 360), .seconds(12))
                }
                video.source = .url(URL(string: "file:///tmp/clip-\(index).mp4")!)
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                for video in videos {
                    video
                    Box(height: gap)
                }
            }
            .alignItems(.stretch)
        }

        /// The sessions of the video at `index` that are not stopped.
        func live(_ index: Int) -> [FakeSession] { sessions[index].filter { !$0.isStopped } }

        /// The videos that hold a session now, in the order the sessions were made.
        var prepared: [Int] {
            var seen: [Int] = []
            for index in madeFor where !live(index).isEmpty && !seen.contains(index) {
                seen.append(index)
            }
            return seen
        }
    }

    @MainActor
    private func shown(_ feed: Feed) -> NodeHost {
        let host = NodeHost(root: feed, size: LayoutSize(width: 300, height: 300))
        host.layoutIfNeeded()
        for _ in 0..<3 { host.layoutIfNeeded() }
        return host
    }

    /// Turns preparation on for the videos at `indices`, one after another, so that the order in
    /// which they ask for a place does not depend on the order the tree is walked in.
    @MainActor
    private func prepare(_ indices: [Int], of feed: Feed, in host: NodeHost) {
        for index in indices {
            feed.videos[index].preload = .automatic
            for _ in 0..<3 { host.layoutIfNeeded() }
        }
    }

    private let clip = URL(string: "file:///tmp/clip.mp4")!

    @MainActor
    private func shown(_ page: Page) -> NodeHost {
        let host = NodeHost(root: page, size: LayoutSize(width: 300, height: 300))
        host.layoutIfNeeded()
        return host
    }

    @MainActor
    private func settle(_ host: NodeHost) {
        for _ in 0..<3 { host.layoutIfNeeded() }
    }

    @Suite(.serialized) @MainActor struct VideoTests {
        @Test func nothingIsReadUntilPlaybackIsAskedFor() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            #expect(page.video.loadPhase == .idle)
            #expect(page.sessions.isEmpty, "a video in sight reads nothing until it is asked")
            host.detach()
        }

        @Test func playAsksForASessionThatWaitsForTheFirstPicture() {
            let poster = Poster()
            let page = Page(source: .url(clip), placeholder: poster)
            let host = shown(page)
            #expect(poster.isMounted, "the placeholder stands over the video from the start")

            page.video.play()
            settle(host)
            #expect(page.sessions.count == 1)
            #expect(page.sessions[0].url == clip)
            #expect(page.sessions[0].calls.contains("play"))
            #expect(page.video.loadPhase == .loading)
            #expect(poster.isMounted)

            page.sessions[0].report(
                .ready(size: LayoutSize(width: 320, height: 240), duration: .seconds(4))
            )
            #expect(page.video.naturalSize == LayoutSize(width: 320, height: 240))
            #expect(page.video.duration == .seconds(4))
            #expect(page.video.loadPhase == .loading, "ready to play is not a picture yet")

            page.sessions[0].report(.firstFrame)
            settle(host)
            #expect(page.video.loadPhase == .ready)
            #expect(page.video.hasShownFrame)
            #expect(!poster.isMounted, "the placeholder is taken out once the picture shows")
            host.detach()
        }

        @Test func soundIsOffAndTheSettingsGoToTheSession() {
            let page = Page(source: .url(clip))
            page.video.volume = 3
            page.video.isLooping = true
            let host = shown(page)
            page.video.play()
            let calls = page.sessions[0].calls
            #expect(calls.contains("muted true"))
            #expect(calls.contains("volume 1.0"), "cut to 1")
            #expect(calls.contains("loop true"))

            page.video.isMuted = false
            page.video.volume = 0.25
            #expect(page.sessions[0].calls.suffix(2) == ["muted false", "volume 0.25"])
            host.detach()
        }

        @Test func autoplayStartsWhenTheVideoIsInSightAndNotBefore() {
            let page = Page(source: nil)
            page.spacer.value = 1000
            page.video.autoplay = true
            page.video.source = .url(clip)
            let host = shown(page)
            #expect(!page.video.isOnScreen)
            #expect(page.sessions.isEmpty, "out of sight: nothing is read")

            page.spacer.value = 0
            settle(host)
            #expect(page.video.isOnScreen)
            #expect(page.sessions.count == 1)
            #expect(page.sessions[0].calls.contains("play"))
            host.detach()
        }

        @Test func goingOutOfSightPausesAndComingBackPlaysAgain() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            page.sessions[0].report(.firstFrame)

            page.spacer.value = 1000
            settle(host)
            #expect(page.sessions.count == 1)
            #expect(page.sessions[0].calls.last == "pause")
            #expect(!page.sessions[0].isStopped, "out of sight only pauses")
            #expect(page.video.wantsToPlay)

            page.spacer.value = 0
            settle(host)
            #expect(page.sessions[0].calls.last == "play")
            host.detach()
        }

        @Test func aPauseTheAppAskedForStaysWhenTheVideoComesBack() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            page.video.pause()
            #expect(!page.video.wantsToPlay)
            #expect(page.sessions[0].calls.last == "pause")

            page.spacer.value = 1000
            settle(host)
            page.spacer.value = 0
            settle(host)
            #expect(page.sessions[0].calls.last == "pause", "it does not start by itself")
            host.detach()
        }

        @Test func aTreeThatStopsShowingLetsTheSessionGoAndPlaysAgainFromWhereItWas() {
            let poster = Poster()
            let page = Page(source: .url(clip), placeholder: poster)
            let host = shown(page)
            page.video.play()
            page.sessions[0].report(.ready(size: nil, duration: .seconds(10)))
            page.sessions[0].report(.firstFrame)
            page.sessions[0].seconds = 4.5
            settle(host)
            #expect(!poster.isMounted)

            host.isShown = false
            settle(host)
            #expect(page.sessions[0].isStopped)
            #expect(page.video.loadPhase == .idle)
            #expect(!page.video.hasShownFrame)
            #expect(page.video.wantsToPlay, "the intent stays")

            host.isShown = true
            settle(host)
            #expect(page.sessions.count == 2)
            #expect(poster.isMounted, "the placeholder is back until a new picture")
            page.sessions[1].report(.ready(size: nil, duration: .seconds(10)))
            #expect(page.sessions[1].calls.contains("seek 4.5"))
            host.detach()
        }

        @Test func anotherSourceStopsTheOldSessionAndItsLateReportsAreIgnored() {
            let poster = Poster()
            let page = Page(source: .url(clip), placeholder: poster)
            let host = shown(page)
            page.video.play()
            page.sessions[0].report(.firstFrame)
            settle(host)
            #expect(page.video.hasShownFrame)

            let other = URL(string: "file:///tmp/other.mp4")!
            page.video.source = .url(other)
            settle(host)
            #expect(page.sessions[0].isStopped)
            #expect(!page.video.hasShownFrame, "the old picture does not show under the new source")
            #expect(page.video.loadPhase == .idle)
            #expect(poster.isMounted)

            // The old session was slow: what it says now is not the new source's.
            page.sessions[0].report(.firstFrame)
            page.sessions[0].report(.failed(.unreadable))
            #expect(!page.video.hasShownFrame)
            #expect(page.video.loadPhase == .idle)

            page.video.source = nil
            #expect(page.video.loadPhase == .empty)
            host.detach()
        }

        @Test func aFailureShowsTheMessageAndRetryStartsAgain() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            page.sessions[0].report(.failed(.network(.notConnectedToInternet)))
            settle(host)
            #expect(page.video.loadPhase == .failed(.network(.notConnectedToInternet)))
            #expect(page.sessions[0].isStopped)
            #expect(!page.video.wantsToPlay)

            page.video.play()
            #expect(page.sessions.count == 1, "play does not get past a failure")
            page.video.retry()
            settle(host)
            #expect(page.sessions.count == 2)
            #expect(page.video.loadPhase == .loading)
            #expect(page.sessions[1].calls.contains("play"))
            host.detach()
        }

        @Test func anAddressThePlayerDoesNotOpenIsAFailureAtOnce() {
            let page = Page(source: .url(URL(string: "ftp://example.com/a.mp4")!))
            let host = shown(page)
            page.video.play()
            #expect(page.video.loadPhase == .failed(.unsupportedSource))
            #expect(page.sessions.isEmpty)
            host.detach()
        }

        @Test func aPictureThatDoesNotComeInTimeIsATimeout() async throws {
            let page = Page(source: .url(clip))
            page.video.prepareTimeout = .milliseconds(30)
            let host = shown(page)
            page.video.play()
            #expect(page.video.loadPhase == .loading)
            try await Task.sleep(for: .milliseconds(200))
            #expect(page.video.loadPhase == .failed(.timeout))

            // A picture that came in time is not timed out later.
            let quick = Page(source: .url(clip))
            quick.video.prepareTimeout = .milliseconds(30)
            let quickHost = shown(quick)
            quick.video.play()
            quick.sessions[0].report(.firstFrame)
            try await Task.sleep(for: .milliseconds(200))
            #expect(quick.video.loadPhase == .ready)
            host.detach()
            quickHost.detach()
        }

        @Test func theEndStopsTheIntentToPlayAndPlayGoesOnFromIt() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            page.sessions[0].report(.firstFrame)
            page.sessions[0].report(.playback(.playing))
            #expect(page.video.playback == .playing)

            page.sessions[0].report(.playback(.ended))
            #expect(page.video.playback == .ended)
            #expect(!page.video.wantsToPlay)
            #expect(page.video.hasShownFrame, "the last picture stays")

            page.video.play()
            #expect(page.sessions[0].calls.last == "play")
            host.detach()
        }

        @Test func theNodeFollowsTheVideosProportionsOnlyWhenItIsToldTo() {
            let fixed = Page(source: .url(clip))
            let fixedHost = shown(fixed)
            fixed.video.play()
            fixed.sessions[0].report(
                .ready(size: LayoutSize(width: 200, height: 400), duration: .unknown)
            )
            settle(fixedHost)
            #expect(
                abs(fixed.video.frame.size.width / fixed.video.frame.size.height - 16.0 / 9.0)
                    < 0.01
            )

            let following = Page(source: .url(clip))
            following.video.aspectRatio = nil
            let followingHost = shown(following)
            following.video.play()
            following.sessions[0].report(
                .ready(size: LayoutSize(width: 200, height: 400), duration: .unknown)
            )
            settle(followingHost)
            #expect(
                abs(following.video.frame.size.width / following.video.frame.size.height - 0.5)
                    < 0.01
            )
            fixedHost.detach()
            followingHost.detach()
        }

        @Test func contentModeSetsTheGravityOfTheSurface() {
            let page = Page(source: .url(clip))
            #expect(page.video.surface.videoGravity == .resizeAspect)
            page.video.contentMode = .fill
            #expect(page.video.surface.videoGravity == .resizeAspectFill)
        }

        @Test func theVideoOffersPlayAndPauseToAssistiveTechnologies() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            #expect(page.video.accessibilityActions.map(\.name) == ["Play"])
            _ = page.video.accessibilityActions[0].perform()
            #expect(page.video.wantsToPlay)
            #expect(page.video.accessibilityActions.map(\.name) == ["Pause"])
            _ = page.video.accessibilityActions[0].perform()
            #expect(!page.video.wantsToPlay)

            page.video.pause()
            page.video.play()
            page.sessions[0].report(.failed(.file))
            #expect(page.video.accessibilityActions.map(\.name) == ["Retry"])
            #expect(page.video.accessibility.value == "Failed. The video file could not be read.")
            _ = page.video.accessibilityActions[0].perform()
            #expect(page.video.loadPhase == .loading, "the action retries")

            page.video.source = nil
            #expect(page.video.accessibilityActions.isEmpty)
            host.detach()
        }

        @Test func theVideoAndItsPictureFollowTheSizeOfTheHost() {
            let poster = Poster()
            let page = Page(source: .url(clip), placeholder: poster)
            let host = shown(page)
            let renderer = LayerRenderer()
            let container = CALayer()
            renderer.render(page, in: container)

            func check(_ width: Double, _ label: String) {
                host.size = LayoutSize(width: width, height: 600)
                settle(host)
                renderer.render(page, in: container)
                let frame = page.video.frame
                #expect(abs(frame.size.width - width) < 0.5, "\(label): as wide as the host")
                // Frames are rounded to whole points: the height is within one of the ratio's.
                #expect(abs(frame.size.height - width * 9 / 16) <= 1, Comment(rawValue: label))
                #expect(
                    page.video.surface.frame
                        == CGRect(x: 0, y: 0, width: frame.size.width, height: frame.size.height),
                    "\(label): the picture fills the node"
                )
                #expect(
                    abs(poster.frame.size.width - frame.size.width) < 0.5
                        && abs(poster.frame.size.height - frame.size.height) < 0.5,
                    "\(label): the placeholder fills it too"
                )
            }
            check(300, "300")
            check(800, "wide")
            check(120, "narrow")
            host.detach()
        }

        // MARK: Seek

        @Test func aPlaceKeptBeforeTheVideoIsReadIsGoneToWhenItIs() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            settle(host)

            page.video.seek(toSeconds: 5)
            #expect(
                !page.sessions[0].calls.contains { $0.hasPrefix("seek") },
                "nothing to seek yet"
            )
            #expect(page.video.currentSeconds == 5, "the place is kept")

            page.sessions[0].report(.ready(size: nil, duration: .seconds(10)))
            #expect(page.sessions[0].calls.contains("seek 5.0"))
            host.detach()
        }

        @Test func aSeekIsCutToTheVideoAndNotBelowTheStart() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            settle(host)
            page.sessions[0].report(.ready(size: nil, duration: .seconds(10)))

            page.video.seek(toSeconds: 99)
            page.video.seek(toSeconds: -3)
            page.video.seek(toSeconds: 4)

            let seeks = page.sessions[0].calls.filter { $0.hasPrefix("seek") }
            #expect(seeks == ["seek 10.0", "seek 0.0", "seek 4.0"])
            host.detach()
        }

        @Test func aPlaceKeptWithoutASessionIsWhereTheVideoGoesOnWhenItIsReadAgain() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            #expect(page.video.currentSeconds == nil, "before anything is read there is no place")

            page.video.seek(toSeconds: 7)
            #expect(page.sessions.isEmpty, "a seek reads nothing")
            #expect(page.video.currentSeconds == 7)

            page.video.play()
            settle(host)
            page.sessions[0].report(.ready(size: nil, duration: .seconds(30)))
            #expect(page.sessions[0].calls.contains("seek 7.0"))
            host.detach()
        }

        @Test func aLiveVideoHasNoPlacesAndAFailedOneIsNotSeeked() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            settle(host)
            page.sessions[0].report(.ready(size: nil, duration: .live))
            page.video.seek(toSeconds: 5)
            #expect(!page.sessions[0].calls.contains { $0.hasPrefix("seek") })
            #expect(page.video.currentSeconds == nil)

            page.sessions[0].report(.failed(.other))
            page.video.seek(toSeconds: 5)
            #expect(page.video.currentSeconds == nil, "a failed video keeps no place")
            host.detach()
        }

        @Test func aSeekAfterTheEndIsNotUndoneByPlay() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            settle(host)
            page.sessions[0].report(.ready(size: nil, duration: .seconds(10)))
            page.sessions[0].report(.playback(.ended))
            #expect(page.video.playback == .ended)

            page.video.seek(toSeconds: 3)

            #expect(page.sessions[0].calls.contains("seek 3.0"))
            host.detach()
        }

        // MARK: Placeholder leaving

        @Test func thePlaceholderLeavesWithTheThemesMoveAndAtOnceWhereMotionIsReduced() {
            for reduced in [false, true] {
                let page = Page(source: .url(clip), placeholder: Poster())
                let host = shown(page)
                host.conditions = DisplayConditions(reducesMotion: reduced)
                page.video.play()
                settle(host)
                #expect(page.video.lastRevealAnimation == nil, "no picture yet")

                page.sessions[0].report(.firstFrame)

                // What the node used when the picture came, not only what the theme would say.
                let expected: Animation? = reduced ? nil : .easeInOut(duration: 0.25)
                #expect(page.video.lastRevealAnimation == .some(expected), "reduced: \(reduced)")
                host.detach()
            }
        }

        @Test func aRouteThatWentAwayLeavesTheVideoPausedUntilAskedAgain() {
            let page = Page(source: .url(clip))
            let host = shown(page)
            page.video.play()
            settle(host)
            #expect(page.video.wantsToPlay)

            page.sessions[0].report(.stoppedByRoute)

            #expect(!page.video.wantsToPlay, "it does not start playing out loud on its own")
            page.video.play()
            #expect(page.video.wantsToPlay)
            host.detach()
        }

        // MARK: Preload and the budget

        @Test func aPreparedVideoShowsItsFirstPictureWithoutAskingToPlayAndPlaysAtOnce() {
            let poster = Poster()
            let page = Page(source: .url(clip), placeholder: poster)
            page.video.preload = .automatic
            let host = shown(page)

            #expect(page.sessions.count == 1, "the picture is prepared before play is asked")
            #expect(!page.sessions[0].calls.contains("play"))
            #expect(page.video.loadPhase == .idle, "preparing is not loading: nobody asked")
            page.sessions[0].report(
                .ready(size: LayoutSize(width: 320, height: 240), duration: .seconds(5))
            )
            page.sessions[0].report(.firstFrame)
            settle(host)
            #expect(page.video.hasShownFrame)
            #expect(page.video.loadPhase == .ready)
            #expect(!poster.isMounted, "the picture is there, so the placeholder is gone")

            page.video.play()
            settle(host)
            #expect(page.sessions.count == 1, "play uses the session that was prepared")
            #expect(page.sessions[0].calls.contains("play"))
            host.detach()
        }

        @Test func playAskedWhilePreparingStartsTheSpinnerAndTheTimeout() async throws {
            let page = Page(source: .url(clip))
            page.video.preload = .automatic
            page.video.prepareTimeout = .milliseconds(100)
            let host = shown(page)
            #expect(page.sessions.count == 1)

            // Preparing never times out: nobody is waiting.
            try await Task.sleep(for: .milliseconds(250))
            #expect(page.video.loadPhase == .idle)

            page.video.play()
            settle(host)
            #expect(page.video.loadPhase == .loading)
            try await Task.sleep(for: .milliseconds(250))
            #expect(page.video.loadPhase == .failed(.timeout), "the timeout runs from the ask")
            host.detach()
        }

        @Test func aFailureOfPreparationIsQuietAndShowsWhenPlayIsAskedFor() {
            let page = Page(source: .url(clip))
            page.video.preload = .automatic
            let host = shown(page)
            #expect(page.sessions.count == 1)

            page.sessions[0].report(.failed(.network(.notConnectedToInternet)))
            settle(host)

            #expect(page.video.loadPhase == .idle, "nobody asked, so nothing is shown")
            #expect(page.sessions[0].isStopped)
            #expect(page.sessions.count == 1, "it is not prepared again and again")

            page.video.play()
            settle(host)
            #expect(page.sessions.count == 2, "asking tries for real")
            guard page.sessions.count == 2 else { return }

            page.sessions[1].report(.failed(.network(.notConnectedToInternet)))
            #expect(page.video.loadPhase == .failed(.network(.notConnectedToInternet)))
            host.detach()
        }

        @Test func theBudgetLimitsPreparationAndANeighbourWaitsForARoom() {
            let budget = VideoPreparationBudget(limit: 2)
            let feed = Feed(count: 3, budget: budget)
            let host = shown(feed)
            prepare([0, 1, 2], of: feed, in: host)

            #expect(feed.live(0).count == 1 && feed.live(1).count == 1)
            #expect(feed.live(2).isEmpty, "the third does not fit")
            #expect(budget.occupied == 2)

            // The first goes away; its room goes to the one that waited.
            feed.videos[0].source = nil
            settle(host)
            #expect(feed.live(0).isEmpty)
            #expect(feed.live(2).count == 1, "the waiting neighbour is prepared")
            #expect(budget.occupied == 2)
            host.detach()
        }

        @Test func aVideoAskedToPlayTakesTheRoomOfTheOldestPreparation() {
            let budget = VideoPreparationBudget(limit: 2)
            let feed = Feed(count: 3, budget: budget, gap: 0)
            let host = shown(feed)
            prepare([1, 2], of: feed, in: host)
            #expect(feed.prepared == [1, 2])

            // The first video is in the window: asked to play, it gets its room at the cost of
            // the oldest preparation, which is the second video's.
            feed.videos[0].play()
            settle(host)

            #expect(feed.live(0).count == 1, "play gets its session")
            #expect(feed.live(1).isEmpty, "the oldest preparation was let go")
            #expect(feed.live(2).count == 1, "the newer one stays")
            host.detach()
        }

        @Test func videosThatPlayAreNeverLetGoToMakeRoom() {
            let budget = VideoPreparationBudget(limit: 1)
            let feed = Feed(count: 2, budget: budget, gap: 0)
            let host = shown(feed)
            feed.videos[0].play()
            settle(host)
            #expect(feed.live(0).count == 1)

            // The second is in the window too and is asked to play, beyond the limit.
            feed.videos[1].play()
            settle(host)

            #expect(feed.live(0).count == 1, "a playing video is not dropped for another")
            #expect(feed.live(1).count == 1, "and the one asked to play is not refused")
            #expect(!feed.sessions[0][0].isStopped)
            host.detach()
        }

        @Test func aVideoThatIsOnlyPreparedNeverTakesARoomFromAnother() {
            let budget = VideoPreparationBudget(limit: 1)
            let feed = Feed(count: 2, budget: budget)
            let host = shown(feed)
            prepare([0, 1], of: feed, in: host)

            #expect(feed.live(0).count == 1)
            #expect(feed.live(1).isEmpty, "preparation does not push another out")
            host.detach()
        }

        @Test func aBudgetOfZeroPreparesNothingAndPlayingStillWorks() {
            let feed = Feed(count: 1, budget: VideoPreparationBudget(limit: 0), preload: .automatic)
            let host = shown(feed)
            #expect(feed.live(0).isEmpty)

            feed.videos[0].play()
            settle(host)

            #expect(feed.live(0).count == 1)
            host.detach()
        }

        @Test func leavingTheTreeOrNotShowingLetsThePreparationGo() {
            let budget = VideoPreparationBudget(limit: 2)
            let feed = Feed(count: 1, budget: budget, preload: .automatic)
            let host = shown(feed)
            #expect(feed.live(0).count == 1 && budget.occupied == 1)

            host.isShown = false
            settle(host)
            #expect(feed.live(0).isEmpty, "a tree that does not show prepares nothing")
            #expect(budget.occupied == 0)

            host.isShown = true
            settle(host)
            #expect(feed.live(0).count == 1, "it is prepared again when the tree shows")

            host.detach()
            #expect(feed.live(0).isEmpty)
            #expect(budget.occupied == 0)
        }

        @Test func settingPreloadBackToNoneLetsGoOfWhatWasPrepared() {
            let budget = VideoPreparationBudget(limit: 2)
            let feed = Feed(count: 1, budget: budget, preload: .automatic)
            let host = shown(feed)
            #expect(feed.live(0).count == 1)

            feed.videos[0].preload = .none
            settle(host)

            #expect(feed.live(0).isEmpty)
            #expect(budget.occupied == 0)
            host.detach()
        }

        @Test func aVideoThatWasPausedMayBeLetGoForAnotherThatPlays() {
            let budget = VideoPreparationBudget(limit: 1)
            let feed = Feed(count: 2, budget: budget, gap: 0)
            let host = shown(feed)
            feed.videos[0].play()
            settle(host)
            feed.videos[0].pause()
            settle(host)

            // Paused, it holds a room that may be taken: the second video's play takes it.
            feed.videos[1].play()
            settle(host)

            #expect(feed.live(1).count == 1)
            #expect(feed.live(0).isEmpty, "the paused one gave way")
            host.detach()
        }

        @Test func metadataGivesTheSizeAndLengthBeforePlayWithoutASession() async {
            let budget = VideoPreparationBudget(limit: 2)
            let feed = Feed(count: 1, budget: budget, preload: .metadata)
            let host = shown(feed)

            for _ in 0..<200 where feed.videos[0].naturalSize == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }

            #expect(feed.videos[0].naturalSize == LayoutSize(width: 640, height: 360))
            #expect(feed.videos[0].duration == .seconds(12))
            #expect(feed.sessions[0].isEmpty, "no player is made for a description")
            #expect(feed.metadataReads.count == 1)
            #expect(budget.occupied == 0, "the room is given back when the read is done")
            #expect(feed.videos[0].loadPhase == .idle)
            host.detach()
        }

        @Test func metadataIsNotReadTwiceNorForAVideoOutOfTheTree() async {
            let feed = Feed(count: 1, budget: VideoPreparationBudget(limit: 2), preload: .metadata)
            let host = shown(feed)
            for _ in 0..<200 where feed.videos[0].naturalSize == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            host.isShown = false
            settle(host)
            host.isShown = true
            settle(host)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(feed.metadataReads.count == 1, "what is known is not read again")

            feed.videos[0].source = .url(URL(string: "file:///tmp/other.mp4")!)
            settle(host)
            for _ in 0..<200 where feed.metadataReads.count < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(feed.metadataReads.count == 2, "another source is another video")
            host.detach()
        }

        @Test func thePlaceholderIsDrawnOverThePicture() {
            let poster = Poster()
            let page = Page(source: .url(clip), placeholder: poster)
            let host = shown(page)
            let renderer = LayerRenderer()
            renderer.render(page, in: CALayer())

            let layer = renderer.layer(for: page.video)
            let posterLayer = renderer.layer(for: poster)
            #expect(layer?.sublayers?.first === page.video.surface)
            #expect(posterLayer?.superlayer === layer, "the placeholder is a subnode's layer")
            #expect(layer?.sublayers?.contains { $0 === posterLayer } == true)
            #expect(
                (layer?.sublayers?.firstIndex { $0 === posterLayer } ?? 0)
                    > (layer?.sublayers?.firstIndex { $0 === page.video.surface } ?? 1)
            )
            host.detach()
        }
    }
#endif

#if canImport(AVFoundation) && canImport(QuartzCore)
    /// The player's own session and a video the player really plays.
    @Suite(.serialized) @MainActor struct VideoPlaybackTests {
        /// Waits, on the main actor, until `condition` holds or `seconds` pass.
        private func wait(
            _ seconds: Double = 10,
            until condition: @MainActor () -> Bool
        ) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        /// A window that holds `layer` in its layers, the way the picture of a video is in a
        /// window: on iOS a player layer shows no picture that is not in one.
        private func window(holding layer: CALayer) -> AnyObject {
            #if canImport(UIKit)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
                window.isHidden = false
                window.layer.addSublayer(layer)
                return window
            #else
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.isReleasedWhenClosed = false
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.addSublayer(layer)
                return window
            #endif
        }

        @Test func aLocalVideoReadsShowsItsFirstPictureAndPlaysToTheEnd() async throws {
            let url = try await VideoFixture.make(seconds: 1)
            defer { try? FileManager.default.removeItem(at: url) }
            let surface = AVPlayerLayer()
            surface.frame = CGRect(x: 0, y: 0, width: 128, height: 96)
            let window = window(holding: surface)
            defer { withExtendedLifetime(window) {} }
            var events: [VideoSessionEvent] = []
            let session = AVVideoSession(url: url, surface: surface) { events.append($0) }
            defer { session.stop() }

            #expect(
                await wait {
                    events.contains(.firstFrame)
                        || events.contains { if case .failed = $0 { true } else { false } }
                }
            )
            #expect(events.contains(.firstFrame), "events: \(events)")
            let ready = events.compactMap { event -> (LayoutSize?, VideoDuration)? in
                if case .ready(let size, let duration) = event { return (size, duration) }
                return nil
            }
            #expect(ready.last?.0 == LayoutSize(width: 64, height: 48))
            if case .seconds(let length)? = ready.last?.1 {
                #expect(abs(length - 1) < 0.3)
            } else {
                Issue.record("duration: \(String(describing: ready.last?.1))")
            }

            session.play()
            #expect(await wait { events.contains(.playback(.playing)) }, "events: \(events)")
            #expect(await wait { events.contains(.playback(.ended)) }, "events: \(events)")
            #expect((session.currentSeconds ?? 0) > 0.5)
        }

        @Test func aFileThatIsNotThereIsAFailureOfTheFile() async {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "missing-\(UUID()).mp4"
            )
            let surface = AVPlayerLayer()
            var events: [VideoSessionEvent] = []
            let session = AVVideoSession(url: url, surface: surface) { events.append($0) }
            defer { session.stop() }

            #expect(await wait { events.contains { if case .failed = $0 { true } else { false } } })
            #expect(events.contains(.failed(.file)), "events: \(events)")
        }

        @Test func bytesThatAreNotAVideoAreUnreadable() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "junk-\(UUID()).mp4"
            )
            try Data("not a video".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            var events: [VideoSessionEvent] = []
            let session = AVVideoSession(url: url, surface: AVPlayerLayer()) { events.append($0) }
            defer { session.stop() }

            #expect(await wait { events.contains { if case .failed = $0 { true } else { false } } })
            #expect(events.contains(.failed(.unreadable)), "events: \(events)")
        }

        @Test func aLoopingVideoStartsAgainAtTheEndAndPauseHoldsThePicture() async throws {
            let url = try await VideoFixture.make(seconds: 1)
            defer { try? FileManager.default.removeItem(at: url) }
            var events: [VideoSessionEvent] = []
            let surface = AVPlayerLayer()
            surface.frame = CGRect(x: 0, y: 0, width: 128, height: 96)
            let window = window(holding: surface)
            defer { withExtendedLifetime(window) {} }
            let session = AVVideoSession(url: url, surface: surface) { events.append($0) }
            defer { session.stop() }
            session.setLooping(true)
            session.play()
            #expect(await wait { events.contains(.playback(.playing)) })
            try await Task.sleep(for: .milliseconds(1800))
            #expect(!events.contains(.playback(.ended)), "a loop never ends: \(events)")
            let playback = events.compactMap { event -> VideoPlaybackState? in
                if case .playback(let state) = event { return state }
                return nil
            }
            #expect(playback.last == .playing, "still playing: \(events)")
            // Two and a half plays of a second: the playhead went back to the start.
            #expect((session.currentSeconds ?? 9) < 1.05)

            session.pause()
            #expect(await wait { events.last == .playback(.paused) }, "events: \(events)")
            let held = session.currentSeconds
            try await Task.sleep(for: .milliseconds(300))
            #expect(session.currentSeconds == held)
        }

        @Test func aSeekPutsTheRealPlayheadThereAndPlayGoesOnFromIt() async throws {
            let url = try await VideoFixture.make(seconds: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let surface = AVPlayerLayer()
            surface.frame = CGRect(x: 0, y: 0, width: 128, height: 96)
            let window = window(holding: surface)
            defer { withExtendedLifetime(window) {} }
            var events: [VideoSessionEvent] = []
            let session = AVVideoSession(url: url, surface: surface) { events.append($0) }
            defer { session.stop() }
            #expect(await wait { events.contains(.firstFrame) }, "events: \(events)")

            session.seek(toSeconds: 1.2)
            #expect(await wait { abs((session.currentSeconds ?? 0) - 1.2) < 0.15 })

            // Played to the end, then moved back: play goes on from there and not from the start.
            session.play()
            #expect(await wait { events.contains(.playback(.ended)) }, "events: \(events)")
            session.seek(toSeconds: 1.0)
            #expect(await wait { events.last == .playback(.paused) }, "events: \(events.suffix(3))")
            session.play()
            #expect(
                await wait { events.last == .playback(.playing) },
                "events: \(events.suffix(3))"
            )
            #expect((session.currentSeconds ?? 0) >= 0.9, "it went back to the start")
        }

        #if canImport(UIKit)
            @Test func aCallPausesThePlayerAndItsEndPlaysAgainOnlyIfTheSystemSaysSo() async throws {
                let url = try await VideoFixture.make(seconds: 3)
                defer { try? FileManager.default.removeItem(at: url) }
                let surface = AVPlayerLayer()
                surface.frame = CGRect(x: 0, y: 0, width: 128, height: 96)
                let window = window(holding: surface)
                defer { withExtendedLifetime(window) {} }
                var events: [VideoSessionEvent] = []
                let session = AVVideoSession(url: url, surface: surface) { events.append($0) }
                defer { session.stop() }
                #expect(await wait { events.contains(.firstFrame) }, "events: \(events)")
                session.play()
                #expect(await wait { events.last == .playback(.playing) }, "events: \(events)")

                post(
                    AVAudioSession.interruptionNotification,
                    [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began
                            .rawValue
                    ]
                )
                #expect(
                    await wait { events.last == .playback(.paused) },
                    "events: \(events.suffix(3))"
                )

                // The video asks to play again while the call goes on: the system has the sound.
                session.play()
                try await Task.sleep(for: .milliseconds(300))
                #expect(events.last == .playback(.paused), "it played during the interruption")

                // The call ends and the system says not to resume: it stays paused.
                post(
                    AVAudioSession.interruptionNotification,
                    [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended
                            .rawValue,
                        AVAudioSessionInterruptionOptionKey: 0,
                    ]
                )
                try await Task.sleep(for: .milliseconds(300))
                #expect(events.last == .playback(.paused))

                // A second call, and this time the system says to resume.
                post(
                    AVAudioSession.interruptionNotification,
                    [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began
                            .rawValue
                    ]
                )
                post(
                    AVAudioSession.interruptionNotification,
                    [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended
                            .rawValue,
                        AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions
                            .shouldResume
                            .rawValue,
                    ]
                )
                #expect(
                    await wait { events.last == .playback(.playing) },
                    "events: \(events.suffix(3))"
                )
            }

            @Test func aRouteThatLeavesPausesAndOneThatArrivesDoesNot() async throws {
                let url = try await VideoFixture.make(seconds: 3)
                defer { try? FileManager.default.removeItem(at: url) }
                let surface = AVPlayerLayer()
                surface.frame = CGRect(x: 0, y: 0, width: 128, height: 96)
                let window = window(holding: surface)
                defer { withExtendedLifetime(window) {} }
                var events: [VideoSessionEvent] = []
                let session = AVVideoSession(url: url, surface: surface) { events.append($0) }
                defer { session.stop() }
                #expect(await wait { events.contains(.firstFrame) }, "events: \(events)")
                session.play()
                #expect(await wait { events.last == .playback(.playing) }, "events: \(events)")

                post(
                    AVAudioSession.routeChangeNotification,
                    [
                        AVAudioSessionRouteChangeReasonKey:
                            AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                    ]
                )
                try await Task.sleep(for: .milliseconds(300))
                #expect(events.last == .playback(.playing), "a new route is not a reason to stop")

                post(
                    AVAudioSession.routeChangeNotification,
                    [
                        AVAudioSessionRouteChangeReasonKey:
                            AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    ]
                )
                #expect(
                    await wait { events.contains(.stoppedByRoute) },
                    "events: \(events.suffix(3))"
                )
                #expect(
                    await wait { events.last == .playback(.paused) }
                        || events.last == .stoppedByRoute
                )
            }

            private func post(_ name: Notification.Name, _ info: [String: UInt]) {
                NotificationCenter.default.post(name: name, object: nil, userInfo: info)
            }
        #endif

        @Test func theDescriptionOfAFileIsReadWithoutPlayingItAndAMissingOneThrows() async throws {
            let url = try await VideoFixture.make(seconds: 2, width: 64, height: 48)
            defer { try? FileManager.default.removeItem(at: url) }

            let metadata = try await AVVideoSession.readMetadata(of: url)

            #expect(metadata.size == LayoutSize(width: 64, height: 48))
            if case .seconds(let length) = metadata.duration {
                #expect(abs(length - 2) < 0.3)
            } else {
                Issue.record("duration: \(metadata.duration)")
            }

            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
                "gone-\(UUID()).mp4"
            )
            await #expect(throws: (any Error).self) {
                _ = try await AVVideoSession.readMetadata(of: missing)
            }
        }

        @Test func aVideoNodePlaysAFileThroughItsRealSession() async throws {
            let url = try await VideoFixture.make(seconds: 1)
            defer { try? FileManager.default.removeItem(at: url) }
            let root = Root(source: .url(url))
            #if canImport(UIKit)
                let view = NodeView(root: root)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
                view.frame = window.bounds
                window.addSubview(view)
                window.isHidden = false
                view.layoutIfNeeded()
                let host = view.host
            #else
                let view = NodeNSView(root: root)
                view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
                let window = NSWindow(
                    contentRect: view.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                view.layout()
                let host = view.host
            #endif
            defer { withExtendedLifetime(window) {} }

            #expect(await wait(2) { root.video.isOnScreen })
            root.video.play()
            #expect(await wait { root.video.hasShownFrame })
            #expect(root.video.loadPhase == .ready)
            #expect(root.video.naturalSize == LayoutSize(width: 64, height: 48))
            #expect(await wait { root.video.playback == .playing })
            #expect(await wait { root.video.playback == .ended })
            #expect(!root.video.wantsToPlay)
            host.detach()
            #expect(root.video.session == nil, "leaving the tree lets the session go")
        }

        @MainActor
        private final class Root: Node {
            let video: Video
            init(source: VideoSource) {
                video = Video(source: source)
                super.init()
            }
            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) { video }.alignItems(.stretch)
            }
        }
    }
#endif
