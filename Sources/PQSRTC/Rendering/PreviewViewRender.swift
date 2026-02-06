//
//  PreviewViewRender.swift
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
import Foundation
import NeedleTailMediaKit
import NeedleTailLogger
import WebRTC
@preconcurrency import AVKit
@preconcurrency import CoreImage

actor PreviewViewRender: RendererDelegate {
    
    private let logger: NeedleTailLogger
    let metalProcessor = MetalProcessor()
    private let captureOutputWrapper = CaptureOutputWrapper()
    let layer: AVCaptureVideoPreviewLayer
    private let defaultDevices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .microphone,
            .builtInWideAngleCamera
        ],
        mediaType: .video,
        position: .front
    )
    private let ciContext: CIContext
    var streamTask: Task<Void, Error>?
    
    let rtcVideoRenderWrapper = RTCVideoRenderWrapper(id: "PreviewViewRender", needsRendering: false)
    weak var delegate: BufferToMetalDelegate?
    @MainActor
    var bounds: CGRect {
        didSet {
#if os(iOS)
            if let connection = layer.connection {
                _ = handleOrientation(connection: connection)
            }
#endif
        }
    }
    @MainActor
    func setBounds(_ bounds: CGRect) async {
        self.bounds = bounds
    }
    nonisolated(unsafe) var shouldRenderOnMetal: Bool = false
    nonisolated func setShouldRenderOnMetal(_ render: Bool) {
        self.shouldRenderOnMetal = render
    }
    
    nonisolated(unsafe) var streamContinuation: AsyncStream<CaptureOutputWrapper.CaptureOutputPacket?>.Continuation?
    private var shouldRender = true
    func setShouldRender(_ render: Bool) {
        self.shouldRender = render
    }
    
    func setDelegate(_ view: NTMTKView) {
        self.delegate = view
    }
    
    init(
        layer: AVCaptureVideoPreviewLayer,
        ciContext: CIContext,
        bounds: CGRect,
        logger: NeedleTailLogger = NeedleTailLogger("[PreviewViewRender]")
    ) async {
        layer.videoGravity = .resizeAspectFill
        
        self.layer = layer
        self.ciContext = ciContext
        self.bounds = bounds
        self.logger = logger
        if streamTask?.isCancelled == false { streamTask?.cancel() }
        await startStreamTask()
    }
    
    private func startStreamTask() async {
      
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                // The user has previously granted access to the camera
                self.logger.log(level: .info, message: "AUTHORIZED")
                
            case .notDetermined:
                let result = await AVCaptureDevice.requestAccess(for: .video)
                if !result {
                    self.logger.log(level: .critical, message: "NOT AUTHORIZED")
                }
            default:
                // The user has previously denied access
                self.logger.log(level: .critical, message: "DENIED")
            }
            
            await setSessionLayer()
            if let session = layer.session {
                session.sessionPreset = .high
            }
        streamTask = Task(priority: .high) { [weak self] in
            guard let self else { return }
            try await initializeCaptureStream()
        }
    }
    
    private func setSessionLayer() async {
        // If there's an existing session, stop and clean it up first
        if let existingSession = layer.session, existingSession.isRunning {
            existingSession.stopRunning()
            existingSession.beginConfiguration()
            for input in existingSession.inputs {
                existingSession.removeInput(input)
            }
            for output in existingSession.outputs {
                existingSession.removeOutput(output)
            }
            existingSession.commitConfiguration()
            logger.log(level: .debug, message: "Cleaned up existing capture session before creating new one")
        }
        
        // Create a fresh session
        layer.session = AVCaptureSession()
        logger.log(level: .debug, message: "Created new AVCaptureSession")
    }
    
    func initializeCaptureStream() async throws {
        try await startCaptureSession()
        try await createCaptureSession()
        try await startStream(ciContext: ciContext)
    }
    
    deinit {
#if DEBUG
        // Intentionally no print; rely on logger if needed
#endif
    }
    
    private func startStream(ciContext: CIContext) async throws {
        self.logger.log(level: .debug, message: "Started the Preview Buffer Stream")
        let stream = AsyncStream<CaptureOutputWrapper.CaptureOutputPacket?>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.streamContinuation = continuation
            
            self.captureOutputWrapper.captureOutput = { packet in
                if let packet = packet {
                    continuation.yield(packet)
                } else {
                    continuation.yield(nil)
                }
            }
            continuation.onTermination = { status in
#if DEBUG
                // Intentionally no print; rely on logger if needed
#endif
            }
        }
        
        for await packet in stream {
            layer.connection?.isEnabled = shouldRender
            if shouldRender {
                try await self.handleOutputStream(packet, ciContext: ciContext)
            }
        }
    }
    
    private func startCaptureSession() async throws {
        guard let session = layer.session else { return }
        guard !session.isRunning else { return }
        session.startRunning()
        self.logger.log(level: .debug, message: "Started the Capture Session")
    }
    
    func stopCaptureSession() async {
        guard let session = layer.session else {
            logger.log(level: .debug, message: "Capture session already nil; skipping stop")
            await shutdown()
            return
        }
        
        // Stop the session first
        if session.isRunning {
            session.stopRunning()
            self.logger.log(level: .debug, message: "Stopped the Capture Session")
        }
        
        // Remove all inputs and outputs to ensure clean state for next call
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()
        self.logger.log(level: .debug, message: "Removed all inputs and outputs from Capture Session")
        
        await shutdown()
    }
    
    private func shutdown() async {
        streamContinuation?.finish()
        streamContinuation = nil
        self.captureOutputWrapper.captureOutput = nil
        self.rtcVideoRenderWrapper.frameOutput = nil
        rtcVideoCaptureWrapper = nil
        streamTask?.cancel()
        streamTask = nil
    }
    
    
    private func createCaptureSession() async throws {
        guard let session = layer.session else { return }
        session.beginConfiguration()
        
        var captureDevice: AVCaptureDevice?
        _ = defaultDevices.devices.map { dev in
            if dev.hasMediaType(.video) {
                captureDevice = dev
            } else {
                // Handle error case
            }
        }
        
        guard let captureDevice = captureDevice else { return }
        
        let input = try AVCaptureDeviceInput(device: captureDevice)
        session.removeInput(input)
        if session.canAddInput(input) {
            session.addInput(input)
            //Local Capture setup
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(captureOutputWrapper, queue: DispatchQueue(label: "preview-capture-queue"))
            for connection in output.connections {
#if os(iOS)
                if connection.isVideoRotationAngleSupported(VideoRotation.portrait.angle) {
                    connection.videoRotationAngle = VideoRotation.portrait.angle
                }
#elseif os(macOS)
                if connection.isVideoRotationAngleSupported(VideoRotation.landscapeLeft.angle) {
                    connection.videoRotationAngle = VideoRotation.landscapeLeft.angle
                }
#endif
            }
            session.addOutput(output)
#if os(iOS)
            if #available(iOS 16.0, *) {
                if session.isMultitaskingCameraAccessSupported {
                    // Enable using the camera in multitasking modes.
                    session.isMultitaskingCameraAccessEnabled = true
                }
            }
#endif
        }
        session.commitConfiguration()
        self.logger.log(level: .debug, message: "Created the Capture Session")
    }
    
    private var rtcVideoCaptureWrapper: RTCVideoCaptureWrapper?
    func setCapture(_ rtcVideoCaptureWrapper: RTCVideoCaptureWrapper?) {
        self.rtcVideoCaptureWrapper = rtcVideoCaptureWrapper
        if rtcVideoCaptureWrapper != nil {
            self.logger.log(level: .info, message: "✅ Bound RTCVideoCaptureWrapper (WebRTC capture injection enabled)")
        } else {
            self.logger.log(level: .info, message: "⛔️ Unbound RTCVideoCaptureWrapper (WebRTC capture injection disabled)")
        }
    }

    // MARK: - Capture → WebRTC injection telemetry
    //
    // This answers the critical question:
    // "Are camera frames being injected into WebRTC (and therefore eligible to become RTP)?"
    nonisolated(unsafe) private var injectedFrameCount: UInt64 = 0
    nonisolated(unsafe) private var didLogFirstInjection: Bool = false
    nonisolated(unsafe) private var lastInjectionUptimeNs: UInt64 = 0
    
    enum DeviceOrientationState: Sendable {
        case wasLandscapeLeft, wasLandscapeRight, none
    }
    @MainActor
    var deviceOrientationState: DeviceOrientationState = .none
#if os(iOS)
    @MainActor
    var determineScale: ScaleMode {
        //We are landscape no matter what, whether upright or flat
        if UIScreen.main.bounds.width > UIScreen.main.bounds.height {
            return .aspectFitHorizontal
        } else {
            return .aspectFitVertical
        }
    }
#endif
    enum VideoRotation {
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight
        case faceUp(DeviceOrientationState)

        var angle: CGFloat {
            switch self {
            case .portrait:
                return 90
            case .portraitUpsideDown:
                return 270
            case .landscapeLeft:
                return 180
            case .landscapeRight:
                return 0
            case .faceUp(let state):
                switch state {
                case .wasLandscapeLeft:
                    return 180
                case .wasLandscapeRight:
                    return 0
                case .none:
                    return 90
                }
            }
        }

        var rtcRotation: RTCVideoRotation {
            switch self {
            case .portrait:
                return ._0
            case .portraitUpsideDown:
                return ._180
            case .landscapeLeft:
                return ._90
            case .landscapeRight:
                return ._270
            case .faceUp:
                return ._0 // Default for faceUp, will be overridden in the switch below
            }
        }
    }
    
#if os(iOS)
    @MainActor
    func handleOrientation(connection: AVCaptureConnection, rtcVideoRotation: RTCVideoRotation? = nil) -> RTCVideoRotation? {
        func setVideoRotation(for connection: AVCaptureConnection, rotation: VideoRotation) -> RTCVideoRotation? {
            let angle = rotation.angle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            return rotation.rtcRotation
        }
            let currentOrientation = UIDevice.current.orientation
            switch currentOrientation {
            case .portrait:
                return setVideoRotation(for: connection, rotation: .portrait)
                
            case .portraitUpsideDown:
                return setVideoRotation(for: connection, rotation: .portraitUpsideDown)
                
            case .landscapeLeft:
                deviceOrientationState = .wasLandscapeLeft
                return setVideoRotation(for: connection, rotation: .landscapeLeft)
                
            case .landscapeRight:
                deviceOrientationState = .wasLandscapeRight
                return setVideoRotation(for: connection, rotation: .landscapeRight)
                
            case .faceUp:
                let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
                let rotation: VideoRotation
                switch deviceOrientationState {
                case .wasLandscapeLeft:
                    rotation = isLandscape ? .faceUp(.wasLandscapeLeft) : .faceUp(.none)
                case .wasLandscapeRight:
                    rotation = isLandscape ? .faceUp(.wasLandscapeRight) : .faceUp(.none)
                case .none:
                    rotation = .faceUp(.none)
                }
               return setVideoRotation(for: connection, rotation: rotation)
                
            default:
                deviceOrientationState = .none
                return setVideoRotation(for: connection, rotation: .portrait) // Default to portrait
            }
    }
#endif
    private func handleOutputStream(_ packet: CaptureOutputWrapper.CaptureOutputPacket?, ciContext: CIContext) async throws {
        if let packet = packet {
            var rtcRotation: RTCVideoRotation = ._0
#if os(iOS)
            if let rotation = await handleOrientation(connection: packet.connection, rtcVideoRotation: packet.rtcVideoRotation) {
                rtcRotation = rotation
            }
#endif
            guard await bounds.size != .zero else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(packet.sampleBuffer) else { return }
            guard let session = self.layer.session else { return }

            if let wrapper = rtcVideoCaptureWrapper {
                wrapper.passCapture(
                    pixelBuffer: pixelBuffer,
                    captureSession: session,
                    sampleBuffer: packet.sampleBuffer,
                    connection: packet.connection,
                    rotation: rtcRotation)

                lastInjectionUptimeNs = DispatchTime.now().uptimeNanoseconds
                injectedFrameCount &+= 1

                if didLogFirstInjection == false {
                    didLogFirstInjection = true
                    self.logger.log(level: .info, message: "✅ First camera frame injected into WebRTC")
                }

                if PQSRTCDiagnostics.criticalBugLoggingEnabled, injectedFrameCount % 120 == 0 {
                    // Roughly every ~4s at 30fps. Low-noise, but proves ongoing injection.
                    let lastMsAgo: UInt64 = {
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard now >= lastInjectionUptimeNs else { return 0 }
                        return (now - lastInjectionUptimeNs) / 1_000_000
                    }()
                    self.logger.log(level: .debug, message: "Capture→WebRTC injection OK: injectedFrames=\(injectedFrameCount) lastInjectionMsAgo=\(lastMsAgo)")
                }
            } else {
                // This is the "silent failure" mode: user sees local preview, but WebRTC produces no video RTP.
                if PQSRTCDiagnostics.criticalBugLoggingEnabled {
                    self.logger.log(level: .warning, message: "⚠️ Camera frame available but WebRTC capture wrapper is nil (no frames injected into WebRTC)")
                }
            }
            
            var scaleMode: ScaleMode = .none

            if shouldRenderOnMetal {
#if os(iOS)
                scaleMode = await determineScale
#endif
                let aspectRatio = await metalProcessor.getAspectRatio(
                    width: CGFloat(pixelBuffer.width),
                    height: CGFloat(pixelBuffer.height))
                let scaleInfo = await metalProcessor.createSize(
                    for: scaleMode,
                    originalSize: .init(width: pixelBuffer.width, height: pixelBuffer.height),
                    desiredSize: bounds.size,
                    aspectRatio: aspectRatio)
                let info = try await metalProcessor.createMetalImage(
                    fromPixelBuffer: pixelBuffer,
                    parentBounds: bounds.size,
                    scaleInfo: scaleInfo,
                    aspectRatio: aspectRatio)
                try await delegate?.passTexture(texture: info.texture)
            }
        }
    }
}

extension CVPixelBuffer: @retroactive @unchecked Sendable {
    var width: Int {
        return CVPixelBufferGetWidth(self)
    }
    
    var height: Int {
        return CVPixelBufferGetHeight(self)
    }
}
#endif
