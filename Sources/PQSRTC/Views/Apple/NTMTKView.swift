//
//  NTMTKView.swift
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
@preconcurrency import MetalKit
import WebRTC
import NeedleTailLogger
import NeedleTailMediaKit

protocol BufferToMetalDelegate: AnyObject, Sendable {
    /// Supplies a decoded video frame as an `MTLTexture` to be rendered.
    func passTexture(texture: MTLTexture) async throws
}

/// Metal-backed view used for video rendering on Apple platforms.
///
/// `NTMTKView` owns and coordinates:
/// - a capture/display subview (`PreviewCaptureView` / `SampleCaptureView`)
/// - a renderer (`PreviewViewRender` / `SampleBufferViewRenderer`)
/// - an optional Metal render loop that can blit the latest decoded texture
///
/// The call UI controllers create one instance per video stream:
/// - `.preview` for local camera preview
/// - `.sample` for remote/received video
public final class NTMTKView: MTKView, BufferToMetalDelegate {
    
    /// Declares the logical role of an `NTMTKView` in the call UI.
    public enum ViewType: Sendable {
        case sample, preview
    }
    
    /// Errors that can occur while configuring Metal rendering.
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
    /// Logical name used to tag the underlying `CIContext` and help debugging.
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

    /// Non-throwing initializer that attempts to configure Metal rendering if available,
    /// otherwise falls back to a software CIContext and a nil MTKView device.
    public init(
        fallbackType type: ViewType,
        contextName: String,
        logger: NeedleTailLogger = NeedleTailLogger("NTMTKView")
    ) {
        self.type = type
        self.contextName = contextName
        self.logger = logger

        let name = contextName.isEmpty ? "NTMTKView" : contextName
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            self.mtlDevice = mtlDevice
            self.ciContext = CIContext(
                mtlDevice: mtlDevice,
                options: [
                    .useSoftwareRenderer: false,
                    .cacheIntermediates: false,
                    .name: name
                ]
            )
            super.init(frame: .zero, device: mtlDevice)
            delegate = mtkViewDelegateWrapper
            self.device = mtlDevice
        } else {
            self.mtlDevice = nil
            self.ciContext = CIContext(
                options: [
                    .useSoftwareRenderer: true,
                    .cacheIntermediates: false,
                    .name: name
                ]
            )
            super.init(frame: .zero, device: nil)
            delegate = mtkViewDelegateWrapper
            self.device = nil
            logger.log(level: .warning, message: "Metal device not available; NTMTKView using software CIContext")
        }

        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = false

        if let mtlDevice = self.mtlDevice {
            let textureDescriptor = MTLTextureDescriptor()
            textureDescriptor.usage = [.shaderRead, .renderTarget]
            textureDescriptor.storageMode = .private
            texture = mtlDevice.makeTexture(descriptor: textureDescriptor)
            if texture == nil {
                logger.log(level: .warning, message: "Failed to create initial texture")
            }
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
    
    /// Creates the underlying capture/display view and starts the renderer.
    ///
    /// This method also starts a Metal stream task. When `shouldRenderOnMetal` is `false`,
    /// the view falls back to embedding the capture/display view directly.
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
            captureView = view
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
        let logger = NeedleTailLogger("NTMTKView")
        self.type = .sample
        self.contextName = "coder"
        self.logger = logger

        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            self.mtlDevice = mtlDevice
            self.ciContext = CIContext(
                mtlDevice: mtlDevice,
                options: [
                    .useSoftwareRenderer: false,
                    .cacheIntermediates: false,
                    .name: "coder"
                ]
            )
        } else {
            self.mtlDevice = nil
            self.ciContext = CIContext(
                options: [
                    .useSoftwareRenderer: true,
                    .cacheIntermediates: false,
                    .name: "coder"
                ]
            )
            logger.log(level: .warning, message: "Metal device not available in init(coder:); using software CIContext")
        }

        super.init(coder: coder)
        delegate = mtkViewDelegateWrapper
        device = mtlDevice
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = false

        if let mtlDevice = self.mtlDevice {
            let textureDescriptor = MTLTextureDescriptor()
            textureDescriptor.usage = [.shaderRead, .renderTarget]
            textureDescriptor.storageMode = .private
            texture = mtlDevice.makeTexture(descriptor: textureDescriptor)
        }
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
    
    /// Starts an internal async stream that triggers Metal rendering work.
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
    
    /// Stops rendering, shuts down capture/display views, and releases renderer resources.
    func shutdownMetalStream() {
        streamContinuation?.finish()
        streamContinuation = nil
        streamTask?.cancel()
        streamTask = nil

        if let sampleRenderer = renderer as? SampleBufferViewRenderer {
            Task { await sampleRenderer.shutdown() }
        } else if let previewRenderer = renderer as? PreviewViewRender {
            Task { await previewRenderer.stopCaptureSession() }
        }

        if let sampleCaptureView = captureView as? SampleCaptureView {
            sampleCaptureView.shutdown()
        }

        captureView?.removeFromSuperview()
        captureView = nil
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
        await commandBuffer.completed()
    }
    
    /// Receives an updated frame texture from the renderer.
    func passTexture(texture: any MTLTexture) async throws {
        self.texture = texture
        drawableSize = self.bounds.size
        draw()
    }
}

protocol RendererDelegate: AnyObject,  Sendable {}
#endif
