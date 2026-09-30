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
