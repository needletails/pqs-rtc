//
//  NTMTKView.swift
//  needle-tail-rtc
//
//  Created by Cole M on 1/11/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
//
#if os(iOS) || os(macOS)
@preconcurrency import MetalKit
import WebRTC
import NeedleTailLogger
import NeedleTailMediaKit

protocol BufferToMetalDelegate: AnyObject, Sendable {
    func passTexture(texture: MTLTexture) async throws
}

public final class NTMTKView: MTKView, BufferToMetalDelegate {
    
    public enum ViewType: Sendable {
        case sample, preview
    }
    
    public enum NTMTKViewError: Error, Sendable {
        case metalDeviceNotAvailable
        case renderPipelineCreationFailed
        case textureCreationFailed
        case commandQueueCreationFailed
    }
    
    private let mtlDevice: MTLDevice?
    private var library: MTLLibrary?
    private let mtkViewDelegateWrapper = MTKViewDelegateWrapper()
    private let logger: NeedleTailLogger
    private let type: ViewType
    private var texture: MTLTexture?
    private var streamTask: Task<Void, Error>?
    private var streamContinuation: AsyncStream<MTKView?>.Continuation?
    weak var renderer: RendererDelegate?
    
    lazy var renderPipelineState: MTLRenderPipelineState? = {
        guard let mtlDevice = mtlDevice else {
            logger.log(level: .error, message: "Metal device not available")
            return nil
        }
#if SWIFT_PACKAGE
        library = try? mtlDevice.makeDefaultLibrary(bundle: Bundle.module)
#else
        let frameworkBundle = Bundle(for: RTCSession.self)
        library = try? mtlDevice.makeDefaultLibrary(bundle: frameworkBundle)
#endif
        guard let library,
              let vertexFunction = library.makeFunction(name: "mapTexture"),
              let fragmentFunction = library.makeFunction(name: "displayTexture")
        else {
            logger.log(level: .error, message: "Failed to create render pipeline state - Metal functions not found")
            return nil
        }
        self.library = library
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = .invalid
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        do {
            return try mtlDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            logger.log(level: .error, message: "Failed to create render pipeline state: \(error)")
            return nil
        }
    }()
    
    
#if os(iOS)
    @MainActor
    override public var bounds: CGRect {
        didSet {
            let renderer = self.renderer
            if let pRenderer = renderer as? PreviewViewRender {
                setBounds(renderer: pRenderer, bounds: bounds)
            }
            if let sRenderer = renderer as? SampleBufferViewRenderer {
                setBounds(renderer: sRenderer, bounds: bounds)
            }
        }
    }
    
#elseif os(macOS)
    override public var frame: NSRect {
            didSet {
                let renderer = self.renderer
                if let pRenderer = renderer as? PreviewViewRender {
                    setBounds(renderer: pRenderer, bounds: bounds)
                }
                if let sRenderer = renderer as? SampleBufferViewRenderer {
                    setBounds(renderer: sRenderer, bounds: bounds)
                }
            }
        }
#endif
    
    private func setBounds(renderer: PreviewViewRender, bounds: CGRect) {
        renderer.bounds = bounds
    }
    
    private func setBounds(renderer: SampleBufferViewRenderer, bounds: CGRect) {
        renderer.bounds = bounds
    }
    
    let ciContext: CIContext
    let contextName: String
    
#if os(iOS)
    var captureView: UIView?
#elseif os(macOS)
    var captureView: NSView?
#endif
    
    public init (
        type: ViewType,
        contextName: String,
        logger: NeedleTailLogger = NeedleTailLogger("NTMTKView")
    ) throws {
        self.type = type
        self.contextName = contextName
        self.logger = logger
        
        // Safely get Metal device
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            logger.log(level: .error, message: "Metal device not available")
            throw NTMTKViewError.metalDeviceNotAvailable
        }
        self.mtlDevice = mtlDevice
        
        // Create CIContext with safe unwrapping
        ciContext = CIContext(
            mtlDevice: mtlDevice,
            options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false,
                .name: contextName
            ]
        )
        
        super.init(frame: .zero, device: mtlDevice)
        
        delegate = mtkViewDelegateWrapper
        self.device = mtlDevice
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = false
        
        // Create initial texture descriptor for later use
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        textureDescriptor.storageMode = .private
        
        // Create texture without try-catch since makeTexture doesn't throw
        texture = mtlDevice.makeTexture(descriptor: textureDescriptor)
        if texture == nil {
            logger.log(level: .warning, message: "Failed to create initial texture")
        }
    }
    
    var shouldRenderOnMetal: Bool = false {
        didSet {
            if let pRenderer = renderer as? PreviewViewRender {
                pRenderer.setShouldRenderOnMetal(shouldRenderOnMetal)
            }
            if !shouldRenderOnMetal {
                guard let captureView else { return }
                addSubview(captureView)
                
                captureView.anchors(
                    top: topAnchor,
                    leading: leadingAnchor,
                    bottom: bottomAnchor,
                    trailing: trailingAnchor)
            } else {
                if let previewCaptureView = subviews.first(where: { $0 is PreviewCaptureView }) {
                    previewCaptureView.removeFromSuperview()
                }
            }
        }
    }
    
    func startRendering() async {
        switch type {
        case .preview:
            let view = PreviewCaptureView()
            let layer = view.layer as! AVCaptureVideoPreviewLayer
            captureView = view
            let renderer = await PreviewViewRender(
                layer: layer,
                ciContext: ciContext,
                bounds: bounds)
            
            await renderer.setDelegate(self)
            self.renderer = renderer
            shouldRenderOnMetal = false

        case .sample:
            let view = SampleCaptureView()
            self.addSubview(view)
            view.anchors(
                top: topAnchor,
                leading: leadingAnchor,
                bottom: bottomAnchor,
                trailing: trailingAnchor)
#if os(iOS)
            sendSubviewToBack(view)
#endif
            let layer = view.layer as! AVSampleBufferDisplayLayer
            layer.videoGravity = .resizeAspectFill
            let renderer = SampleBufferViewRenderer(
                layer: layer,
                ciContext: ciContext,
                bounds: self.bounds
            )
            
            await renderer.setDelegate(self)
            await renderer.startStream()
            self.renderer = renderer
        }
        
        if streamTask?.isCancelled == false { streamTask?.cancel() }
        streamTask = Task(priority: .high) { @MainActor [weak self] in
            guard let self else { return }
            guard let metalCommandQueue = mtlDevice?.makeCommandQueue() else { 
                self.logger.log(level: .error, message: "Failed to create Metal command queue")
                return 
            }
            do {
                try await self.startMetalStream(
                    ciContext: ciContext,
                    metalCommandQueue: metalCommandQueue
                )
            } catch {
                logger.log(level: .error, message: "Metal stream error: \(error)")
            }
        }
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        // Clean up resources synchronously in deinit
        streamContinuation?.finish()
        streamContinuation = nil
        streamTask?.cancel()
        streamTask = nil
        renderer = nil
        texture = nil
        self.logger.log(level: .debug, message: "Reclaimed memory in NTMTKView\n Type - \(type)")
    }
    
    func startMetalStream(
        ciContext: CIContext,
        metalCommandQueue: MTLCommandQueue
    ) async throws {
        let stream = AsyncStream<MTKView?>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.streamContinuation = continuation
            
            mtkViewDelegateWrapper.capturedView = { packet in
                if let packet = packet {
                    continuation.yield(packet)
                } else {
                    continuation.yield(nil)
                }
            }
            continuation.onTermination = { [weak self] status in
                guard let self else { return }
                self.logger.log(level: .debug, message: "Metal View Stream terminated with status \(status)")
            }
        }
        
        for await _ in stream {
            await self.handleOutputStream(metalCommandQueue)
        }
    }
    
    func shutdownMetalStream() {
        streamContinuation?.finish()
        streamContinuation = nil
        streamTask?.cancel()
        streamTask = nil
        renderer = nil
        texture = nil
    }
    
    private func handleOutputStream(_ metalCommandQueue: MTLCommandQueue) async {
        guard let commandBuffer = metalCommandQueue.makeCommandBuffer(),
              let texture = self.texture,
              let currentDrawable = self.currentDrawable,
              let renderPassDescriptor = self.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let renderPipelineState = self.renderPipelineState
        else {
            return
        }
    
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
//        await commandBuffer.completed()
        commandBuffer.waitUntilCompleted()
    }
    
    func passTexture(texture: any MTLTexture) async throws {
        self.texture = texture
        drawableSize = self.bounds.size
        draw()
    }
}

protocol RendererDelegate: AnyObject,  Sendable {}
#endif
