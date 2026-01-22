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
import Foundation


// MARK: - Sendable Extensions
extension RTCVideoFrame: @retroactive @unchecked Sendable {}
extension CMSampleBuffer: @retroactive @unchecked Sendable {}

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
    private let layer: AVSampleBufferDisplayLayer
    private let ciContext: CIContext
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
    
    // MARK: - Frame arrival / display telemetry (diagnostics)
    //
    // This is intentionally lightweight and uses `nonisolated(unsafe)` storage so the WebRTC
    // callback thread can update timestamps without awaiting the actor.
    // Used to answer: "are we still receiving frames?" vs "are we receiving but failing to render?"
    nonisolated(unsafe) private var lastFrameCallbackUptimeNs: UInt64 = 0
    nonisolated(unsafe) private var lastEnqueueUptimeNs: UInt64 = 0
    nonisolated(unsafe) private var receivedFrameCount: UInt64 = 0
    nonisolated(unsafe) private var enqueuedFrameCount: UInt64 = 0
    private var telemetryTask: Task<Void, Never>?
    
    private struct TelemetrySnapshot: Sendable {
        let cbAgeMs: Int64
        let enqAgeMs: Int64
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

    
    // MARK: - Initialization
    init(
        layer: AVSampleBufferDisplayLayer,
        ciContext: CIContext,
        bounds: CGRect,
        logger: NeedleTailLogger = NeedleTailLogger("[SampleBufferViewRenderer]")
    ) {
        self.layer = layer
        self.ciContext = ciContext
        self.bounds = bounds
        self.logger = logger
        self.rtcVideoRenderWrapper = RTCVideoRenderWrapper(id: "SampleBufferViewRenderer")
        logger.log(level: .info, message: "SampleBufferViewRenderer initialized with bounds: \(bounds)")
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
    
    /// Enables or disables Metal rendering.
    ///
    /// When Metal rendering is paused, frames are routed to the sample-buffer pipeline.
    nonisolated func passPause(_ bool: Bool) {
        pauseMetalRendering = bool
        logger.log(level: .debug, message: "Metal rendering paused: \(bool)")
    }
    
    /// Starts consuming frames from the `RTCVideoRenderWrapper` output.
    func startStream() {
        guard !isShutdown else {
            logger.log(level: .warning, message: "Cannot start stream - renderer is shutdown")
            return
        }
        
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
                            message: "Render telemetry: lastFrameCallbackMsAgo=\(snap.cbAgeMs) lastEnqueueMsAgo=\(snap.enqAgeMs) received=\(snap.received) enqueued=\(snap.enqueued) dropped=\(snap.dropped) pauseMetal=\(snap.pauseMetal) layerStatus=\(snap.layerStatusRaw)"
                        )
                    } else if snap.received > 0, snap.received % 600 == 0 {
                        // Roughly every ~20s at 30fps.
                        await self.logger.log(
                            level: .debug,
                            message: "Render telemetry: OK received=\(snap.received) enqueued=\(snap.enqueued) dropped=\(snap.dropped)"
                        )
                    }
                }
            }
        } else {
            telemetryTask?.cancel()
            telemetryTask = nil
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
        receivedFrameCount = 0
        enqueuedFrameCount = 0
        
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
                try await self.handleFrame(frame, ciContext: self.ciContext, layer: self.layer)
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
        let statusRaw = await MainActor.run { layer.status.rawValue }
        return TelemetrySnapshot(
            cbAgeMs: cbAgeMs,
            enqAgeMs: enqAgeMs,
            received: receivedFrameCount,
            enqueued: enqueuedFrameCount,
            dropped: droppedSampleFrames,
            pauseMetal: pauseMetalRendering,
            layerStatusRaw: statusRaw
        )
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
    
    private func handleFrame(_ frame: RTCVideoFrame?, ciContext: CIContext, layer: AVSampleBufferDisplayLayer) async throws {
        guard let frame = frame else {
            logger.log(level: .debug, message: "Received nil frame, skipping")
            return
        }
        
        // Get frame buffer - it's not optional in RTCVideoFrame
        let buffer = frame.buffer
        
        // Handle RTCCVPixelBuffer frames
        if let cvBuffer = buffer as? RTCCVPixelBuffer {
            try await handleCVPixelBufferFrame(cvBuffer, frame: frame, layer: layer)
        }
        // Handle RTCI420Buffer frames
        else if let i420Buffer = buffer as? RTCI420Buffer {
            try await handleI420BufferFrame(i420Buffer, frame: frame)
        }
        else {
            logger.log(level: .warning, message: "Unsupported buffer type: \(type(of: buffer))")
        }
    }
    
    private func handleCVPixelBufferFrame(_ buffer: RTCCVPixelBuffer, frame: RTCVideoFrame, layer: AVSampleBufferDisplayLayer) async throws {
        let pixelBuffer = buffer.pixelBuffer
        
        // Validate pixel buffer dimensions
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else {
            logger.log(level: .warning, message: "Invalid pixel buffer dimensions: \(width)x\(height)")
            throw SampleBufferViewRendererError.invalidPixelBuffer
        }
        
        // Check bounds
        guard await bounds.size != .zero else {
            logger.log(level: .debug, message: "Bounds are zero, skipping frame")
            return
        }
        
        if !pauseMetalRendering {
            // Process for Metal rendering
            try await processFrameForMetal(pixelBuffer: pixelBuffer)
        } else {
            // Process for sample buffer display
            try await processFrameForSampleBuffer(buffer: buffer, frame: frame)
        }
    }
    
    private func handleI420BufferFrame(_ buffer: RTCI420Buffer, frame: RTCVideoFrame) async throws {
        // Check bounds
        guard await bounds.size != .zero else {
            logger.log(level: .debug, message: "Bounds are zero, skipping I420 frame")
            return
        }
        
        if !pauseMetalRendering {
            // Metal path supports I420 directly.
            try await processI420FrameForMetal(buffer: buffer)
            return
        }
        
        // Sample-buffer path: convert I420 -> NV12 CVPixelBuffer -> CMSampleBuffer enqueue.
        let pixelBuffer = try makeNV12PixelBuffer(fromI420: buffer)
        let time = normalizedPresentationTime(for: frame)
        try await processPixelBufferForSampleBuffer(pixelBuffer: pixelBuffer, time: time)
    }

    // MARK: - Pixel buffer conversion (I420 -> NV12)
    private func makeNV12PixelBuffer(fromI420 buffer: RTCI420Buffer) throws -> CVPixelBuffer {
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
        
        // Interleave U/V into NV12 UV plane.
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let uSrcStride = Int(buffer.strideU)
        let vSrcStride = Int(buffer.strideV)
        
        for row in 0..<chromaHeight {
            let uSrc = buffer.dataU.advanced(by: row * uSrcStride)
            let vSrc = buffer.dataV.advanced(by: row * vSrcStride)
            let uvDst = uvDestBase.advanced(by: row * uvDestStride)
            
            // Each chroma sample becomes 2 bytes: U then V.
            let uv = uvDst.assumingMemoryBound(to: UInt8.self)
            for col in 0..<chromaWidth {
                uv[col * 2] = uSrc[col]
                uv[col * 2 + 1] = vSrc[col]
            }
        }
        
        return pixelBuffer
    }
    
    private func processFrameForMetal(pixelBuffer: CVPixelBuffer) async throws {
        do {
            let aspectRatio = await metalProcessor.getAspectRatio(
                width: CGFloat(pixelBuffer.width), 
                height: CGFloat(pixelBuffer.height)
            )
            
            let scaleMode: ScaleMode
#if os(iOS)
            scaleMode = await determineScale
#elseif os(macOS)
            scaleMode = .aspectFitHorizontal
#endif
            
            let scaleInfo = await metalProcessor.createSize(
                for: scaleMode,
                originalSize: .init(width: pixelBuffer.width, height: pixelBuffer.height),
                desiredSize: bounds.size,
                aspectRatio: aspectRatio
            )
            
            let info = try await metalProcessor.createMetalImage(
                fromPixelBuffer: pixelBuffer,
                parentBounds: bounds.size,
                scaleInfo: scaleInfo,
                aspectRatio: aspectRatio
            )
            
            guard let delegate = delegate else {
                logger.log(level: .warning, message: "Delegate not set, cannot pass texture")
                throw SampleBufferViewRendererError.delegateNotSet
            }
            
            try await delegate.passTexture(texture: info.texture)
            
        } catch {
            logger.log(level: .error, message: "Metal processing failed: \(error)")
            throw SampleBufferViewRendererError.metalProcessingFailed(error.localizedDescription)
        }
    }

    private func processFrameForSampleBuffer(buffer: RTCCVPixelBuffer, frame: RTCVideoFrame) async throws {
        let time = normalizedPresentationTime(for: frame)
        try await processPixelBufferForSampleBuffer(pixelBuffer: buffer.pixelBuffer, time: time)
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
        let wasFailed = await MainActor.run { () -> Bool in
            if layer.status == .failed {
                layer.flush()
                return true
            }
            return false
        }
        if wasFailed {
            logger.log(level: .warning, message: "AVSampleBufferDisplayLayer failed: \(String(describing: layer.error)). Flushed.")
        }
        
        let ready = await MainActor.run { layer.isReadyForMoreMediaData }
        guard ready else {
            droppedSampleFrames += 1
            if PQSRTCDiagnostics.criticalBugLoggingEnabled, droppedSampleFrames % 120 == 0 {
                logger.log(level: .debug, message: "Dropping sample-buffer frames (not ready). dropped=\(droppedSampleFrames)")
            }
            return
        }
        
        await MainActor.run { layer.enqueue(sampleBuffer) }
        lastEnqueueUptimeNs = DispatchTime.now().uptimeNanoseconds
        enqueuedFrameCount &+= 1
    }
    
    private func processI420FrameForMetal(buffer: RTCI420Buffer) async throws {
        do {
            let aspectRatio = await metalProcessor.getAspectRatio(
                width: CGFloat(buffer.width), 
                height: CGFloat(buffer.height)
            )
            let scaleMode = await determineScale  
            let scaleInfo = await metalProcessor.createSize(
                for: scaleMode,
                originalSize: .init(width: CGFloat(buffer.width), height: CGFloat(buffer.height)),
                desiredSize: bounds.size,
                aspectRatio: aspectRatio
            )

            let info = try await metalProcessor.createMetalImage(
                fromI420Buffer: buffer,
                parentBounds: bounds.size,
                scaleInfo: scaleInfo,
                aspectRatio: aspectRatio
            )

            guard let delegate else {
                logger.log(level: .warning, message: "Delegate not set, cannot pass I420 texture")
                throw SampleBufferViewRendererError.delegateNotSet
            }
            
            try await delegate.passTexture(texture: info.texture)
            
        } catch {
            logger.log(level: .error, message: "I420 Metal processing failed: \(error)")
            throw SampleBufferViewRendererError.metalProcessingFailed(error.localizedDescription)
        }
    }
}
#endif
