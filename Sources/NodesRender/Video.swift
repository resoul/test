#if canImport(AVFoundation) && canImport(QuartzCore)
    import AVFoundation
    import Foundation
    import LayoutCore
    import Nodes
    import QuartzCore
    import StateCore
    import ThemeCore

    /// A video in the tree: a picture of a file or of a video on the web, laid out and cut like
    /// any node, with a node of the app's own standing over it until the first picture comes.
    ///
    ///     let video = Video(source: .url(url))
    ///     video.placeholder = PosterNode()      // an Image, a skeleton, a caption…
    ///     video.play()
    ///
    /// Nothing is read until playback is asked for — by `play()`, or by `autoplay` once the
    /// video is in sight. Asking starts a session of playback that holds the player; the
    /// session is let go when the video leaves the tree, its tree stops showing, it gets
    /// another source or it fails. While the video is out of sight, or its tree is not showing,
    /// it is paused and resumes when it is back if it was playing: a pause the app asked for
    /// stays.
    ///
    /// The picture is a layer of the node's own (`LayerHosting`), so the placeholder, the
    /// spinner and the message of a failure are ordinary subnodes drawn over it, and the
    /// node's corner radius, clipping and opacity apply to the picture. The node has no
    /// controls: the app drives it through `play()`, `pause()` and the properties, and reads
    /// what it does from the observable state (`loadPhase`, `playback`, `hasShownFrame`,
    /// `naturalSize`, `duration`).
    ///
    /// Sound is off until `isMuted` says otherwise, and the node does not touch the app's
    /// audio session.
    ///
    /// Ownership: the caller owns the node; the node owns the placeholder while it is set, and
    /// a placeholder can stand in one video only. Isolation: MainActor. Errors: reported as
    /// `loadPhase`, not thrown. Cancellation: a new source, leaving the tree and
    /// releasing the node stop what is under way; results of the session before are ignored.
    @MainActor
    public final class Video: Node, LayerHosting {
        // MARK: Configuration

        /// The video to show. Setting another one, or `nil`, stops the one before and brings
        /// the placeholder back; the picture of the old source never shows under the new
        /// one. The intent to play is reset to `autoplay`.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: replaces the
        /// session.
        public var source: VideoSource? {
            didSet { if source != oldValue { sourceChanged() } }
        }

        /// A node shown over the video until its first picture, and again for a new source
        /// or after the session was let go and not yet shown a picture again. It is mounted
        /// only while it shows: after the video appears it is taken out of the tree, so an
        /// animation of its own stops. `nil` shows the theme's background.
        ///
        /// A pause keeps the picture; the placeholder does not come back for it. Poster
        /// images load on their own (`Image`), and an error of theirs is not the video's.
        ///
        /// Ownership: the video keeps the node. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var placeholder: Node? {
            didSet { if placeholder !== oldValue { setNeedsLayout() } }
        }

        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var contentMode: VideoContentMode = .fit {
            didSet { if contentMode != oldValue { applyContentMode() } }
        }

        /// Whether playback is asked for by itself, once the video is in sight, for the source
        /// set after this. A video does not read anything before it is asked, and by default is
        /// not.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var autoplay = false

        /// Whether the sound is off. On by default.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isMuted = true {
            didSet { session?.setMuted(isMuted) }
        }

        /// The volume, from 0 to 1; values outside are cut to it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var volume = 1.0 {
            didSet { session?.setVolume(min(max(volume, 0), 1)) }
        }

        /// Whether the video starts again from the beginning when it ends.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var isLooping = false {
            didSet { session?.setLooping(isLooping) }
        }

        /// Width divided by height of the node, before the layout says otherwise: 16 by 9 by
        /// default, so that a feed does not jump when the video's description arrives.
        /// `nil` follows the video once its size is known (16 by 9 until then).
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var aspectRatio: Double? = 16.0 / 9.0 {
            didSet { if aspectRatio != oldValue { setNeedsLayout() } }
        }

        /// How long the first picture may take once playback is asked for, before the video
        /// fails with `VideoFailure.timeout`. Buffering after the first picture is not a
        /// failure.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var prepareTimeout: Duration = .seconds(30)

        /// How much is read before playback is asked for; ``VideoPreload/none`` by default, which
        /// reads nothing. See ``VideoPreload`` for what the other modes promise.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: setting it back to
        /// `.none` lets go of what was prepared.
        public var preload = VideoPreload.none {
            didSet { if preload != oldValue { reconcile() } }
        }

        /// The budget that limits how many videos are prepared or playing; the shared one unless the
        /// app gives its own.
        ///
        /// Ownership: the video keeps the budget. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var preparationBudget = VideoPreparationBudget.shared {
            didSet {
                guard preparationBudget !== oldValue else { return }

                oldValue.release(self)
                reconcile()
            }
        }

        // MARK: State

        /// How far the video is toward its first picture. Reading it under tracking depends on
        /// it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var loadPhase: VideoLoadPhase { loadPhaseState.value }

        /// What the picture is doing. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var playback: VideoPlaybackState { playbackState.value }

        /// Whether a picture of the current source is showing. It is `false` after the
        /// session was let go, and until a new one shows its picture. Reading it under
        /// tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var hasShownFrame: Bool { shownFrameState.value }

        /// The size of the picture as it shows, orientation applied, once the player has read
        /// the video's description; `nil` before. Reading it under tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var naturalSize: LayoutSize? { naturalSizeState.value }

        /// The length of the video, `.unknown` until the description is read. Reading it under
        /// tracking depends on it.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var duration: VideoDuration { durationState.value }

        /// Whether the app wants the video to play: after `play()` or with `autoplay`, until
        /// `pause()` or the end. The picture plays only while it is also in sight.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public private(set) var wantsToPlay = false

        // MARK: Commands

        /// Asks for playback: reads the video if that has not started, and plays while it is
        /// in sight. At the end, plays from the beginning. Does nothing after a failure —
        /// `retry()` is the way out of it — or without a source.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: reported as `loadPhase`.
        /// Cancellation: `pause()`.
        public func play() {
            guard source != nil, loadPhase.failure == nil else { return }

            wantsToPlay = true
            reconcile()
            refreshAccessibility()
        }

        /// Stops playing and keeps the picture and the position. Nothing is let go.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func pause() {
            wantsToPlay = false
            reconcile()
            refreshAccessibility()
        }

        /// Tries again after a failure: a new session, playing once the picture is there.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: reported as `loadPhase`.
        /// Cancellation: replaces the session.
        public func retry() {
            guard source != nil, loadPhase.failure != nil else { return }

            releaseSession()
            preparationFailed = false
            loadPhaseState.value = .idle
            wantsToPlay = true
            reconcile()
            refreshAccessibility()
        }

        /// Moves the playhead to `seconds`, cut to the video's length and not below the start. Playing
        /// goes on from there, and a paused video stays paused at the new place; after the end,
        /// `play()` plays from where the playhead was put, not from the beginning.
        ///
        /// Before the video has been read — or while its session is gone — the place is kept and
        /// the playhead goes there when the video is next read. A live video has no places:
        /// nothing happens. Nothing happens without a source or after a failure.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func seek(toSeconds seconds: Double) {
            guard source != nil, loadPhase.failure == nil else { return }

            var target = max(seconds, 0)
            switch duration {
            case .live: return
            case .seconds(let length): target = min(target, length)
            case .unknown: break
            }
            if let session, case .seconds = duration {
                resumeSeconds = nil
                session.seek(toSeconds: target)
            } else {
                resumeSeconds = target
            }
        }

        /// Where the playhead is, in seconds, or `nil` when there is none — before the video is
        /// read, for a live video. While the session is gone it is where the video will go on.
        /// It is a reading of the moment, not observable: sample it when it is needed.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public var currentSeconds: Double? {
            session?.currentSeconds ?? resumeSeconds
        }

        // MARK: Node

        /// Ownership: the node owns the layer. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public var hostedLayer: CALayer? { surface }

        /// The layer of the picture. It lives as long as the node; the sessions come and go
        /// under it.
        let surface = AVPlayerLayer()

        private let loadPhaseState = State(VideoLoadPhase.empty)
        private let playbackState = State(VideoPlaybackState.paused)
        private let shownFrameState = State(false)
        private let naturalSizeState = State<LayoutSize?>(nil)
        private let durationState = State(VideoDuration.unknown)

        /// Makes the session; the platform's player unless a test says otherwise.
        var makeSession: VideoSessionFactory = { url, surface, report in
            AVVideoSession(url: url, surface: surface, report: report)
        }

        /// Reads a video's description; the platform's unless a test says otherwise.
        var readMetadata: VideoMetadataReader = { url in
            try await AVVideoSession.readMetadata(of: url)
        }

        /// The session under way, if any.
        private(set) var session: (any VideoSession)?
        /// The session was made to prepare the picture and nobody has asked to play it: no
        /// spinner, no timeout, and a failure is not shown.
        private var holdsPreparation = false
        /// Preparation failed once; it is not tried again until the source changes or play asks.
        private var preparationFailed = false
        private var metadataTask: Task<Void, Never>?
        private var metadataToken = 0
        private var hasMetadata = false
        /// Tells the reports of the session in force from those of the ones before.
        private var sessionToken = 0
        private var timeoutTask: Task<Void, Never>?
        /// Where the playhead was when the last session was let go, to go back to when the next
        /// one has read the video.
        private var resumeSeconds: Double?

        private let spinner = RefreshSpinner(color: Color(red: 1, green: 1, blue: 1))
        private lazy var failureView = VideoFailureView { [weak self] in self?.retry() }

        /// Ownership: the caller owns the node. Isolation: MainActor. Errors: none.
        /// Cancellation: the session stops when the node is released.
        public init(source: VideoSource? = nil) {
            self.source = source
            super.init()
            tracksScreen = true
            appearance.background = Color(red: 0, green: 0, blue: 0)
            surface.videoGravity = .resizeAspect
            surface.masksToBounds = true
            accessibility.isElement = true
            accessibility.label = "Video"
            spinner.showRefresh(pull: 1, isRefreshing: true)
            if source != nil { loadPhaseState.value = .idle }
            refreshAccessibility()
        }

        deinit {
            timeoutTask?.cancel()
        }

        /// The frame: the placeholder over the picture, the spinner while the picture is
        /// awaited, and the message of a failure — all pinned to the node's box.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override func layoutSpec() -> LayoutSpec? {
            let ratio =
                aspectRatio ?? naturalSize.flatMap { size -> Double? in
                    size.height > 0 ? size.width / size.height : nil
                } ?? (16.0 / 9.0)
            let showsPlaceholder = !hasShownFrame
            let phase = loadPhase
            return FlexContainer {
                if showsPlaceholder, let placeholder {
                    placeholder.absolute(top: 0, leading: 0, bottom: 0, trailing: 0)
                }
                if phase == .loading {
                    spinner.size(32).absolute(top: 0, leading: 0, bottom: 0, trailing: 0)
                }
                if phase.failure != nil {
                    failureView.absolute(top: 0, leading: 0, bottom: 0, trailing: 0)
                }
            }
            .aspectRatio(ratio)
        }

        /// The layer's pictures are shown from where a video is in sight, and playback follows.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public override func screenChanged(_ isOnScreen: Bool) {
            reconcile()
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: leaving the tree
        /// lets the session go.
        public override func mountedChanged(_ isMounted: Bool) {
            reconcile()
        }

        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: a tree that no
        /// longer shows lets the session go.
        public override func shownChanged(_ isShown: Bool) {
            reconcile()
        }

        /// A video is not made ready for a window nobody can see; coming back prepares it again.
        /// Playing is not touched: the system pauses what it must, and whether sound goes on in
        /// the background is the app's audio policy.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: preparation is
        /// let go in the background.
        public override func backgroundChanged(_ isInBackground: Bool) {
            reconcile()
        }

        private var isInBackground: Bool { host?.isInBackground ?? false }

        // MARK: Playback

        /// Whether the picture can play now.
        private var isRunnable: Bool {
            source != nil && isMounted && isShown && isOnScreen
        }

        /// Brings the session in line with what is asked and what is in sight: starts one when
        /// playback is asked for and the video shows, pauses one while it does not, lets one go
        /// when the video is out of the tree or its tree does not show, and — if the video wants
        /// preparing and the budget has room — prepares it before it is asked.
        private func reconcile() {
            guard let source else { return }

            if loadPhase.failure == nil, wantsToPlay, isRunnable {
                preparationBudget.claimForPlay(self)
                cancelMetadata()
                if session == nil {
                    startSession(for: source, preparing: false)
                } else if holdsPreparation {
                    becomeAsked()
                }
                session?.play()
            } else if let session {
                session.pause()
                let keepsPreparing = holdsPreparation && wantsPreparedPicture
                if !isMounted || !isShown || (holdsPreparation && !keepsPreparing) {
                    releaseSession()
                    if loadPhase.failure == nil { loadPhaseState.value = .idle }
                } else {
                    // A video that is not playing may be let go for one that is.
                    preparationBudget.setActive(self, wantsToPlay)
                }
            } else {
                prepareIfWanted(source)
            }
        }

        /// Whether the picture should be made ready before play: asked for, and the video is in the
        /// tree and showing.
        private var wantsPreparedPicture: Bool {
            preload == .automatic && loadPhase.failure == nil && isMounted && isShown
                && !isInBackground
        }

        private func prepareIfWanted(_ source: VideoSource) {
            guard loadPhase.failure == nil, isMounted, isShown, !isInBackground, !preparationFailed
            else {
                cancelMetadata()
                preparationBudget.release(self)
                return
            }

            switch preload {
            case .none:
                cancelMetadata()
            case .metadata:
                guard !hasMetadata, metadataTask == nil else { return }

                if preparationBudget.claimForPreparation(self) {
                    startMetadata(for: source)
                } else {
                    preparationBudget.wait(self)
                }
            case .automatic:
                if preparationBudget.claimForPreparation(self) {
                    startSession(for: source, preparing: true)
                } else {
                    preparationBudget.wait(self)
                }
            }
        }

        private func startMetadata(for source: VideoSource) {
            guard case .url(let url) = source, source.isSupported else {
                preparationBudget.release(self)
                return
            }

            metadataToken += 1
            let token = metadataToken
            let read = readMetadata
            metadataTask = Task { [weak self] in
                let result = try? await read(url)
                guard !Task.isCancelled else { return }

                self?.metadataFinished(result, token: token)
            }
        }

        private func metadataFinished(_ result: VideoMetadata?, token: Int) {
            guard token == metadataToken else { return }

            metadataTask = nil
            preparationBudget.release(self)
            guard let result else {
                // Without a description the video is still fine to play; it is just not known yet.
                preparationFailed = true
                return
            }

            hasMetadata = true
            if result.size != nil, naturalSizeState.value == nil {
                naturalSizeState.value = result.size
                if aspectRatio == nil { setNeedsLayout() }
            }
            if case .unknown = durationState.value { durationState.value = result.duration }
        }

        private func cancelMetadata() {
            metadataToken += 1
            guard metadataTask != nil else { return }

            metadataTask?.cancel()
            metadataTask = nil
            preparationBudget.release(self)
        }

        /// Play was asked for a video that was only being prepared.
        private func becomeAsked() {
            holdsPreparation = false
            guard !shownFrameState.value else { return }

            loadPhaseState.value = .loading
            setNeedsLayout()
            startTimeout(token: sessionToken)
        }

        /// The budget took the place of this video's preparation for one that is to play.
        func preparationWasTaken() {
            guard session != nil, !wantsToPlay else { return }

            releaseSession()
            if loadPhase.failure == nil { loadPhaseState.value = .idle }
            preparationBudget.wait(self)
        }

        /// The budget has a free place for a video that waited for one.
        func preparationRoomAppeared() {
            reconcile()
        }

        private func startSession(for source: VideoSource, preparing: Bool) {
            guard case .url(let url) = source, source.isSupported else {
                if preparing {
                    preparationFailed = true
                    preparationBudget.release(self)
                } else {
                    fail(.unsupportedSource)
                }
                return
            }

            sessionToken += 1
            let token = sessionToken
            holdsPreparation = preparing
            if !preparing {
                loadPhaseState.value = .loading
                setNeedsLayout()
            }
            let session = makeSession(url, surface) { [weak self] event in
                self?.handle(event, token: token)
            }
            self.session = session
            session.setMuted(isMuted)
            session.setVolume(min(max(volume, 0), 1))
            session.setLooping(isLooping)
            applyContentMode()
            if !preparing { startTimeout(token: token) }
        }

        private func startTimeout(token: Int) {
            timeoutTask?.cancel()
            let limit = prepareTimeout
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }

                self?.timedOut(token: token)
            }
        }

        private func timedOut(token: Int) {
            guard token == sessionToken, loadPhase == .loading else { return }

            fail(.timeout)
        }

        private func handle(_ event: VideoSessionEvent, token: Int) {
            // Whatever an earlier session reports late is not this one's.
            guard token == sessionToken, session != nil else { return }

            switch event {
            case .ready(let size, let duration):
                let ratioChanged = size != naturalSizeState.value && aspectRatio == nil
                if size != nil { naturalSizeState.value = size }
                durationState.value = duration
                if ratioChanged { setNeedsLayout() }
                if let resume = resumeSeconds, case .seconds(let length) = duration {
                    resumeSeconds = nil
                    session?.seek(toSeconds: min(resume, length))
                }
            case .firstFrame:
                guard !shownFrameState.value else { return }

                timeoutTask?.cancel()
                timeoutTask = nil
                // The placeholder goes out with the theme's move for a change of what shows, so
                // that there is no flash between the poster and the picture; where motion is
                // reduced the move is `nil` and the change shows at once.
                let animation = revealAnimation
                lastRevealAnimation = .some(animation)
                withAnimation(animation) {
                    shownFrameState.value = true
                    loadPhaseState.value = .ready
                    setNeedsLayout()
                }
            case .playback(let state):
                playbackState.value = state
                if state == .ended { wantsToPlay = false }
                preparationBudget.setActive(self, wantsToPlay)
                refreshAccessibility()
            case .failed(let reason):
                if holdsPreparation, !wantsToPlay {
                    // Nobody asked for this video: a failure of the preparation is not shown. It
                    // shows, if it is real, when play is asked for.
                    preparationFailed = true
                    releaseSession()
                    if loadPhase.failure == nil { loadPhaseState.value = .idle }
                } else {
                    fail(reason)
                }
            case .stoppedByRoute:
                wantsToPlay = false
                refreshAccessibility()
            }
        }

        /// How the placeholder leaves: the theme's move for a change of what shows, or none where
        /// motion is reduced. Read at the moment the picture comes.
        var revealAnimation: Animation? { theme.animation(.standard) }

        /// The move the placeholder last left with: `nil` before any picture came, `.some(nil)`
        /// for a picture that came with no move. For tests, which cannot watch a move.
        private(set) var lastRevealAnimation: Animation??

        private func fail(_ reason: VideoFailure) {
            releaseSession()
            wantsToPlay = false
            failureView.show(reason)
            playbackState.value = .paused
            loadPhaseState.value = .failed(reason)
            setNeedsLayout()
            refreshAccessibility()
        }

        /// Lets go of the session, keeping where the playhead was. The picture is gone with
        /// it: the placeholder shows again until a new session has one.
        private func releaseSession() {
            timeoutTask?.cancel()
            timeoutTask = nil
            guard let session else { return }

            if shownFrameState.value, playbackState.value != .ended,
                let seconds = session.currentSeconds
            {
                resumeSeconds = seconds
            }
            session.stop()
            self.session = nil
            holdsPreparation = false
            preparationBudget.release(self)
            sessionToken += 1
            playbackState.value = .paused
            if shownFrameState.value {
                shownFrameState.value = false
                setNeedsLayout()
            }
            refreshAccessibility()
        }

        private func sourceChanged() {
            releaseSession()
            cancelMetadata()
            hasMetadata = false
            preparationFailed = false
            resumeSeconds = nil
            naturalSizeState.value = nil
            durationState.value = .unknown
            playbackState.value = .paused
            if shownFrameState.value {
                shownFrameState.value = false
            }
            loadPhaseState.value = source == nil ? .empty : .idle
            wantsToPlay = source != nil && autoplay
            setNeedsLayout()
            reconcile()
            refreshAccessibility()
        }

        private func applyContentMode() {
            surface.videoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        }

        // MARK: Accessibility

        private func refreshAccessibility() {
            let isPlaying = playback == .playing
            accessibility.value =
                switch loadPhase {
                case .failed(let reason): "Failed. " + VideoFailureView.message(for: reason)
                case .loading: "Loading"
                default: isPlaying ? "Playing" : "Paused"
                }
            guard source != nil else {
                accessibilityActions = []
                return
            }

            // The video is one element, so the message and the button over it are not read on
            // their own: the message is its value, and Retry is its action.
            if loadPhase.failure != nil {
                accessibilityActions = [
                    AccessibilityAction(name: "Retry") { [weak self] in
                        self?.retry()
                        return true
                    }
                ]
                return
            }
            // What the action does is what is asked, not what the picture does this moment: the
            // action pauses a video that is asked to play, though it is still buffering.
            accessibilityActions = [
                AccessibilityAction(name: wantsToPlay ? "Pause" : "Play") { [weak self] in
                    guard let self else { return false }

                    if wantsToPlay { pause() } else { play() }
                    return true
                }
            ]
        }
    }

    /// The message that stands over a video that failed, with the button to try again.
    @MainActor
    private final class VideoFailureView: Node {
        private let message = Text(
            "",
            style: {
                var style = TextStyle(size: 15)
                style.color = Color(red: 1, green: 1, blue: 1)
                style.alignment = .center
                return style
            }()
        )
        private let retryButton: Button

        init(retry: @escaping @MainActor () -> Void) {
            retryButton = Button("Retry", action: retry)
            super.init()
            appearance.background = Color(red: 0, green: 0, blue: 0, alpha: 0.6)
            accessibility.isElement = false
        }

        func show(_ reason: VideoFailure) {
            message.text = Self.message(for: reason)
        }

        /// What the reader is told of a failure.
        static func message(for reason: VideoFailure) -> String {
            switch reason {
            case .unsupportedSource: "This video cannot be opened."
            case .network: "The video could not be loaded."
            case .file: "The video file could not be read."
            case .unreadable: "This video cannot be played."
            case .timeout: "The video is taking too long to start."
            case .other: "The video could not be played."
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                message
                retryButton
            }
            .justifyContent(.center)
            .alignItems(.center)
            .gap(12)
            .padding(16)
        }
    }
#endif
