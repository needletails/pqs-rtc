//
//  iOSScreenCaptureSource.swift
//  pqs-rtc
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//

#if os(iOS)
import ReplayKit
import WebRTC
import CoreMedia
import NeedleTailLogger

/// Captures the in-app screen via ReplayKit and pushes frames into a WebRTC `RTCVideoSource`.
final class iOSScreenCaptureSource: @unchecked Sendable {

    private let logger = NeedleTailLogger("[iOSScreenCaptureSource]")
    private weak var videoSource: RTCVideoSource?
    private let kNanosecondsPerSecond: Float64 = 1_000_000_000
    private let capturer = RTCVideoCapturer()

    /// Start in-app screen capture. No picker is needed on iOS.
    func startCapture(videoSource: RTCVideoSource) async throws {
        self.videoSource = videoSource

        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw RTCErrors.mediaError("ReplayKit screen recording is not available")
        }

        try await recorder.startCapture { [weak self] sampleBuffer, type, error in
            guard let self, error == nil, type == .video else { return }
            guard let videoSource = self.videoSource else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * self.kNanosecondsPerSecond
            let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: Int64(timeStampNs))
            videoSource.capturer(self.capturer, didCapture: frame)
        }
        logger.log(level: .info, message: "iOS screen capture started via ReplayKit")
    }

    /// Stop capturing.
    func stopCapture() async {
        let recorder = RPScreenRecorder.shared()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recorder.stopCapture { [weak self] error in
                if let error {
                    self?.logger.log(level: .warning, message: "Error stopping ReplayKit capture: \(error)")
                }
                continuation.resume()
            }
        }
        self.videoSource = nil
        logger.log(level: .info, message: "iOS screen capture stopped")
    }
}
#endif
