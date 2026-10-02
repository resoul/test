#if canImport(AVFoundation) && canImport(QuartzCore)
    import AVFoundation
    import Foundation
    import LayoutCore

    /// How much of a video is read before playback is asked for.
    ///
    /// Every mode is a wish, not a promise: it applies only to a video that is in the tree and
    /// showing, only while the app's ``VideoPreparationBudget`` has room, and it is given up at
    /// once when the video leaves the tree, its tree stops showing, or room is needed for a video
    /// that was asked to play. What is read is up to the platform; the mode says what for, not how
    /// many bytes.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum VideoPreload: Sendable, Equatable {
        /// Nothing is read until playback is asked for. The default.
        case none
        /// The video's description is read — its size and length — so that the node has its
        /// proportions and `duration` before play, and no picture is made.
        case metadata
        /// The first picture is made ready, paused, so that play starts at once and the
        /// placeholder gives way to the picture before it.
        case automatic
    }

    /// How many videos may be prepared or playing at once, so that a feed of videos does not make a
    /// player for every row.
    ///
    /// A video that is asked to play always gets its place: if the budget is full it takes the
    /// place of the oldest preparation of another video, which is let go. Playing videos are never
    /// let go to make room. A video that is only being prepared never takes a place from
    /// another: it waits for one, and is prepared when one is free.
    ///
    /// The app owns the budget and gives it to the videos of a screen; ``shared`` is the one
    /// they use unless told otherwise.
    ///
    /// Ownership: the budget keeps its videos weakly. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @MainActor
    public final class VideoPreparationBudget {
        /// The budget of videos that are given none of their own: two.
        public static let shared = VideoPreparationBudget(limit: 2)

        /// How many videos may be prepared or playing; `0` allows no preparation, and playing is
        /// still allowed.
        public let limit: Int

        private struct Entry {
            weak var video: Video?
            /// Asked to play, or playing: not to be let go for another video.
            var isActive: Bool
            var order: Int
        }

        private struct Waiting {
            weak var video: Video?
        }

        private var entries: [ObjectIdentifier: Entry] = [:]
        private var waiting: [Waiting] = []
        private var counter = 0

        public init(limit: Int) {
            self.limit = max(limit, 0)
        }

        /// How many videos hold a place now.
        public var occupied: Int {
            prune()
            return entries.count
        }

        // MARK: What a video asks

        /// The video is to play: it holds a place, and if that makes more than `limit` the oldest
        /// preparations of other videos are let go.
        func claimForPlay(_ video: Video) {
            prune()
            let id = ObjectIdentifier(video)
            if entries[id] == nil {
                counter += 1
                entries[id] = Entry(video: video, isActive: true, order: counter)
                let overflow = entries.count - limit
                if overflow > 0 {
                    let victims =
                        entries
                        .filter { $0.key != id && !$0.value.isActive }
                        .sorted { $0.value.order < $1.value.order }
                        .prefix(overflow)
                    for (key, entry) in victims {
                        entries[key] = nil
                        entry.video?.preparationWasTaken()
                    }
                }
            } else {
                entries[id]?.isActive = true
            }
            waiting.removeAll { $0.video === video }
        }

        /// The video would like to be prepared. Returns whether a place was free; it never takes
        /// one from another video.
        func claimForPreparation(_ video: Video) -> Bool {
            prune()
            let id = ObjectIdentifier(video)
            if entries[id] != nil { return true }
            guard entries.count < limit else { return false }

            counter += 1
            entries[id] = Entry(video: video, isActive: false, order: counter)
            waiting.removeAll { $0.video === video }
            return true
        }

        /// The video keeps its place, as one that may be let go (`isActive` false) or not.
        func setActive(_ video: Video, _ isActive: Bool) {
            entries[ObjectIdentifier(video)]?.isActive = isActive
        }

        /// The video lets its place go, and the first that waits for one is told.
        func release(_ video: Video) {
            waiting.removeAll { $0.video === video }
            guard entries.removeValue(forKey: ObjectIdentifier(video)) != nil else { return }

            offer()
        }

        /// The video waits for a place.
        func wait(_ video: Video) {
            guard !waiting.contains(where: { $0.video === video }) else { return }

            waiting.append(Waiting(video: video))
        }

        private func offer() {
            prune()
            while entries.count < limit, !waiting.isEmpty {
                let next = waiting.removeFirst()
                next.video?.preparationRoomAppeared()
            }
        }

        /// Forgets videos that are gone.
        private func prune() {
            entries = entries.filter { $0.value.video != nil }
            waiting.removeAll { $0.video == nil }
        }
    }

    /// What a read of a video's description gives.
    typealias VideoMetadata = (size: LayoutSize?, duration: VideoDuration)

    /// Reads the description of the video at `url` without playing it.
    typealias VideoMetadataReader = @Sendable (URL) async throws -> VideoMetadata

    extension AVVideoSession {
        /// Reads the size (orientation applied) and the length of the video at `url`. The load
        /// cannot be cancelled once it is under way; its result is dropped by whoever stopped
        /// waiting.
        static func readMetadata(of url: URL) async throws -> VideoMetadata {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            var size: LayoutSize?
            if let track = tracks.first {
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let turned = natural.applying(transform)
                if abs(turned.width) > 0, abs(turned.height) > 0 {
                    size = LayoutSize(width: abs(turned.width), height: abs(turned.height))
                }
            }
            let length: VideoDuration =
                duration.isIndefinite
                ? .live : (duration.isNumeric ? .seconds(duration.seconds) : .unknown)
            return (size, length)
        }
    }
#endif
