//
//  SampleBufferViewRenderer.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
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

#if os(iOS) || os(macOS)
@preconcurrency import AVKit
@preconcurrency import WebRTC
import NeedleTailMediaKit
import NeedleTailLogger
import CoreVideo
import CoreImage
import Foundation


// MARK: - Sendable Extensions
extension RTCVideoFrame: @retroactive @unchecked Sendable {}
extension CMSampleBuffer: @retroactive @unchecked Sendable {}

@MainActor
final class SampleBufferDisplayLayerBox {
    let layer: AVSampleBufferDisplayLayer

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }
}

extension SampleBufferDisplayLayerBox: @unchecked Sendable {}

// MARK: - Error Types
/// Errors produced by `SampleBufferViewRenderer`.
///
/// This renderer has two output modes:
/// - Metal texture output (for custom rendering via `NTMTKView`)
/// - Sample-buffer output (via `AVSampleBufferDisplayLayer`)
///
/// These errors are primarily surfaced for debugging and to help the host app
/// diagnose why frames cannot be rendered.
public enum SampleBufferViewRendererError: Error, Sendable {
    /// A frame buffer could not be extracted or converted.
    case invalidFrameBuffer
    /// A pixel buffer was missing or had invalid dimensions.
    case invalidPixelBuffer
    /// A `CMSampleBuffer` could not be created or was invalid.
    case invalidSampleBuffer
    /// Metal processing failed.
    ///
    /// - Parameter String: A human-readable error description.
    case metalProcessingFailed(String)
    /// The renderer requires a delegate to receive Metal textures, but none was set.
    case delegateNotSet
    /// The renderer bounds were not valid for scaling or layout.
    case boundsNotValid
    /// Attempted to start a stream when one was already running.
    case streamAlreadyRunning
    /// Attempted to use streaming APIs before initialization.
    case streamNotInitialized
    /// The output layer was not available.
    case layerNotAvailable
}


// MARK: - Main Renderer Class
/// Converts inbound WebRTC frames into either Metal textures or displayable sample buffers.
///
/// Frames from ``RTCVideoRenderWrapper`` are **deep-copied to I420** on the WebRTC callback thread before
/// this actor sees them, so plane pointers remain valid for async Metal / sample-buffer work (see
/// `RTCVideoRenderWrapper.makeRenderSafeFrameCopy`). Verbose I420 / first-frame traces use `.trace` and
/// `PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled` (`PQSRTC_REMOTE_VIDEO_TRACE_LOGGING=1` in Release).
///
/// The renderer consumes `RTCVideoFrame` instances via `RTCVideoRenderWrapper` and:
/// - When Metal rendering is enabled, produces a texture and passes it to `BufferToMetalDelegate`.
/// - When Metal rendering is paused, converts frames into `CMSampleBuffer` and enqueues them
///   to an `AVSampleBufferDisplayLayer`.
///
/// This type is an `actor` to ensure thread-safe frame processing and clean stream lifecycle
/// management.
actor SampleBufferViewRenderer: RendererDelegate, PiPEventReceiverDelegate {
    
    // MARK: - Properties
    private var streamTask: Task<Void, Error>?
    private let metalProcessor = MetalProcessor()
    private let logger: NeedleTailLogger
    let rtcVideoRenderWrapper: RTCVideoRenderWrapper
    private let layerBox: SampleBufferDisplayLayerBox
    private let ciContext: CIContext
    private let rendersScreenShare: Bool
    /// When true, camera tiles letterbox inside the tile instead of cropping (used during screen share).
    private var prefersAspectFit = false
    /// Last frame processed for Metal; re-scaled when host bounds change while ingress is stalled (frozen tile).
    private var lastMetalDisplayPixelBuffer: CVPixelBuffer?
    @MainActor var bounds: CGRect
    private weak var delegate: BufferToMetalDelegate?
    
    // MARK: - Sample-buffer timestamping & backpressure
    //
    // AVSampleBufferDisplayLayer is sensitive to invalid / non-monotonic timestamps and can
    // enter a failed state that looks like "video freezes". WebRTC frame timestamps are often
    // large (nanoseconds since an arbitrary epoch). For display, we normalize to a small,
    // monotonic timeline starting at 0.
    private var baseTimestampNs: Int64?
    private var lastPresentationNs: Int64 = -1
    private var droppedSampleFrames: Int = 0

    // MARK: - Sample-buffer recovery (production hardening)
    //
    // AVSampleBufferDisplayLayer can enter states where it will not resume decoding/rendering
    // after upstream disruption (packet loss / missing keyframes / large gaps). In those cases,
    // a flush (and often "flushAndRemoveImage") plus timestamp rebasing is required to recover.
    private var consecutiveNotReadyDrops: Int = 0
    private var lastLayerRecoveryUptimeNs: UInt64 = 0
    
    // MARK: - Frame arrival / display telemetry (diagnostics)
    //
    // This is intentionally lightweight and uses `nonisolated(unsafe)` storage so the WebRTC
    // callback thread can update timestamps without awaiting the actor.
    // Used to answer: "are we still receiving frames?" vs "are we receiving but failing to render?"
    nonisolated(unsafe) private var lastFrameCallbackUptimeNs: UInt64 = 0
    nonisolated(unsafe) private var lastEnqueueUptimeNs: UInt64 = 0
    /// Last time a frame successfully reached the display path (Metal `passTexture` or sample-buffer enqueue).
    nonisolated(unsafe) private var lastSuccessfulRemoteVideoOutputUptimeNs: UInt64 = 0
    nonisolated(unsafe) private var receivedFrameCount: UInt64 = 0
    nonisolated(unsafe) private var enqueuedFrameCount: UInt64 = 0
    
    // MARK: - First-frame / wire-format diagnostics (trace, gated)
    //
    // Emitted at `.trace` only when `PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled` is true
    // (DEBUG by default; Release requires `PQSRTC_REMOTE_VIDEO_TRACE_LOGGING=1`). Answers bring-up
    // questions like “any remote callbacks?” and “what I420 strides hit Metal?”.
    nonisolated(unsafe) private var didLogFirstFrameCallback: Bool = false
    private var didLogFirstEnqueue: Bool = false
    private var didLogFirstIncomingPixelFormat = false
    private var didLogFirstIncomingI420Format = false
    private var i420WireLogCount = 0
    private var lastI420WireSignature: String?
    private var i420DetailedLogCount = 0
    private var didLogFirstRemoteMetalScale = false
    private var didLogIOSRemoteI420MetalPath = false
    private var telemetryTask: Task<Void, Never>?
    /// Always-on 2s cadence: distinguish “no frames from WebRTC” vs “frames arrive but nothing is displayed”.
    private var remoteVideoHealthWatchdogTask: Task<Void, Never>?
    private var didLogRemoteNeverOutputWarning = false
    
    private struct TelemetrySnapshot: Sendable {
        let cbAgeMs: Int64
        let enqAgeMs: Int64
        let outputAgeMs: Int64
        let received: UInt64
        let enqueued: UInt64
        let dropped: Int
        let pauseMetal: Bool
        let layerStatusRaw: Int
    }
    
    // MARK: - Thread-Safe Properties
    nonisolated(unsafe) private var pauseMetalRendering = false
    nonisolated(unsafe) private var streamContinuation: AsyncStream<RTCVideoFrame?>.Continuation?
    nonisolated(unsafe) private var isShutdown = false
    /// Set by the call UI after `renderRemoteVideo` — enables “should be receiving but isn’t” checks.
    nonisolated(unsafe) private var remoteVideoInboundExpected: Bool = false
    nonisolated(unsafe) private var remoteVideoExpectedSinceUptimeNs: UInt64 = 0
    nonisolated(unsafe) private var lastLogRemoteExpectedNoCallbacksUptimeNs: UInt64 = 0

    
    // MARK: - Initialization
    init(
        layerBox: SampleBufferDisplayLayerBox,
        ciContext: CIContext,
        bounds: CGRect,
        rendersScreenShare: Bool = false,
        logger: NeedleTailLogger = NeedleTailLogger("[SampleBufferViewRenderer]")
    ) {
        self.layerBox = layerBox
        self.ciContext = ciContext
        self.rendersScreenShare = rendersScreenShare
        self.bounds = bounds
        self.logger = logger
        self.rtcVideoRenderWrapper = RTCVideoRenderWrapper(id: rendersScreenShare ? "ScreenShareRenderer" : "SampleBufferViewRenderer")
        logger.log(level: .info, message: "SampleBufferViewRenderer initialized with bounds: \(bounds) rendersScreenShare=\(rendersScreenShare)")
    }

    private var usesAspectFitRendering: Bool {
        rendersScreenShare || prefersAspectFit
    }

    func setPrefersAspectFit(_ enabled: Bool) {
        let changed = prefersAspectFit != enabled
        prefersAspectFit = enabled
        if changed {
            Task { await self.reprocessCachedMetalFrameIfNeeded(reason: "prefersAspectFit") }
        }
    }

    /// Fits source pixels inside a tile without cropping or stretching.
    ///
    /// Screen shares can switch between portrait and landscape while a fixed tile remains
    /// mounted. Keep this calculation local to the receiver so an upstream scaler regression
    /// cannot turn presentation content into a cropped or compressed image.
    nonisolated static func aspectFitSize(sourceSize: CGSize, destinationSize: CGSize) -> CGSize {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0
        else {
            return .zero
        }

        let scale = min(
            destinationSize.width / sourceSize.width,
            destinationSize.height / sourceSize.height
        )
        return CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    nonisolated private static func aspectFitScaleInfo(
        sourceSize: CGSize,
        destinationSize: CGSize
    ) -> MetalProcessor.ScaledInfo {
        let fitted = aspectFitSize(sourceSize: sourceSize, destinationSize: destinationSize)
        return MetalProcessor.ScaledInfo(
            size: fitted,
            scaleX: fitted.width / max(sourceSize.width, 1),
            scaleY: fitted.height / max(sourceSize.height, 1)
        )
    }
    
    deinit {
#if DEBUG
        logger.log(level: .debug, message: "SampleBufferViewRenderer deinit started")
#endif
    }
    
    // MARK: - Public Methods
    /// Sets the view delegate that receives Metal textures.
    func setDelegate(_ view: NTMTKView) {
        self.delegate = view
        logger.log(level: .debug, message: "Delegate set to NTMTKView")
    }
    
    /// Mirrors the hosting ``NTMTKView`` bounds into the renderer.
    ///
    /// On macOS, AppKit often resizes `NSView` via `setFrameSize` / `layout`, which does **not**
    /// reliably trigger Swift `frame.didSet`. If these bounds stay `.zero`, ``handleCVPixelBufferFrame``
    /// skips Metal output (`boundsNotValid` path) and the call UI stays blank despite decoded frames.
    func applyHostViewBounds(_ rect: CGRect) async {
        let previousSize = await MainActor.run { bounds.size }
        await MainActor.run {
            bounds = rect
        }
        let sizeChanged = abs(previousSize.width - rect.width) > 0.5
            || abs(previousSize.height - rect.height) > 0.5
        if sizeChanged {
            await reprocessCachedMetalFrameIfNeeded(reason: "hostBounds")
        }
    }

    /// Drops the last rasterized frame without shutting down the renderer or stream.
    ///
    /// Used when the hosting view's aspect ratio changes (e.g. camera tile expanding after screen
    /// share ends) so a stale strip-sized Metal texture is not stretched to the new bounds.
    func clearCachedMetalDisplayFrame() async {
        lastMetalDisplayPixelBuffer = nil
        if let mtkView = delegate as? NTMTKView {
            await mtkView.clearMetalDisplayTexture()
        }
    }

    /// Re-rasterizes the last decoded frame when layout changes but WebRTC callbacks are stalled.
    private func reprocessCachedMetalFrameIfNeeded(reason: String) async {
        guard !pauseMetalRendering, !isShutdown, let cached = lastMetalDisplayPixelBuffer else { return }
        let width = CVPixelBufferGetWidth(cached)
        let height = CVPixelBufferGetHeight(cached)
        guard width > 0, height > 0 else { return }
        do {
            try await processFrameForMetal(pixelBuffer: cached)
        } catch {
            logger.log(
                level: .debug,
                message: "Cached frame reprocess after \(reason) failed: \(error)"
            )
        }
    }
    
    /// Enables or disables Metal rendering.
    ///
    /// When Metal rendering is paused, frames are routed to the sample-buffer pipeline.
    nonisolated func passPause(_ bool: Bool) {
        pauseMetalRendering = bool
        logger.log(level: .debug, message: "Metal rendering paused: \(bool)")
    }

    /// Call when the session has attached a live remote video track to this renderer (`renderRemoteVideo` / auxiliary sink).
    /// The health watchdog then warns if no frame callbacks arrive within a short grace period.
    func setRemoteVideoInboundExpected(_ expected: Bool) {
        remoteVideoInboundExpected = expected
        if expected {
            remoteVideoExpectedSinceUptimeNs = DispatchTime.now().uptimeNanoseconds
            lastLogRemoteExpectedNoCallbacksUptimeNs = 0
        } else {
            remoteVideoExpectedSinceUptimeNs = 0
            lastLogRemoteExpectedNoCallbacksUptimeNs = 0
        }
    }
    
    /// Starts consuming frames from the `RTCVideoRenderWrapper` output.
    func startStream() {
        guard !isShutdown else {
            logger.log(level: .warning, message: "Cannot start stream - renderer is shutdown")
            return
        }
        didLogRemoteNeverOutputWarning = false
        
        if let existingTask = streamTask, !existingTask.isCancelled {
            logger.log(level: .info, message: "Cancelling existing stream task")
            existingTask.cancel()
        }
        
        // Expensive telemetry loop is gated behind a runtime flag.
        if PQSRTCDiagnostics.criticalBugLoggingEnabled {
            if let existingTelemetry = telemetryTask, !existingTelemetry.isCancelled {
                existingTelemetry.cancel()
            }
            telemetryTask = Task { [weak self] in
                guard let self else { return }
                // Periodically log whether frames are still arriving / enqueuing.
                // This makes "sender hung" vs "renderer stalled" immediately obvious from logs.
                while true {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                    if Task.isCancelled { return }
                    if self.isShutdown { return }
                    if !PQSRTCDiagnostics.criticalBugLoggingEnabled { return }
                    
                    let snap = await self.makeTelemetrySnapshot()
                    
                    // Only emit when things look suspicious (stale), or occasionally for baseline.
                    // - if frames are not arriving for > 1500ms, warn
                    // - if frames arrive but enqueue stalls for > 1500ms, warn
                    if snap.cbAgeMs > 1500 || (snap.cbAgeMs >= 0 && snap.enqAgeMs > 1500) {
                        await self.logger.log(
                            level: .warning,
                            message: "Render telemetry: lastFrameCallbackMsAgo=\(snap.cbAgeMs) lastEnqueueMsAgo=\(snap.enqAgeMs) lastOutputMsAgo=\(snap.outputAgeMs) received=\(snap.received) enqueued=\(snap.enqueued) dropped=\(snap.dropped) pauseMetal=\(snap.pauseMetal) layerStatus=\(snap.layerStatusRaw)"
                        )
                    } else if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled,
                              snap.received > 0, snap.received % 600 == 0 {
                        // Roughly every ~20s at 30fps.
                        await self.logger.log(
                            level: .trace,
                            message: "Render telemetry: OK received=\(snap.received) enqueued=\(snap.enqueued) dropped=\(snap.dropped)"
                        )
                    }
                }
            }
        } else {
            telemetryTask?.cancel()
            telemetryTask = nil
        }

        remoteVideoHealthWatchdogTask?.cancel()
        remoteVideoHealthWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if self.isShutdown { return }
                await self.logRemoteVideoHealthIfNeeded()
            }
        }
        
        streamTask = Task(priority: .high) { [weak self] in
            guard let self = self else {
                self?.logger.log(level: .error, message: "Self reference lost during stream start")
                return
            }
            
            do {
                try await self.handleStream()
            } catch {
                self.logger.log(level: .error, message: "Stream handling failed: \(error)")
                throw error
            }
        }
        
        logger.log(level: .info, message: "Stream started successfully")
    }
    
    /// Stops frame processing and releases stream resources.
    ///
    /// This cancels any active stream task, finishes the underlying `AsyncStream`, and clears
    /// the `RTCVideoRenderWrapper` output callback.
    func shutdown() {
        guard !isShutdown else {
            logger.log(level: .debug, message: "Shutdown already completed; skipping")
            return
        }
        logger.log(level: .info, message: "Shutdown initiated")
        
        isShutdown = true
        
        // Finish continuation safely
        if let continuation = streamContinuation {
            continuation.finish()
            streamContinuation = nil
            logger.log(level: .debug, message: "Stream continuation finished")
        }
        
        // Cancel stream task
        if let task = streamTask {
            task.cancel()
            streamTask = nil
            logger.log(level: .debug, message: "Stream task cancelled")
        }
        
        telemetryTask?.cancel()
        telemetryTask = nil
        
        // Clear frame output
        rtcVideoRenderWrapper.frameOutput = nil
        
        // Reset sample-buffer state for cleanliness (helps when reusing the same view instance).
        baseTimestampNs = nil
        lastPresentationNs = -1
        droppedSampleFrames = 0
        lastFrameCallbackUptimeNs = 0
        lastEnqueueUptimeNs = 0
        lastSuccessfulRemoteVideoOutputUptimeNs = 0
        receivedFrameCount = 0
        enqueuedFrameCount = 0
        
        remoteVideoHealthWatchdogTask?.cancel()
        remoteVideoHealthWatchdogTask = nil
        didLogRemoteNeverOutputWarning = false
        remoteVideoInboundExpected = false
        remoteVideoExpectedSinceUptimeNs = 0
        lastLogRemoteExpectedNoCallbacksUptimeNs = 0
        lastMetalDisplayPixelBuffer = nil
        
        logger.log(level: .info, message: "Shutdown completed")
    }
    
    // MARK: - Private Methods
    private func handleStream() async throws {
        logger.log(level: .debug, message: "Starting sample buffer stream")
        
        let stream = AsyncStream<RTCVideoFrame?>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }
            
            self.streamContinuation = continuation
            
            self.rtcVideoRenderWrapper.frameOutput = { packet in
                self.lastFrameCallbackUptimeNs = DispatchTime.now().uptimeNanoseconds
                self.receivedFrameCount &+= 1
                
                // First-frame callback signal (runs on WebRTC callback thread).
                if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, self.didLogFirstFrameCallback == false {
                    self.didLogFirstFrameCallback = true
                    Task { [weak self] in
                        guard let self else { return }
                        await self.logger.log(level: .trace, message: "First remote video frame received by renderer callback")
                    }
                }
                
                if let packet = packet {
                    continuation.yield(packet)
                } else {
                    continuation.yield(nil)
                }
            }
            
            continuation.onTermination = { [weak self] status in
                guard let self else { return }
                self.logger.log(level: .debug, message: "Stream continuation terminated with status: \(status)")
            }
        }
        
        for await frame in stream {
            guard !isShutdown else {
                logger.log(level: .debug, message: "Stream terminated due to shutdown")
                break
            }
            
            do {
                try await self.handleFrame(frame, ciContext: self.ciContext)
            } catch {
                logger.log(level: .error, message: "Frame handling failed: \(error)")
                // Continue processing other frames instead of breaking the stream
            }
        }
    }
    
    private func makeTelemetrySnapshot() async -> TelemetrySnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        let lastCb = lastFrameCallbackUptimeNs
        let lastEnq = lastEnqueueUptimeNs
        
        // Use UInt64 math and clamp to Int64 to avoid Swift runtime overflows when casting.
        func ageMsSince(_ last: UInt64) -> Int64 {
            guard last != 0 else { return -1 }
            let deltaNs: UInt64 = (now >= last) ? (now - last) : 0
            let deltaMsU: UInt64 = deltaNs / 1_000_000
            if deltaMsU >= UInt64(Int64.max) { return Int64.max }
            return Int64(deltaMsU)
        }
        
        let cbAgeMs = ageMsSince(lastCb)
        let enqAgeMs = ageMsSince(lastEnq)
        let lastOut = lastSuccessfulRemoteVideoOutputUptimeNs
        let outputAgeMs = ageMsSince(lastOut)
        let statusRaw = await MainActor.run { layerBox.layer.status.rawValue }
        return TelemetrySnapshot(
            cbAgeMs: cbAgeMs,
            enqAgeMs: enqAgeMs,
            outputAgeMs: outputAgeMs,
            received: receivedFrameCount,
            enqueued: enqueuedFrameCount,
            dropped: droppedSampleFrames,
            pauseMetal: pauseMetalRendering,
            layerStatusRaw: statusRaw
        )
    }

    /// Periodic remote-video health: WebRTC vs renderer output vs (when on sample-buffer path) enqueue.
    private func logRemoteVideoHealthIfNeeded() async {
        let snap = await makeTelemetrySnapshot()
        let now = DispatchTime.now().uptimeNanoseconds
        let expectHint = remoteVideoInboundExpected ? " inboundExpected=true" : ""

        if remoteVideoInboundExpected, snap.received == 0 {
            let since = remoteVideoExpectedSinceUptimeNs
            if since > 0, now >= since {
                let elapsedMs = Int64((now - since) / 1_000_000)
                if elapsedMs > 5_000, now &- lastLogRemoteExpectedNoCallbacksUptimeNs >= 8_000_000_000 {
                    lastLogRemoteExpectedNoCallbacksUptimeNs = now
                    await logger.log(
                        level: .warning,
                        message: "Remote video health: INBOUND EXPECTED (track attached to this renderer) but ZERO WebRTC frame callbacks after \(elapsedMs)ms — check remote camera, transceiver direction, mute, packet loss, or decoder"
                    )
                }
            }
        }

        guard snap.received > 0 else { return }

        if snap.cbAgeMs > 1_500 {
            await logger.log(
                level: .warning,
                message: "Remote video health: WebRTC frame callbacks STALLED (lastFrameCallbackMsAgo=\(snap.cbAgeMs)) received=\(snap.received) pauseMetal=\(snap.pauseMetal)\(expectHint)"
            )
            return
        }

        guard snap.cbAgeMs >= 0, snap.cbAgeMs < 900 else { return }

        if snap.pauseMetal {
            if snap.enqAgeMs > 1_500 {
                await logger.log(
                    level: .warning,
                    message: "Remote video health: callbacks OK but SAMPLE-BUFFER enqueue STALLED (lastEnqueueMsAgo=\(snap.enqAgeMs)) received=\(snap.received) enqueued=\(snap.enqueued) dropped=\(snap.dropped) layerStatus=\(snap.layerStatusRaw)\(expectHint)"
                )
            }
        } else {
            if snap.outputAgeMs > 1_500 {
                await logger.log(
                    level: .warning,
                    message: "Remote video health: callbacks OK but RENDERER OUTPUT STALLED — no successful Metal passTexture / display path (lastOutputMsAgo=\(snap.outputAgeMs)) received=\(snap.received) pauseMetal=\(snap.pauseMetal)\(expectHint)"
                )
            } else if snap.received > 45, snap.outputAgeMs < 0, didLogRemoteNeverOutputWarning == false {
                didLogRemoteNeverOutputWarning = true
                await logger.log(
                    level: .warning,
                    message: "Remote video health: many frames received (\(snap.received)) but NEVER recorded a successful display output (check Metal errors / delegate)"
                )
            }
        }
    }

    /// Compatibility helper for call UI code that treats stale inbound frame callbacks as "camera off".
    ///
    /// Returns:
    /// - `-1` when no frame callback has been observed yet
    /// - elapsed milliseconds since the last renderer callback otherwise
    func ageMillisecondsSinceLastVideoFrameCallback() async -> Int64 {
        let snap = await makeTelemetrySnapshot()
        return snap.cbAgeMs
    }

    /// Returns true once at least one WebRTC frame callback has been observed.
    func hasReceivedAnyVideoFrameCallbacks() async -> Bool {
        let snap = await makeTelemetrySnapshot()
        return snap.received > 0
    }

    /// Returns milliseconds since inbound video was expected on this renderer.
    ///
    /// Returns:
    /// - `-1` when inbound expectation was never set
    /// - elapsed milliseconds since expectation began otherwise
    func ageMillisecondsSinceInboundVideoExpectationBegan() async -> Int64 {
        let since = remoteVideoExpectedSinceUptimeNs
        guard since > 0 else { return -1 }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= since else { return -1 }
        return Int64((now - since) / 1_000_000)
    }
    

    @MainActor
    private var determineScale: ScaleMode {
#if os(iOS)
        // We are landscape no matter what, whether upright or flat
        if UIScreen.main.bounds.width > UIScreen.main.bounds.height {
            return .aspectFitHorizontal
        } else {
            return .aspectFitVertical
        }
#else
        return .aspectFitHorizontal
#endif
    }
    
    private func handleFrame(_ frame: RTCVideoFrame?, ciContext: CIContext) async throws {
        guard let frame = frame else {
            logger.log(level: .debug, message: "Received nil frame, skipping")
            return
        }
        
        // Get frame buffer - it's not optional in RTCVideoFrame
        let buffer = frame.buffer
        
        // Handle RTCCVPixelBuffer frames
        if let cvBuffer = buffer as? RTCCVPixelBuffer {
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                logger.log(level: .trace, message: "CVBuffer TO PROCESS \(cvBuffer)")
            }
            try await handleCVPixelBufferFrame(cvBuffer, frame: frame)
        } else if let i420Buffer = buffer as? RTCI420Buffer {
            logI420WireDetailsIfNeeded(i420Buffer, frame: frame, context: "handleFrame dispatch")
            try await handleI420BufferFrame(i420Buffer, frame: frame)
        } else {
            logger.log(level: .warning, message: "Unsupported buffer type: \(type(of: buffer))")
        }
    }
    
    private func handleCVPixelBufferFrame(_ buffer: RTCCVPixelBuffer, frame: RTCVideoFrame) async throws {
        let pixelBuffer = buffer.pixelBuffer
        
        // Validate pixel buffer dimensions
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else {
            logger.log(level: .warning, message: "Invalid pixel buffer dimensions: \(width)x\(height)")
            throw SampleBufferViewRendererError.invalidPixelBuffer
        }
        if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, didLogFirstIncomingPixelFormat == false {
            didLogFirstIncomingPixelFormat = true
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
            logger.log(level: .trace, message: "First remote CVPixelBuffer format=\(format) planes=\(planes) size=\(width)x\(height) pauseMetal=\(pauseMetalRendering)")
        }
        
        if !pauseMetalRendering {
            let displayBuffer = try uprightScreenSharePixelBufferIfNeeded(
                from: pixelBuffer,
                rotation: frame.rotation
            )
            try await processFrameForMetal(pixelBuffer: displayBuffer)
        } else {
            let displayBuffer = try uprightScreenSharePixelBufferIfNeeded(
                from: pixelBuffer,
                rotation: frame.rotation
            )
            // For sample-buffer path (PiP / non-Metal), prefer native NV12 when already provided by
            // WebRTC to avoid unnecessary color conversion churn. Fall back to explicit I420->NV12
            // conversion for other formats.
            let normalizedBuffer = try makeSampleDisplayPixelBuffer(from: frame.buffer, fallback: displayBuffer)
            let time = normalizedPresentationTime(for: frame)
            try await processPixelBufferForSampleBuffer(pixelBuffer: normalizedBuffer, time: time)
        }
    }

    private func uprightScreenSharePixelBufferIfNeeded(
        from pixelBuffer: CVPixelBuffer,
        rotation: RTCVideoRotation
    ) throws -> CVPixelBuffer {
        guard rotation != ._0 else { return pixelBuffer }
        guard let rotated = ReplayKitScreenShareJPEGOrientation.uprightPixelBuffer(
            from: pixelBuffer,
            webRTCRotation: rotation,
            context: ciContext
        ) else {
            logger.log(
                level: .warning,
                message: "Failed to apply remote video rotation=\(rotation.rawValue); using source buffer"
            )
            return pixelBuffer
        }
        return rotated
    }
    
    private func handleI420BufferFrame(_ buffer: RTCI420Buffer, frame: RTCVideoFrame) async throws {
        if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, didLogFirstIncomingI420Format == false {
            didLogFirstIncomingI420Format = true
            logger.log(level: .trace, message: "First remote I420 frame received (detailed wire log emitted separately)")
        }
        if !pauseMetalRendering {
            if frame.rotation != ._0 {
                let pixelBuffer = try makeNV12PixelBuffer(fromI420: buffer)
                let displayBuffer = try uprightScreenSharePixelBufferIfNeeded(
                    from: pixelBuffer,
                    rotation: frame.rotation
                )
                try await processFrameForMetal(pixelBuffer: displayBuffer)
                return
            }
            #if os(iOS)
            // Render iOS remote frames from source I420 planes directly for Metal.
            // This avoids an extra I420->NV12 interleave step and preserves source strides.
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, didLogIOSRemoteI420MetalPath == false {
                didLogIOSRemoteI420MetalPath = true
                logger.log(
                    level: .trace,
                    message: "Remote iOS direct I420->Metal path active src=\(buffer.width)x\(buffer.height) strides=\(buffer.strideY)/\(buffer.strideU)/\(buffer.strideV)"
                )
            }
            try await processI420FrameForMetal(buffer: buffer)
            #else
            // Metal path supports I420 directly.
            try await processI420FrameForMetal(buffer: buffer)
            #endif
            return
        }
        
        // Sample-buffer path: convert I420 -> NV12 CVPixelBuffer -> CMSampleBuffer enqueue.
        let pixelBuffer = try makeNV12PixelBuffer(fromI420: buffer)
        let time = normalizedPresentationTime(for: frame)
        try await processPixelBufferForSampleBuffer(pixelBuffer: pixelBuffer, time: time)
    }

    // MARK: - Pixel buffer conversion (I420 -> NV12)
    private func makeNV12PixelBuffer(fromI420 buffer: any RTCI420BufferProtocol) throws -> CVPixelBuffer {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            logger.log(level: .warning, message: "CVPixelBufferCreate failed (status=\(status)) for I420->NV12 conversion")
            throw SampleBufferViewRendererError.invalidPixelBuffer
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let yDestBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvDestBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            logger.log(level: .warning, message: "Failed to get base addresses for NV12 pixel buffer planes")
            throw SampleBufferViewRendererError.invalidPixelBuffer
        }
        
        let yDestStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvDestStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        
        // Copy Y plane
        let ySrcStride = Int(buffer.strideY)
        for row in 0..<height {
            let src = buffer.dataY.advanced(by: row * ySrcStride)
            let dst = yDestBase.advanced(by: row * yDestStride)
            memcpy(dst, src, width)
        }
        
        // Interleave chroma into bi-planar UV memory.
        //
        // Keep standard NV12 UV order for sample-buffer / PiP path.
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let uSrcStride = Int(buffer.strideU)
        let vSrcStride = Int(buffer.strideV)
        
        for row in 0..<chromaHeight {
            let uSrc = buffer.dataU.advanced(by: row * uSrcStride)
            let vSrc = buffer.dataV.advanced(by: row * vSrcStride)
            let uvDst = uvDestBase.advanced(by: row * uvDestStride)
            
            // Write U then V (NV12).
            let uv = uvDst.assumingMemoryBound(to: UInt8.self)
            for col in 0..<chromaWidth {
                uv[col * 2] = uSrc[col]
                uv[col * 2 + 1] = vSrc[col]
            }
        }
        
        return pixelBuffer
    }
    
    private func processFrameForMetal(pixelBuffer: CVPixelBuffer) async throws {
        lastMetalDisplayPixelBuffer = pixelBuffer
        do {
            let renderBounds = await resolveRenderableBounds()
            let aspectRatio = await metalProcessor.getAspectRatio(
                width: CGFloat(pixelBuffer.width), 
                height: CGFloat(pixelBuffer.height)
            )
            
            let scaleMode: ScaleMode
            let originalSize = CGSize(width: pixelBuffer.width, height: pixelBuffer.height)
            let scaleInfo: MetalProcessor.ScaledInfo
            if usesAspectFitRendering {
                scaleInfo = Self.aspectFitScaleInfo(
                    sourceSize: originalSize,
                    destinationSize: renderBounds
                )
            } else {
#if os(iOS)
                scaleMode = .aspectFill
#else
                scaleMode = .aspectFitHorizontal
#endif
                scaleInfo = await metalProcessor.createSize(
                    for: scaleMode,
                    originalSize: originalSize,
                    desiredSize: renderBounds,
                    aspectRatio: aspectRatio
                )
            }
            
            let info = try await metalProcessor.createMetalImage(
                fromPixelBuffer: pixelBuffer,
                parentBounds: renderBounds,
                scaleInfo: scaleInfo,
                aspectRatio: aspectRatio
            )
            
            guard let delegate = delegate else {
                logger.log(level: .warning, message: "Delegate not set, cannot pass texture")
                throw SampleBufferViewRendererError.delegateNotSet
            }
            
            try await delegate.passTexture(texture: info.texture)
            lastSuccessfulRemoteVideoOutputUptimeNs = DispatchTime.now().uptimeNanoseconds
            
        } catch {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            logger.log(
                level: .error,
                message: "Metal processing failed: \(w)x\(h) format=\(fmt) pauseMetalRendering=\(pauseMetalRendering) error=\(error)"
            )
            throw SampleBufferViewRendererError.metalProcessingFailed(error.localizedDescription)
        }
    }

    /// Returns a non-zero render target size for Metal conversion.
    ///
    /// Some host views (especially AppKit-backed collection/grid cells) can initialize this renderer
    /// before layout has established a non-zero frame. In that case we fall back to the layer's
    /// current bounds, and finally to a conservative default.
    private func resolveRenderableBounds() async -> CGSize {
        let hostBounds = await bounds.size
        if hostBounds.width > 0, hostBounds.height > 0 {
            return hostBounds
        }
        let layerBounds = await MainActor.run { self.layerBox.layer.bounds.size }
        if layerBounds.width > 0, layerBounds.height > 0 {
            return layerBounds
        }
        return .init(width: 640, height: 480)
    }

    private func processFrameForSampleBuffer(buffer: RTCCVPixelBuffer, frame: RTCVideoFrame) async throws {
        let time = normalizedPresentationTime(for: frame)
        try await processPixelBufferForSampleBuffer(pixelBuffer: buffer.pixelBuffer, time: time)
    }
    
    private func makeSampleDisplayPixelBuffer(from buffer: RTCVideoFrameBuffer, fallback: CVPixelBuffer) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(fallback)
        if isNV12PixelFormat(format), CVPixelBufferGetWidth(fallback) > 0, CVPixelBufferGetHeight(fallback) > 0 {
            return fallback
        }
        let converted = buffer.toI420()
        return try makeNV12PixelBuffer(fromI420: converted)
    }
    
    private func isNV12PixelFormat(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
    
    /// Produces a small, monotonic presentation timestamp for AVSampleBufferDisplayLayer.
    private func normalizedPresentationTime(for frame: RTCVideoFrame) -> CMTime {
        let ts = frame.timeStampNs
        
        if baseTimestampNs == nil {
            baseTimestampNs = ts
            lastPresentationNs = 0
            return .zero
        }
        
        guard let base = baseTimestampNs else {
            baseTimestampNs = ts
            lastPresentationNs = 0
            return .zero
        }
        
        var rel = ts - base
        if rel < 0 {
            // Clock reset/rollover; rebase but keep monotonicity.
            baseTimestampNs = ts
            rel = max(lastPresentationNs + 1, 0)
        }
        if rel <= lastPresentationNs {
            rel = lastPresentationNs + 1
        }
        lastPresentationNs = rel
        return CMTimeMake(value: rel, timescale: Int32(NSEC_PER_SEC))
    }

    private func processPixelBufferForSampleBuffer(pixelBuffer: CVPixelBuffer, time: CMTime) async throws {
        // Production-safe sample-buffer path: build the CMFormatDescription from the CVPixelBuffer
        // using CoreMedia APIs. This avoids invalid format descriptions causing Fig errors like:
        // CMVideoFormatDescriptionGetDimensions ... kCMFormatDescriptionError_InvalidParameter.
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            logger.log(level: .warning, message: "Failed to create CMVideoFormatDescription (status=\(formatStatus))")
            throw SampleBufferViewRendererError.invalidSampleBuffer
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            logger.log(level: .warning, message: "Failed to create CMSampleBuffer (status=\(sbStatus))")
            throw SampleBufferViewRendererError.invalidSampleBuffer
        }

        // Hint AVSampleBufferDisplayLayer to display ASAP (avoid buffering quirks).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let first = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = unsafeBitCast(first, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        // Enqueue into the display layer.
        //
        // IMPORTANT: AVSampleBufferDisplayLayer is not reliably thread-safe. Enqueue/flush must
        // run on the main thread to avoid sporadic Fig/CoreMedia failures that manifest as freezes.
        let nowUptimeNs = DispatchTime.now().uptimeNanoseconds

        // If the renderer was stalled for a while and frames start flowing again, treat that as
        // a discontinuity and reset the display layer + timestamps. This helps avoid the "network
        // recovered but video stays frozen" symptom.
        let timeSinceLastEnqueueNs: UInt64 = (lastEnqueueUptimeNs > 0 && nowUptimeNs >= lastEnqueueUptimeNs)
            ? (nowUptimeNs - lastEnqueueUptimeNs)
            : 0
        let didStallLongEnoughToRebase = lastEnqueueUptimeNs > 0 && timeSinceLastEnqueueNs >= 2_500_000_000 // 2.5s

        // Decide whether we need to flush to resume decoding (failed state, requiresFlush, or long stall).
        let recoveryReason = await MainActor.run { () -> String? in
            if layerBox.layer.status == .failed { return "layerFailed" }
            if didStallLongEnoughToRebase { return "stallGap" }
            // Some Fig failures set requiresFlushToResumeDecoding without flipping `status` to `.failed`.
            if #available(iOS 11.0, macOS 10.13, *) {
                if layerBox.layer.requiresFlushToResumeDecoding { return "requiresFlushToResumeDecoding" }
            }
            return nil
        }

        if let reason = recoveryReason {
            await recoverSampleBufferLayerIfNeeded(reason: reason, nowUptimeNs: nowUptimeNs)
        }
        
        let ready = await MainActor.run { layerBox.layer.isReadyForMoreMediaData }
        guard ready else {
            droppedSampleFrames += 1
            consecutiveNotReadyDrops += 1

            // If the layer stays "not ready" for too long while we're still receiving frames,
            // proactively recover it. This tends to happen after upstream disruptions.
            if consecutiveNotReadyDrops >= 120 { // ~4s at 30fps, ~8s at 15fps
                await recoverSampleBufferLayerIfNeeded(reason: "notReadyTooLong", nowUptimeNs: nowUptimeNs)
                consecutiveNotReadyDrops = 0
            }

            if PQSRTCDiagnostics.criticalBugLoggingEnabled, droppedSampleFrames % 120 == 0 {
                logger.log(level: .debug, message: "Dropping sample-buffer frames (not ready). dropped=\(droppedSampleFrames)")
            }
            return
        }
        
        await MainActor.run { layerBox.layer.enqueue(sampleBuffer) }
        let outNow = DispatchTime.now().uptimeNanoseconds
        lastEnqueueUptimeNs = outNow
        lastSuccessfulRemoteVideoOutputUptimeNs = outNow
        enqueuedFrameCount &+= 1
        consecutiveNotReadyDrops = 0
        
        if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, didLogFirstEnqueue == false {
            didLogFirstEnqueue = true
            logger.log(level: .trace, message: "First remote video frame enqueued to AVSampleBufferDisplayLayer")
        }
    }

    /// Attempts to recover AVSampleBufferDisplayLayer so rendering resumes after upstream disruptions.
    ///
    /// This is intentionally conservative and throttled to avoid flush storms.
    private func recoverSampleBufferLayerIfNeeded(reason: String, nowUptimeNs: UInt64) async {
        // Throttle recovery attempts (flush is not free and can cause flicker).
        if lastLayerRecoveryUptimeNs > 0, nowUptimeNs >= lastLayerRecoveryUptimeNs {
            let delta = nowUptimeNs - lastLayerRecoveryUptimeNs
            if delta < 1_000_000_000 { // 1s
                return
            }
        }
        lastLayerRecoveryUptimeNs = nowUptimeNs

        // Reset timestamp normalization so the next frame starts a new monotonic timeline.
        baseTimestampNs = nil
        lastPresentationNs = -1

        await MainActor.run {
            // Stronger than `flush()`; clears the last displayed image as well.
            layerBox.layer.flushAndRemoveImage()
            layerBox.layer.flush()
        }

        logger.log(level: .info, message: "Recovered AVSampleBufferDisplayLayer to resume rendering (reason=\(reason))")
    }
    
    private func processI420FrameForMetal(buffer: RTCI420Buffer) async throws {
        do {
            let renderBounds = await resolveRenderableBounds()
            let aspectRatio = await metalProcessor.getAspectRatio(
                width: CGFloat(buffer.width),
                height: CGFloat(buffer.height)
            )
            let scaleMode: ScaleMode
            let originalSize = CGSize(width: CGFloat(buffer.width), height: CGFloat(buffer.height))
            let scaleInfo: MetalProcessor.ScaledInfo
            if usesAspectFitRendering {
                scaleMode = .none
                scaleInfo = Self.aspectFitScaleInfo(
                    sourceSize: originalSize,
                    destinationSize: renderBounds
                )
            } else {
#if os(iOS)
                scaleMode = .aspectFill
#else
                scaleMode = .aspectFitHorizontal
#endif
                scaleInfo = await metalProcessor.createSize(
                    for: scaleMode,
                    originalSize: originalSize,
                    desiredSize: renderBounds,
                    aspectRatio: aspectRatio
                )
            }
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, didLogFirstRemoteMetalScale == false {
                didLogFirstRemoteMetalScale = true
                logger.log(
                    level: .trace,
                    message: "Remote I420 Metal conversion srcSize=\(buffer.width)x\(buffer.height) renderBounds=\(renderBounds) scaleMode=\(scaleMode) scaleX=\(scaleInfo.scaleX) scaleY=\(scaleInfo.scaleY)"
                )
            }

            let info = try await metalProcessor.createMetalImage(
                fromI420Buffer: buffer,
                parentBounds: renderBounds,
                scaleInfo: scaleInfo,
                aspectRatio: aspectRatio
            )

            guard let delegate else {
                logger.log(level: .warning, message: "Delegate not set, cannot pass I420 texture")
                throw SampleBufferViewRendererError.delegateNotSet
            }
            
            try await delegate.passTexture(texture: info.texture)
            lastSuccessfulRemoteVideoOutputUptimeNs = DispatchTime.now().uptimeNanoseconds
            
        } catch {
            logger.log(level: .error, message: "I420 Metal processing failed: \(error)")
            throw SampleBufferViewRendererError.metalProcessingFailed(error.localizedDescription)
        }
    }

    private func logI420WireDetailsIfNeeded(_ buffer: RTCI420Buffer, frame: RTCVideoFrame, context: String) {
        guard PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled else { return }
        let signature = "\(buffer.width)x\(buffer.height)|\(buffer.strideY)|\(buffer.strideU)|\(buffer.strideV)|\(rotationLabel(frame.rotation))"
        let shouldLogBecauseChanged = lastI420WireSignature != signature
        let shouldLogBecauseFirstFew = i420WireLogCount < 12
        guard shouldLogBecauseChanged || shouldLogBecauseFirstFew else { return }

        i420WireLogCount += 1
        lastI420WireSignature = signature
        let includeRowDiagnostics = i420DetailedLogCount < 8 || shouldLogBecauseChanged
        if includeRowDiagnostics {
            i420DetailedLogCount += 1
        }
        let message = describeI420Wire(
            buffer,
            frame: frame,
            context: context,
            includeRowDiagnostics: includeRowDiagnostics
        )
        logger.log(level: .trace, message: "\(message)")
    }

    private func describeI420Wire(
        _ buffer: RTCI420Buffer,
        frame: RTCVideoFrame,
        context: String,
        includeRowDiagnostics: Bool
    ) -> String {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2

        let strideY = Int(buffer.strideY)
        let strideU = Int(buffer.strideU)
        let strideV = Int(buffer.strideV)
        let yPadding = strideY - width
        let uPadding = strideU - chromaWidth
        let vPadding = strideV - chromaWidth

        let yAddr = hexAddress(buffer.dataY)
        let uAddr = hexAddress(buffer.dataU)
        let vAddr = hexAddress(buffer.dataV)

        let yPreview = previewBytes(buffer.dataY, count: min(16, max(strideY, 0)))
        let uPreview = previewBytes(buffer.dataU, count: min(16, max(strideU, 0)))
        let vPreview = previewBytes(buffer.dataV, count: min(16, max(strideV, 0)))

        let yStats = planeStats(buffer.dataY, sampleCount: min(max(strideY, 0), 64))
        let uStats = planeStats(buffer.dataU, sampleCount: min(max(strideU, 0), 64))
        let vStats = planeStats(buffer.dataV, sampleCount: min(max(strideV, 0), 64))

        let strideCheck = "strideExpected(y/u/v)=\(width)/\(chromaWidth)/\(chromaWidth) " +
            "strideExtra(y/u/v)=\(max(0, yPadding))/\(max(0, uPadding))/\(max(0, vPadding))"
        let yRowSummary = includeRowDiagnostics
            ? " yRows=\(samplePlaneRows(ptr: buffer.dataY, stride: strideY, rowCount: height, logicalWidth: width))"
            : ""
        let uRowSummary = includeRowDiagnostics
            ? " uRows=\(samplePlaneRows(ptr: buffer.dataU, stride: strideU, rowCount: chromaHeight, logicalWidth: chromaWidth))"
            : ""
        let vRowSummary = includeRowDiagnostics
            ? " vRows=\(samplePlaneRows(ptr: buffer.dataV, stride: strideV, rowCount: chromaHeight, logicalWidth: chromaWidth))"
            : ""

        return "[Wire I420 \(context)] rotation=\(rotationLabel(frame.rotation)) tsNs=\(frame.timeStampNs) " +
            "size=\(width)x\(height) chroma=\(chromaWidth)x\(chromaHeight) " +
            "strides(y/u/v)=\(strideY)/\(strideU)/\(strideV) padding(y/u/v)=\(yPadding)/\(uPadding)/\(vPadding) " +
            "\(strideCheck) " +
            "planes(y/u/v)=\(yAddr)/\(uAddr)/\(vAddr) " +
            "y[0..]=\(yPreview) u[0..]=\(uPreview) v[0..]=\(vPreview) " +
            "statsY(min/max/avg)=\(yStats.min)/\(yStats.max)/\(yStats.avg) " +
            "statsU(min/max/avg)=\(uStats.min)/\(uStats.max)/\(uStats.avg) " +
            "statsV(min/max/avg)=\(vStats.min)/\(vStats.max)/\(vStats.avg)" +
            "\(yRowSummary)\(uRowSummary)\(vRowSummary)"
    }

    private func rotationLabel(_ rotation: RTCVideoRotation) -> String {
        switch rotation {
        case ._0: return "0"
        case ._90: return "90"
        case ._180: return "180"
        case ._270: return "270"
        @unknown default: return "unknown"
        }
    }

    private func hexAddress(_ ptr: UnsafePointer<UInt8>) -> String {
        let raw = UInt(bitPattern: UnsafeRawPointer(ptr))
        return "0x" + String(raw, radix: 16)
    }

    private func previewBytes(_ ptr: UnsafePointer<UInt8>, count: Int) -> String {
        guard count > 0 else { return "[]" }
        var bytes: [String] = []
        bytes.reserveCapacity(count)
        for i in 0..<count {
            let b = ptr[i]
            let hex = String(format: "%02x", b)
            bytes.append(hex)
        }
        return "[" + bytes.joined(separator: " ") + "]"
    }

    private func planeStats(_ ptr: UnsafePointer<UInt8>, sampleCount: Int) -> (min: Int, max: Int, avg: Int) {
        guard sampleCount > 0 else { return (0, 0, 0) }
        var lo = Int.max
        var hi = Int.min
        var sum = 0
        for i in 0..<sampleCount {
            let v = Int(ptr[i])
            lo = min(lo, v)
            hi = max(hi, v)
            sum += v
        }
        return (lo, hi, sum / sampleCount)
    }

    private func samplePlaneRows(
        ptr: UnsafePointer<UInt8>,
        stride: Int,
        rowCount: Int,
        logicalWidth: Int
    ) -> String {
        guard stride > 0, rowCount > 0, logicalWidth > 0 else { return "none" }
        let sampledRows = [0, rowCount / 2, max(0, rowCount - 1)]
        var parts: [String] = []
        parts.reserveCapacity(sampledRows.count)
        for row in sampledRows {
            let rowPtr = ptr.advanced(by: row * stride)
            let previewCount = min(8, logicalWidth)
            let preview = previewBytes(rowPtr, count: previewCount)
            let rowStats = planeStats(rowPtr, sampleCount: min(logicalWidth, 64))
            parts.append("r\(row):\(preview) s=\(rowStats.min)/\(rowStats.max)/\(rowStats.avg)")
        }
        return parts.joined(separator: " | ")
    }
}
#endif
