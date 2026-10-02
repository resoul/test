#if canImport(AVFoundation) && canImport(QuartzCore)
    import AVFoundation
    import Foundation
    import LayoutCore
    import QuartzCore

    /// Where a video is read from: a file, or a web address of a video file (HTTP or HTTPS).
    /// A URL of another kind is a failure (`VideoFailure.unsupportedSource`) when the video
    /// starts, not before: nothing is asked of it until playback is requested.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoSource: Sendable, Equatable {
        case url(URL)

        /// Whether the platform's player can be asked to open the source.
        var isSupported: Bool {
            switch self {
            case .url(let url):
                guard let scheme = url.scheme?.lowercased() else { return false }

                return ["file", "http", "https"].contains(scheme)
            }
        }
    }

    /// How a video occupies its node's frame.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoContentMode: Sendable {
        /// The whole picture, with bars where the proportions differ from the frame's.
        case fit
        /// The frame filled, the picture cut at the edges where the proportions differ.
        case fill
    }

    /// How far the video has come toward its first picture.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoLoadPhase: Sendable, Equatable {
        /// No source.
        case empty
        /// A source, and nothing started: playback was not asked for yet, and nothing is read
        /// before it is.
        case idle
        /// Playback was asked for and the first picture is not there yet.
        case loading
        /// The first picture is showing.
        case ready
        /// The video cannot be shown, for this reason; `retry()` tries again.
        case failed(VideoFailure)

        /// The reason, when the video failed.
        public var failure: VideoFailure? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    /// What the picture is doing, as the player reports it.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoPlaybackState: Sendable, Equatable {
        /// Not playing, and not asked to: the picture stays where it stopped.
        case paused
        /// Asked to play and waiting for data: buffering, at the start or later. It is not a
        /// failure.
        case waiting
        case playing
        /// Reached the end and stopped; a video that loops never ends.
        case ended
    }

    /// How long a video is, when that is known.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoDuration: Sendable, Equatable {
        /// Not known yet: before the player has read the video's description.
        case unknown
        /// A live stream, which has no end.
        case live
        case seconds(Double)
    }

    /// Why a video could not be shown — for choosing what to tell the reader and whether to
    /// offer `retry()`.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoFailure: Sendable, Equatable {
        /// The address is not a file or a web address the player opens.
        case unsupportedSource
        /// The server could not be reached or stopped answering. Worth retrying later.
        case network(URLError.Code)
        /// A file that is missing, or not permitted.
        case file
        /// The bytes are not a video the platform can play.
        case unreadable
        /// The first picture did not come in `Video.prepareTimeout`.
        case timeout
        /// Anything else.
        case other
    }

    /// What a session of playback tells its video, on the main actor.
    enum VideoSessionEvent: Sendable, Equatable {
        /// The video's description is read: its size in points of picture, as it shows
        /// (orientation applied), and its length.
        case ready(size: LayoutSize?, duration: VideoDuration)
        /// The surface shows a picture of this session.
        case firstFrame
        case playback(VideoPlaybackState)
        case failed(VideoFailure)
        /// The sound's route went away — headphones taken out, a speaker lost — and the session
        /// paused itself. A route that is gone does not come back by itself, so the video
        /// stays paused until the app asks again.
        case stoppedByRoute
    }

    /// One run of playback of one source: what plays it, made when playback is first asked
    /// for and let go when the video leaves the tree, fails or gets another source. A session
    /// reports to the video that made it; whatever it reports after it was stopped is
    /// ignored.
    @MainActor
    protocol VideoSession: AnyObject {
        func play()
        func pause()
        func seek(toSeconds seconds: Double)
        func setMuted(_ isMuted: Bool)
        func setVolume(_ volume: Double)
        func setLooping(_ isLooping: Bool)
        /// Where the playhead is, or `nil` when there is none, or the video is live.
        var currentSeconds: Double? { get }
        /// Lets go of everything: observers, the player, the item.
        func stop()
    }

    /// Makes the session for `url` that shows on `surface` and reports to `report`.
    typealias VideoSessionFactory =
        @MainActor (
            _ url: URL,
            _ surface: AVPlayerLayer,
            _ report: @escaping @MainActor (VideoSessionEvent) -> Void
        ) -> any VideoSession
#endif
