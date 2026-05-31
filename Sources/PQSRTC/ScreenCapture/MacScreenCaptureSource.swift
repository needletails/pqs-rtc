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
import AppKit
import CoreGraphics
import ScreenCaptureKit
import WebRTC
import CoreMedia
import QuartzCore
import NeedleTailLogger

/// Captures a macOS display or window via ScreenCaptureKit and pushes frames
/// into a WebRTC `RTCVideoSource`.
final class MacScreenCaptureSource: NSObject, @unchecked Sendable {

    private let logger = NeedleTailLogger("[MacScreenCaptureSource]")
    private var stream: SCStream?
    private weak var videoSource: RTCVideoSource?
    private let kNanosecondsPerSecond: Float64 = 1_000_000_000
    private lazy var capturer = RTCVideoCapturer()
    private let screenSampleQueue = DispatchQueue(label: "com.needletails.pqsrtc.mac-screen-capture.video", qos: .userInteractive)
    private let audioSampleQueue = DispatchQueue(label: "com.needletails.pqsrtc.mac-screen-capture.audio", qos: .userInitiated)
    private var loggedUnsupportedAudioSample = false
    private let onUnexpectedStop: (@Sendable () -> Void)?

    init(onUnexpectedStop: (@Sendable () -> Void)? = nil) {
        self.onUnexpectedStop = onUnexpectedStop
        super.init()
    }

    /// Enumerate available displays and windows.
    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    /// Begin capture for the given target and deliver frames to `videoSource`.
    func startCapture(target: ScreenShareTarget, videoSource: RTCVideoSource) async throws {
        try await startCapture(
            target: target,
            options: ScreenShareOptions(),
            videoSource: videoSource
        )
    }

    /// Begin capture for the given target and deliver frames to `videoSource`.
    func startCapture(
        target: ScreenShareTarget,
        options: ScreenShareOptions,
        videoSource: RTCVideoSource
    ) async throws {
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
            guard Self.isShareableApplicationWindow(window) else {
                throw RTCErrors.mediaError("Window \(windowID) is not a shareable application window")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)

        default:
            throw RTCErrors.mediaError("MacScreenCaptureSource only supports macOS targets")
        }

        let config = SCStreamConfiguration()
        switch target {
        case .entireScreen(let displayID):
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                let sourcePixels = displayPixelSize(for: display)
                let targetPixels = captureOutputSize(for: sourcePixels, options: options)
                config.width = targetPixels.width
                config.height = targetPixels.height
            }
        case .window(let windowID, _):
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                let sourcePixels = windowPixelSize(for: window)
                let targetPixels = captureOutputSize(for: sourcePixels, options: options)
                config.width = targetPixels.width
                config.height = targetPixels.height
            }
        default:
            break
        }
        config.minimumFrameInterval = options.optimizeForVideo
            ? CMTime(value: 1, timescale: 60)
            : CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true
        }
        config.queueDepth = 4
        if options.shareSystemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenSampleQueue)
        if options.shareSystemAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
        }
        try await scStream.startCapture()
        self.stream = scStream
        loggedUnsupportedAudioSample = false
        logger.log(
            level: .info,
            message: "Screen capture started output=\(config.width)x\(config.height) optimizeForVideo=\(options.optimizeForVideo) shareSystemAudio=\(options.shareSystemAudio)"
        )
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

    private func captureOutputSize(for sourcePixels: CGSize, options: ScreenShareOptions) -> (width: Int, height: Int) {
        let sourceWidth = max(2, sourcePixels.width)
        let sourceHeight = max(2, sourcePixels.height)
        let maxLongEdge: CGFloat = options.optimizeForVideo ? 1920 : 2048
        let longEdge = max(sourceWidth, sourceHeight)
        let scale = min(1, maxLongEdge / max(longEdge, 1))
        let width = Int(max(2, (sourceWidth * scale).rounded(.toNearestOrAwayFromZero)))
        let height = Int(max(2, (sourceHeight * scale).rounded(.toNearestOrAwayFromZero)))
        return (width: width, height: height)
    }

    private func displayPixelSize(for display: SCDisplay) -> CGSize {
        let pixelWidth = CGDisplayPixelsWide(display.displayID)
        let pixelHeight = CGDisplayPixelsHigh(display.displayID)
        if pixelWidth > 0, pixelHeight > 0 {
            return CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        }
        return CGSize(width: CGFloat(max(2, display.width)), height: CGFloat(max(2, display.height)))
    }

    private func windowPixelSize(for window: SCWindow) -> CGSize {
        let pointSize = window.frame.size
        let scale = backingScaleFactor(for: window.frame)
        let pixelWidth = max(2, pointSize.width * scale)
        let pixelHeight = max(2, pointSize.height * scale)
        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private func backingScaleFactor(for frame: CGRect) -> CGFloat {
        let matches = NSScreen.screens.filter { screen in
            screen.frame.intersects(frame) || screen.visibleFrame.intersects(frame)
        }
        let best = matches.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        } ?? NSScreen.main
        return best?.backingScaleFactor ?? 1
    }

    private static func isShareableApplicationWindow(_ window: SCWindow) -> Bool {
        guard window.isOnScreen else { return false }
        guard window.windowLayer == 0 else { return false }
        guard let application = window.owningApplication else { return false }

        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        if !ownBundleID.isEmpty, application.bundleIdentifier == ownBundleID {
            return false
        }

        let appName = application.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { return false }

        let size = window.frame.size
        return size.width >= 160 && size.height >= 120
    }
}

extension MacScreenCaptureSource: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleScreenSampleBuffer(sampleBuffer)
        case .audio:
            handleAudioSampleBuffer(sampleBuffer)
        @unknown default:
            return
        }
    }

    private func handleScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        guard sampleBufferContainsCompleteFrame(sampleBuffer) else { return }
        guard let videoSource else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestampSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let timeStampNs = (timestampSeconds.isFinite ? timestampSeconds : CACurrentMediaTime()) * kNanosecondsPerSecond
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: Int64(timeStampNs))
        videoSource.capturer(capturer, didCapture: frame)
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        if !loggedUnsupportedAudioSample {
            loggedUnsupportedAudioSample = true
            logger.log(
                level: .warning,
                message: "Captured ScreenCaptureKit system-audio samples, but this WebRTC build does not expose a push-audio source for RTP egress"
            )
        }
    }

    private func sampleBufferContainsCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return true
        }
        return status == .complete
    }
}

extension MacScreenCaptureSource: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.log(level: .error, message: "SCStream stopped with error: \(error)")
        self.stream = nil
        self.videoSource = nil
        onUnexpectedStop?()
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite, width > 0, height > 0 else { return 0 }
        return width * height
    }
}
#endif
