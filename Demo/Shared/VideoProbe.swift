import AVFoundation
import AppShell
import CoreVideo
import Foundation
import LayoutCore
import Nodes
import NodesRender
import ThemeCore

/// `VIDEO_PROBE=1` for UI tests and for looking at the video node: a short video the probe
/// writes itself, with a poster over it until the first picture and buttons that drive it, a
/// line that says what the video is doing, and a second video that cannot be opened, with the
/// message of its failure and its Retry button. `VIDEO_FILL=1` starts the first in `fill`,
/// `VIDEO_AUTOPLAY=1` with `autoplay`.
@MainActor
enum VideoProbe {
    static func content(fill: Bool, autoplay: Bool) -> any SceneContent {
        NodeScreen(Page(fill: fill, autoplay: autoplay), title: "Video")
    }

    /// Two seconds of solid frames that change color, 160 by 90 pixels, written to the
    /// temporary directory.
    static func writeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-probe-\(UUID().uuidString).mp4")
        let width = 160
        let height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(60 + frame * 9), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }

        return url
    }

    private final class Page: Node {
        let video = Video()
        let broken = Video(source: .url(URL(fileURLWithPath: "/nonexistent/video-probe.mp4")))
        let status = Text("", style: TextStyle(size: 15))
        let poster = Text("Poster", style: TextStyle(size: 20))
        let playButton: Button
        let pauseButton: Button
        let muteButton: Button
        let fillButton: Button
        let brokenPlay: Button

        init(fill: Bool, autoplay: Bool) {
            playButton = Button("Play") {}
            pauseButton = Button("Pause") {}
            muteButton = Button("Unmute") {}
            fillButton = Button(fill ? "Fit" : "Fill") {}
            brokenPlay = Button("Play broken") {}
            super.init()
            video.contentMode = fill ? .fill : .fit
            video.autoplay = autoplay
            video.placeholder = poster
            poster.appearance.background = Color(red: 0.3, green: 0.3, blue: 0.5)
            video.accessibility.label = "Sample video"
            broken.accessibility.label = "Broken video"
            playButton.onTap = { [weak self] in self?.video.play() }
            pauseButton.onTap = { [weak self] in self?.video.pause() }
            muteButton.onTap = { [weak self] in
                guard let self else { return }

                video.isMuted.toggle()
                muteButton.label.text = video.isMuted ? "Unmute" : "Mute"
            }
            fillButton.onTap = { [weak self] in
                guard let self else { return }

                video.contentMode = video.contentMode == .fit ? .fill : .fit
                fillButton.label.text = video.contentMode == .fit ? "Fill" : "Fit"
            }
            brokenPlay.onTap = { [weak self] in self?.broken.play() }
            Task { [weak self] in
                guard let url = try? await VideoProbe.writeVideo() else { return }

                self?.video.source = .url(url)
            }
        }

        override func update() {
            status.text =
                "Video: \(describe(video.loadPhase)) \(describe(video.playback)) "
                + "frame:\(video.hasShownFrame)"
        }

        private func describe(_ phase: VideoLoadPhase) -> String {
            switch phase {
            case .empty: "empty"
            case .idle: "idle"
            case .loading: "loading"
            case .ready: "ready"
            case .failed: "failed"
            }
        }

        private func describe(_ state: VideoPlaybackState) -> String {
            switch state {
            case .paused: "paused"
            case .waiting: "waiting"
            case .playing: "playing"
            case .ended: "ended"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                video
                FlexContainer(.row) {
                    playButton
                    pauseButton
                    muteButton
                    fillButton
                }
                .gap(8)
                status
                brokenPlay
                broken
            }
            .gap(12)
            .padding(24)
            .alignItems(.stretch)
        }
    }
}
