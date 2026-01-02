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
        
        // Clear frame output
        rtcVideoRenderWrapper.frameOutput = nil
        
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
            try await processFrameForSampleBuffer(buffer: buffer, frame: frame, layer: layer)
        }
    }
    
    private func handleI420BufferFrame(_ buffer: RTCI420Buffer, frame: RTCVideoFrame) async throws {
        guard !pauseMetalRendering else {
            logger.log(level: .debug, message: "Metal rendering paused, skipping I420 frame")
            return
        }
        
        // Check bounds
        guard await bounds.size != .zero else {
            logger.log(level: .debug, message: "Bounds are zero, skipping I420 frame")
            return
        }
        
        try await processI420FrameForMetal(buffer: buffer)
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
    
    private func processFrameForSampleBuffer(buffer: RTCCVPixelBuffer, frame: RTCVideoFrame, layer: AVSampleBufferDisplayLayer) async throws {
        do {
            let time = CMTimeMake(value: frame.timeStampNs, timescale: Int32(NSEC_PER_SEC))
            
            guard let sampleBuffer = try await metalProcessor.createSampleBuffer(buffer.pixelBuffer, time: time) else {
                logger.log(level: .warning, message: "Failed to create sample buffer")
                throw SampleBufferViewRendererError.invalidSampleBuffer
            }
            
            layer.sampleBufferRenderer.enqueue(sampleBuffer)
            
        } catch {
            logger.log(level: .error, message: "Sample buffer processing failed: \(error)")
            throw error
        }
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
