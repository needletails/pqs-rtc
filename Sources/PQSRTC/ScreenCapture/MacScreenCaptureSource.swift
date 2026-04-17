//
//  MacScreenCaptureSource.swift
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

#if os(macOS)
import ScreenCaptureKit
import WebRTC
import CoreMedia
import NeedleTailLogger

/// Captures a macOS display or window via ScreenCaptureKit and pushes frames
/// into a WebRTC `RTCVideoSource`.
final class MacScreenCaptureSource: NSObject, @unchecked Sendable {

    private let logger = NeedleTailLogger("[MacScreenCaptureSource]")
    private var stream: SCStream?
    private weak var videoSource: RTCVideoSource?
    private let kNanosecondsPerSecond: Float64 = 1_000_000_000
    private lazy var capturer = RTCVideoCapturer()

    /// Enumerate available displays and windows.
    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Begin capture for the given target and deliver frames to `videoSource`.
    func startCapture(target: ScreenShareTarget, videoSource: RTCVideoSource) async throws {
        if stream != nil {
            await stopCapture()
        }
        self.videoSource = videoSource

        let content = try await Self.availableContent()

        let filter: SCContentFilter
        switch target {
        case .entireScreen(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RTCErrors.mediaError("Display \(displayID) not found")
            }
            let ownBundleID = Bundle.main.bundleIdentifier ?? ""
            let excludedWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        case .window(let windowID, _):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RTCErrors.mediaError("Window \(windowID) not found")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)

        default:
            throw RTCErrors.mediaError("MacScreenCaptureSource only supports macOS targets")
        }

        let config = SCStreamConfiguration()
        switch target {
        case .entireScreen(let displayID):
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                config.width = display.width
                config.height = display.height
            }
        case .window:
            config.width = 1920
            config.height = 1080
        default:
            break
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await scStream.startCapture()
        self.stream = scStream
        logger.log(level: .info, message: "Screen capture started")
    }

    /// Stop capturing and release the stream.
    func stopCapture() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            logger.log(level: .warning, message: "Error stopping screen capture: \(error)")
        }
        self.stream = nil
        self.videoSource = nil
        logger.log(level: .info, message: "Screen capture stopped")
    }
}

extension MacScreenCaptureSource: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let videoSource else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * kNanosecondsPerSecond
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: Int64(timeStampNs))
        videoSource.capturer(capturer, didCapture: frame)
    }
}

extension MacScreenCaptureSource: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.log(level: .error, message: "SCStream stopped with error: \(error)")
        self.stream = nil
        self.videoSource = nil
    }
}
#endif
