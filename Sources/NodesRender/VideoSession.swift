#if canImport(AVFoundation) && canImport(QuartzCore)
    import AVFoundation
    import Foundation
    import LayoutCore
    import QuartzCore

    extension VideoFailure {
        /// The reason an error of the player or of loading stands for. A network error of a file
        /// is a problem of the file.
        init(_ error: any Error, isFile: Bool = false) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                self = isFile ? .file : .network(URLError.Code(rawValue: ns.code))
                return
            }
            if ns.domain == NSCocoaErrorDomain {
                self = .file
                return
            }
            if ns.domain == AVFoundationErrorDomain {
                switch AVError.Code(rawValue: ns.code) {
                case .contentIsNotAuthorized?:
                    self = .file
                case .fileFormatNotRecognized?, .decodeFailed?, .formatUnsupported?,
                    .failedToLoadMediaData?, .decoderNotFound?, .fileFailedToParse?:
                    self = .unreadable
                default:
                    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                        underlying.domain == NSURLErrorDomain
                    {
                        self =
                            isFile ? .file : .network(URLError.Code(rawValue: underlying.code))
                    } else {
                        self = .other
                    }
                }
                return
            }
            self = .other
        }
    }

    /// Plays one video with AVFoundation into a surface (`AVPlayerLayer`) it does not own.
    ///
    /// The player and the item are made here and let go in `stop()`. The player's own
    /// notifications come on other threads: each is turned into a call on the main actor that
    /// reads the state then, so what is reported is what is true when it is reported.
    @MainActor
    final class AVVideoSession: VideoSession {
        private let player = AVPlayer()
        private let item: AVPlayerItem
        private let surface: AVPlayerLayer
        private let report: @MainActor (VideoSessionEvent) -> Void
        private var observations: [NSKeyValueObservation] = []
        private var endObserver: (any NSObjectProtocol)?
        private var isStopped = false
        private var wasReady = false
        private var isLooping = false
        private var lastPlayback: VideoPlaybackState = .paused
        private var wantsToPlay = false

        init(
            url: URL,
            surface: AVPlayerLayer,
            report: @escaping @MainActor (VideoSessionEvent) -> Void
        ) {
            item = AVPlayerItem(url: url)
            self.surface = surface
            self.report = report
            // The end is handled here — looping or stopping — not by the player.
            player.actionAtItemEnd = .none
            player.replaceCurrentItem(with: item)
            surface.player = player

            observations = [
                item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.itemChanged() }
                },
                item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.itemChanged() }
                },
                player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.playbackChanged() }
                },
                surface.observe(\.isReadyForDisplay, options: [.initial, .new]) {
                    [weak self] _, _ in
                    Task { @MainActor in self?.surfaceChanged() }
                },
            ]
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reachedEnd() }
            }
        }

        var currentSeconds: Double? {
            let time = player.currentTime()
            guard time.isNumeric, item.duration.isNumeric else { return nil }

            return time.seconds
        }

        func play() {
            wantsToPlay = true
            if lastPlayback == .ended {
                player.seek(to: .zero)
            }
            player.play()
        }

        func pause() {
            wantsToPlay = false
            player.pause()
        }

        func seek(toSeconds seconds: Double) {
            player.seek(
                to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        func setMuted(_ isMuted: Bool) { player.isMuted = isMuted }

        func setVolume(_ volume: Double) { player.volume = Float(min(max(volume, 0), 1)) }

        func setLooping(_ isLooping: Bool) { self.isLooping = isLooping }

        func stop() {
            guard !isStopped else { return }

            isStopped = true
            observations.forEach { $0.invalidate() }
            observations = []
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            if surface.player === player { surface.player = nil }
        }

        private func itemChanged() {
            guard !isStopped else { return }

            switch item.status {
            case .readyToPlay:
                let size = item.presentationSize
                let duration: VideoDuration
                if item.duration.isIndefinite {
                    duration = .live
                } else if item.duration.isNumeric {
                    duration = .seconds(item.duration.seconds)
                } else {
                    duration = .unknown
                }
                // The size can arrive a moment after the item is ready; it is told again when
                // it does.
                let shown = size.width > 0 && size.height > 0
                report(
                    .ready(
                        size: shown ? LayoutSize(width: size.width, height: size.height) : nil,
                        duration: duration
                    )
                )
                wasReady = true
            case .failed:
                let url = (item.asset as? AVURLAsset)?.url
                var reason = item.error.map { VideoFailure($0, isFile: url?.isFileURL ?? false) }
                // The player's error for a file that is not there says nothing of it.
                if let url, url.isFileURL,
                    !FileManager.default.isReadableFile(atPath: url.path)
                {
                    reason = .file
                }
                report(.failed(reason ?? .other))
            default:
                break
            }
        }

        private func playbackChanged() {
            guard !isStopped else { return }

            let state: VideoPlaybackState
            switch player.timeControlStatus {
            case .playing: state = .playing
            case .waitingToPlayAtSpecifiedRate: state = .waiting
            default: state = lastPlayback == .ended && !wantsToPlay ? .ended : .paused
            }
            guard state != lastPlayback else { return }

            lastPlayback = state
            report(.playback(state))
        }

        private func surfaceChanged() {
            guard !isStopped, surface.isReadyForDisplay else { return }

            report(.firstFrame)
        }

        private func reachedEnd() {
            guard !isStopped else { return }

            if isLooping {
                player.seek(to: .zero)
                player.play()
                return
            }
            wantsToPlay = false
            player.pause()
            lastPlayback = .ended
            report(.playback(.ended))
        }
    }
#endif
