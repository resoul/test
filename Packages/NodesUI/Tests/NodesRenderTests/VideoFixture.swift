#if canImport(AVFoundation)
    import AVFoundation
    import CoreVideo
    import Foundation

    /// A short video written with `AVAssetWriter`: solid frames that change color, so that no
    /// binary fixture is kept in the repository.
    enum VideoFixture {
        /// Writes `seconds` of video at 10 frames a second, `width` by `height` pixels, to a new
        /// file in the temporary directory and returns its URL.
        static func make(seconds: Double = 1, width: Int = 64, height: Int = 48) async throws -> URL
        {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fixture-\(UUID().uuidString).mp4")
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
            let frames = max(Int(seconds * 10), 1)
            for frame in 0..<frames {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(
                    nil,
                    width,
                    height,
                    kCVPixelFormatType_32BGRA,
                    nil,
                    &buffer
                )
                guard let buffer else { throw CocoaError(.fileWriteUnknown) }

                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let level = UInt8(min(255, 40 + frame * 20))
                    memset(base, Int32(level), CVPixelBufferGetDataSize(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: Int64(frame), timescale: 10)
                )
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }

            return url
        }
    }
#endif
