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
import QuartzCore
import WebRTC
import NeedleTailLogger
import NeedleTailMediaKit
#if os(macOS)
@preconcurrency import AppKit
#endif

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
    private static let isMetalDiagnosticLoggingEnabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["PQSRTC_METAL_DIAGNOSTICS"] == "1"
        #endif
    }()
    
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
    private lazy var metalCommandQueue: MTLCommandQueue? = mtlDevice?.makeCommandQueue()
    private var library: MTLLibrary?
    private let mtkViewDelegateWrapper = MTKViewDelegateWrapper()
    private let logger: NeedleTailLogger
    private let type: ViewType
    private var texture: MTLTexture?
    private var streamTask: Task<Void, Error>?
    private var streamContinuation: AsyncStream<MTKView?>.Continuation?
    @MainActor private var metalDrawInFlight = false
    @MainActor private var metalDrawPending = false
    @MainActor private var metalDrawInFlightSinceUptimeNs: UInt64 = 0
    @MainActor private var lastInFlightRecoveryUptimeNs: UInt64 = 0
    /// Coalesced retry when `CAMetalLayer` has no drawable yet (common during live window resize).
    @MainActor private var metalDrawableRetryScheduled = false
    /// AppKit can briefly report a zero `bounds` while the superview is resizing; keep sizing stable.
    @MainActor private var lastNonZeroBoundsSize: CGSize = .zero
    /// Throttle for `[contextName] …` Metal diagnostics (resize can fire hundreds of times/sec).
    @MainActor private var lastMetalDiagnosticLogUptimeNs: UInt64 = 0
    @MainActor private var lastDrawableSizeDiagnosticLogUptimeNs: UInt64 = 0
    /// Resize can complete while remote ingress is stalled. Keep re-presenting the last texture for a short burst
    /// so the frame remains visible at the new size even without fresh WebRTC callbacks.
    @MainActor private var postResizeRedrawTask: Task<Void, Never>?
    /// Remote (`.sample`) + Metal: last `passTexture` bind vs last successful `present`+`commit`.
    @MainActor private var lastRemoteTextureReceivedUptimeNs: UInt64 = 0
    @MainActor private var lastRemoteMetalPresentCommittedUptimeNs: UInt64 = 0
    private var remoteVideoPresentWatchdogTask: Task<Void, Never>?
    /// Strong reference to the active renderer.
    ///
    /// This must NOT be `weak`. The renderer owns the `RTCVideoRenderWrapper` that the WebRTC
    /// track retains, but the renderer's stream/task lifecycle is tied to the renderer instance.
    /// If this were weak, the renderer could be deallocated immediately after `startRendering()`,
    /// resulting in "track attached, but no frames rendered".
    var renderer: RendererDelegate?
    
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
    /// AppKit frequently applies layout through `setFrameSize` / `layout` without touching the Swift
    /// `frame` property observer, so we mirror bounds into renderers from those paths as well.
    override public var frame: NSRect {
        didSet {
            syncEmbeddedCaptureViewBounds()
            scheduleRendererBoundsPropagation()
        }
    }
    
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncEmbeddedCaptureViewBounds()
        scheduleRendererBoundsPropagation()
    }
    
    override public func layout() {
        super.layout()
        syncEmbeddedCaptureViewBounds()
        scheduleRendererBoundsPropagation()
    }

    /// AppKit can invoke `draw(_:)` on layer-backed views during resize; MTKView’s default path
    /// may touch the same `CAMetalLayer` drawable queue as our manual `present`, producing
    /// “drawable can only be presented once” / post-present `.texture` faults.
    override public func draw(_ dirtyRect: NSRect) {
        // Frames are presented from `handleOutputStream` via `CAMetalLayer.nextDrawable`.
    }

    /// When the local preview is detached from the collection view into PiP, AppKit can keep the
    /// embedded capture view at its old size even though `NTMTKView` itself has already resized.
    /// Force the child preview subtree to match the wrapper bounds on every layout pass.
    private func syncEmbeddedCaptureViewBounds() {
        guard let captureView else { return }
        guard captureView.frame != bounds else {
            if let previewCaptureView = captureView as? PreviewCaptureView,
               previewCaptureView.previewLayer.frame != previewCaptureView.bounds {
                previewCaptureView.previewLayer.frame = previewCaptureView.bounds
            }
            return
        }

        captureView.frame = bounds
        captureView.layer?.frame = captureView.bounds
        if let previewCaptureView = captureView as? PreviewCaptureView {
            previewCaptureView.previewLayer.frame = previewCaptureView.bounds
        }
    }
    
    /// Pushes `bounds` into preview/remote renderers. Uses `Task` because renderers are `actor`s.
    private func scheduleRendererBoundsPropagation() {
        let rect = bounds
        if let pRenderer = renderer as? PreviewViewRender {
            Task { await pRenderer.setBounds(rect) }
        }
        if let sRenderer = renderer as? SampleBufferViewRenderer {
            Task { await sRenderer.applyHostViewBounds(rect) }
        }
        requestDrawIfPossible()
        schedulePostResizeRedrawBurstIfNeeded()
    }
#endif
    
    private func setBounds(renderer: PreviewViewRender, bounds: CGRect) {
        Task { await renderer.setBounds(bounds) }
    }
    
    private func setBounds(renderer: SampleBufferViewRenderer, bounds: CGRect) {
        Task { await renderer.applyHostViewBounds(bounds) }
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
#if os(macOS)
        // Default AppKit `NSView` uses translating autoresizing masks into constraints; that produces
        // implicit width/height ties to the superview and Auto Layout will break our explicit PiP size.
        translatesAutoresizingMaskIntoConstraints = false
        autoresizingMask = []
#endif
        delegate = mtkViewDelegateWrapper
        self.device = mtlDevice
        isPaused = true
        enableSetNeedsDisplay = false
        // Drawable sizing is driven by `requestDrawIfPossible()` (`drawableSize`), not MTKView auto-resize.
        // (`autoresizesDrawable` is unavailable in some SwiftPM / SDK combinations this package builds with.)
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
#if os(macOS)
            translatesAutoresizingMaskIntoConstraints = false
            autoresizingMask = []
#endif
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
#if os(macOS)
            translatesAutoresizingMaskIntoConstraints = false
            autoresizingMask = []
#endif
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
            // Demand-driven Metal: each frame calls `requestDrawIfPossible()` → `handleOutputStream`,
            // which acquires `currentDrawable` and presents explicitly.
            //
            // **Do not** set `enableSetNeedsDisplay = true` here: that makes MTKView schedule
            // `draw(in:)` on the same CAMetalLayer. Combined with our manual present, macOS logs
            // "Each CAMetalLayerDrawable can only be presented once" and WebRTC sinks can stall.
            isPaused = true
            enableSetNeedsDisplay = false
            // Clear delegate while we own the full `currentDrawable` → encode → `present` cycle so
            // MTKView does not invoke `draw(in:)` on the same CAMetalLayer (legacy `startMetalStream`
            // is unused in production; it temporarily reattaches the wrapper if needed).
            delegate = shouldRenderOnMetal ? nil : mtkViewDelegateWrapper
            if let pRenderer = renderer as? PreviewViewRender {
                pRenderer.setShouldRenderOnMetal(shouldRenderOnMetal)
            }
            // Keep the remote/sample renderer's output mode in sync with the view mode.
            // - shouldRenderOnMetal == true  -> renderer should output Metal textures
            // - shouldRenderOnMetal == false -> renderer should output CMSampleBuffer to AVSampleBufferDisplayLayer
            if let sRenderer = renderer as? SampleBufferViewRenderer {
                sRenderer.passPause(!shouldRenderOnMetal)
            }
            if !shouldRenderOnMetal {
                guard let captureView else { return }
                if captureView.superview !== self {
                    addSubview(captureView)
                    captureView.anchors(
                        top: topAnchor,
                        leading: leadingAnchor,
                        bottom: bottomAnchor,
                        trailing: trailingAnchor)
                }
#if os(macOS)
                syncEmbeddedCaptureViewBounds()
#endif
            } else {
                // Remove the embedded view from layout, but do not detach the preview capture session here.
                // `PreviewViewRender` still owns capture through the `AVCaptureVideoPreviewLayer`, and
                // clearing `previewLayer.session` during a Metal-mode switch invalidates the active
                // `AVCaptureSession` before local capture has finished starting.
                //
                // Session teardown still happens in `shutdownMetalStream()` / `tearDownPreviewView()`.
                captureView?.removeFromSuperview()
                requestDrawIfPossible()
            }
            if type == .sample {
                if shouldRenderOnMetal {
                    ensureRemoteVideoPresentWatchdogIfNeeded()
                } else {
                    cancelRemoteVideoPresentWatchdog()
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
#if os(macOS)
            superview?.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()
            scheduleRendererBoundsPropagation()
#endif
            shouldRenderOnMetal = true

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
            let layerBox = SampleBufferDisplayLayerBox(layer: layer)
            let renderer = SampleBufferViewRenderer(
                layerBox: layerBox,
                ciContext: ciContext,
                bounds: self.bounds
            )
            
            await renderer.setDelegate(self)
            await renderer.startStream()
            self.renderer = renderer
            self.logger.log(level: .debug, message: "Sample renderer installed (strong ref) and stream started")
#if os(macOS)
            // Collection view / SwiftUI may not have laid out yet; still push whatever bounds we have and
            // rely on `layout`/`setFrameSize` to update once the cell gets a real size.
            superview?.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()
            scheduleRendererBoundsPropagation()
#endif
            shouldRenderOnMetal = true
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
#if os(macOS)
        translatesAutoresizingMaskIntoConstraints = false
        autoresizingMask = []
#endif
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
        remoteVideoPresentWatchdogTask?.cancel()
        remoteVideoPresentWatchdogTask = nil
        postResizeRedrawTask?.cancel()
        postResizeRedrawTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        streamTask?.cancel()
        streamTask = nil
        renderer = nil
        texture = nil
        self.logger.log(level: .debug, message: "Reclaimed memory in NTMTKView\n Type - \(type)")
    }
    
    /// Legacy async draw-stream path retained for reference; production rendering now renders directly
    /// from `requestDrawIfPossible()` to avoid presenting stale drawables during live resize.
    func startMetalStream(
        ciContext: CIContext,
        metalCommandQueue: MTLCommandQueue
    ) async throws {
        await MainActor.run { [weak self] in
            // Legacy path is driven by `MTKViewDelegate.draw(in:)`; restore delegate if callers use this API.
            self?.delegate = self?.mtkViewDelegateWrapper
        }
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
            self.handleOutputStream(metalCommandQueue)
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

        if let previewCaptureView = captureView as? PreviewCaptureView {
            if Thread.isMainThread {
                previewCaptureView.removeSession()
            } else {
                DispatchQueue.main.async {
                    previewCaptureView.removeSession()
                }
            }
        }

        captureView?.removeFromSuperview()
        captureView = nil
        renderer = nil
        texture = nil
        lastNonZeroBoundsSize = .zero
        metalDrawableRetryScheduled = false
        lastMetalDiagnosticLogUptimeNs = 0
        lastDrawableSizeDiagnosticLogUptimeNs = 0
        metalDrawInFlight = false
        metalDrawPending = false
        metalDrawInFlightSinceUptimeNs = 0
        lastInFlightRecoveryUptimeNs = 0
        cancelRemoteVideoPresentWatchdog()
        postResizeRedrawTask?.cancel()
        postResizeRedrawTask = nil
    }

    @MainActor
    private func cancelRemoteVideoPresentWatchdog() {
        remoteVideoPresentWatchdogTask?.cancel()
        remoteVideoPresentWatchdogTask = nil
        lastRemoteTextureReceivedUptimeNs = 0
        lastRemoteMetalPresentCommittedUptimeNs = 0
    }

    /// Detects “textures still reach `NTMTKView` but `CAMetalLayer` never successfully presents” (e.g. drawable starvation during resize).
    @MainActor
    private func ensureRemoteVideoPresentWatchdogIfNeeded() {
        guard type == .sample, shouldRenderOnMetal else { return }
        guard remoteVideoPresentWatchdogTask == nil || remoteVideoPresentWatchdogTask?.isCancelled == true else { return }
        remoteVideoPresentWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkRemoteVideoPresentStall()
            }
        }
    }

    @MainActor
    private func checkRemoteVideoPresentStall() {
        guard type == .sample, shouldRenderOnMetal, texture != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        func ms(since t: UInt64) -> Int64 {
            guard t > 0, now >= t else { return -1 }
            return Int64((now - t) / 1_000_000)
        }
        let texMs = ms(since: lastRemoteTextureReceivedUptimeNs)
        let presMs = ms(since: lastRemoteMetalPresentCommittedUptimeNs)
        guard lastRemoteTextureReceivedUptimeNs > 0, texMs >= 0, texMs < 1_200 else { return }
        if presMs < 0 || presMs > 2_000 {
            logMetalDiagnostic(
                "REMOTE DISPLAY STALL: passTexture still fresh (~\(texMs)ms ago) but CAMetalLayer present+commit stale (last=\(presMs < 0 ? "never" : "\(presMs)ms")) bounds=\(bounds.size) drawableSize=\(drawableSize)",
                intervalNs: 800_000_000
            )
        }
    }

    /// Logs at most once per `intervalNs` (resize storms otherwise bury Console).
    @MainActor
    private func logMetalDiagnostic(_ message: String, intervalNs: UInt64 = 300_000_000) {
        guard Self.isMetalDiagnosticLoggingEnabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastMetalDiagnosticLogUptimeNs >= intervalNs else { return }
        lastMetalDiagnosticLogUptimeNs = now
        logger.log(
            level: .debug,
            message: "[NTMTKView context=\(contextName) type=\(type)] \(message)"
        )
    }

    @MainActor
    private func logDrawableSizeChange(_ newPixelSize: CGSize) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastDrawableSizeDiagnosticLogUptimeNs >= 500_000_000 else { return }
        lastDrawableSizeDiagnosticLogUptimeNs = now
#if os(macOS)
        let contentsScaleForLog = layer?.contentsScale ?? 1
        let liveResize = (window as? NSWindow)?.inLiveResize == true
#else
        let contentsScaleForLog = layer.contentsScale
        let liveResize = false
#endif
        logger.log(
            level: .info,
            message: "[NTMTKView context=\(contextName) type=\(type)] drawableSize=\(newPixelSize) boundsPoints=\(bounds.size) contentsScale=\(contentsScaleForLog) inLiveResize=\(liveResize)"
        )
    }

    /// Compact layout snapshot for Metal diagnostics (resize / coalescing / drawable starvation).
    @MainActor
    private func metalLayoutDebugSuffix() -> String {
#if os(macOS)
        let live = (window as? NSWindow)?.inLiveResize == true
        let wsz = window?.frame.size ?? .zero
        let sup = superview?.bounds.size ?? .zero
        return " inLiveResize=\(live) windowFrame=\(wsz) frame=\(frame.size) superBounds=\(sup) hidden=\(isHidden) alpha=\(alphaValue)"
#else
        let wsz = window?.bounds.size ?? .zero
        let sup = superview?.bounds.size ?? .zero
        return " windowBounds=\(wsz) frame=\(frame.size) superBounds=\(sup) hidden=\(isHidden) alpha=\(alpha)"
#endif
    }

    @MainActor
    private func metalInFlightAgeMs() -> Int64 {
        guard metalDrawInFlightSinceUptimeNs > 0 else { return -1 }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= metalDrawInFlightSinceUptimeNs else { return -1 }
        return Int64((now - metalDrawInFlightSinceUptimeNs) / 1_000_000)
    }
    
    @MainActor
    private func scheduleMetalDrawableRetryIfNeeded() {
        guard shouldRenderOnMetal, texture != nil, metalDrawableRetryScheduled == false else { return }
        metalDrawableRetryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metalDrawableRetryScheduled = false
            self.requestDrawIfPossible()
        }
    }

    @MainActor
    private func schedulePostResizeRedrawBurstIfNeeded() {
        guard type == .sample, shouldRenderOnMetal, texture != nil else { return }
        postResizeRedrawTask?.cancel()
        postResizeRedrawTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Backoff attempts so we repaint after AppKit/CAMetalLayer settles.
            let retryNs: [UInt64] = [16_000_000, 33_000_000, 66_000_000, 120_000_000, 200_000_000]
            for delay in retryNs {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                self.requestDrawIfPossible()
            }
        }
    }

    /// Acquires a **fresh** drawable from the view’s `CAMetalLayer` instead of `MTKView.currentDrawable`.
    /// The latter can return a drawable MTKView has already presented or that conflicts with internal
    /// MTKView bookkeeping, which matches the “texture after present” / “presented once” runtime errors.
    @MainActor
    private func acquireDrawableForPresent() -> CAMetalDrawable? {
        guard let metalLayer = layer as? CAMetalLayer else { return nil }
        let ds = drawableSize
        guard ds.width >= 1, ds.height >= 1 else { return nil }
        if metalLayer.drawableSize != ds {
            metalLayer.drawableSize = ds
        }
        return metalLayer.nextDrawable()
    }

    /// `requestDrawIfPossible()` sets `metalDrawInFlight` before layout-heavy work; this method must clear it on failure and via the command buffer completion handler on success.
    @MainActor
    private func handleOutputStream(_ metalCommandQueue: MTLCommandQueue) {
        guard let texture = self.texture,
              let renderPipelineState = self.renderPipelineState
        else {
            metalDrawInFlight = false
            return
        }

        if metalDrawInFlight == false {
            // `requestDrawIfPossible` normally reserves before layout; legacy `startMetalStream` does not.
            metalDrawInFlight = true
            metalDrawInFlightSinceUptimeNs = DispatchTime.now().uptimeNanoseconds
        }

        let commandBuffer = metalCommandQueue.makeCommandBuffer()
        guard let cb = commandBuffer else {
            metalDrawInFlight = false
            if shouldRenderOnMetal {
                let layerReady = (layer as? CAMetalLayer) != nil && drawableSize.width >= 1 && drawableSize.height >= 1
                logMetalDiagnostic(
                    "Metal present deferred (coalesced main-queue retry): metalLayerReady=\(layerReady) renderPassDesc=n/a commandBuffer=false bounds=\(bounds.size) drawableSize=\(drawableSize) inFlight=\(metalDrawInFlight) pending=\(metalDrawPending) window=\(window != nil)"
                )
                scheduleMetalDrawableRetryIfNeeded()
            }
            return
        }

        guard let drawable = acquireDrawableForPresent() else {
            metalDrawInFlight = false
            if shouldRenderOnMetal {
                logMetalDiagnostic(
                    "Metal present deferred (coalesced main-queue retry): drawable=false renderPassDesc=n/a commandBuffer=true bounds=\(bounds.size) drawableSize=\(drawableSize) inFlight=\(metalDrawInFlight) pending=\(metalDrawPending) window=\(window != nil)"
                )
                scheduleMetalDrawableRetryIfNeeded()
            }
            return
        }

        // Use exactly one drawable reference for the color attachment and `present`.
        // `currentRenderPassDescriptor` can route through MTKView internals that also touch the
        // layer’s drawable queue and has been associated with “texture after present” faults.
        let drawableTexture = drawable.texture
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawableTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .dontCare
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = cb.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            metalDrawInFlight = false
            if shouldRenderOnMetal {
                logMetalDiagnostic("Metal present deferred: failed to create render encoder bounds=\(bounds.size) drawableSize=\(drawableSize)")
                scheduleMetalDrawableRetryIfNeeded()
            }
            return
        }

        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        cb.addCompletedHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.metalDrawInFlight = false
                self.metalDrawInFlightSinceUptimeNs = 0
                if self.metalDrawPending {
                    self.metalDrawPending = false
                    self.requestDrawIfPossible()
                }
            }
        }
        cb.present(drawable)
        cb.commit()
        if type == .sample {
            lastRemoteMetalPresentCommittedUptimeNs = DispatchTime.now().uptimeNanoseconds
        }
    }

    @MainActor
    private func currentDrawableSize() -> CGSize? {
        guard shouldRenderOnMetal, window != nil else { return nil }
        
        var pointSize = bounds.size
        let finite = pointSize.width.isFinite && pointSize.height.isFinite
        // During live window resize, AppKit can briefly report `.zero` bounds while `frame` still
        // carries the visible size; using only `lastNonZeroBoundsSize` then pins the drawable to a
        // stale small rect (remote/preview tiles stay letterboxed).
        if (!finite || pointSize.width <= 0 || pointSize.height <= 0) {
            let fs = frame.size
            if fs.width.isFinite, fs.height.isFinite, fs.width > 0, fs.height > 0 {
                pointSize = fs
            }
        }
        let finiteAfterFrame = pointSize.width.isFinite && pointSize.height.isFinite
        if finiteAfterFrame, pointSize.width > 0, pointSize.height > 0 {
            lastNonZeroBoundsSize = pointSize
        } else if lastNonZeroBoundsSize.width > 0, lastNonZeroBoundsSize.height > 0 {
            logMetalDiagnostic(
                "Drawable sizing: invalid live bounds \(bounds.size) — using lastNonZero \(lastNonZeroBoundsSize)"
            )
            pointSize = lastNonZeroBoundsSize
        } else {
            return nil
        }
        
        var scale: CGFloat = 1
#if os(macOS)
        scale = layer?.contentsScale ?? 1
#else
        scale = layer.contentsScale
#endif
        // `contentsScale` or transient layout can be non-finite; multiplying into pixel size then
        // `Int(ceil(...))` traps with "Double value cannot be converted to Int … infinite or NaN".
        if !scale.isFinite || scale <= 0 {
            scale = 1
        }
        let pixelW = pointSize.width * scale
        let pixelH = pointSize.height * scale
        guard pixelW.isFinite, pixelH.isFinite, pixelW > 0, pixelH > 0 else {
            logMetalDiagnostic(
                "Drawable sizing: non-finite pixel size point=\(pointSize) scale=\(scale) pixel=(\(pixelW), \(pixelH))"
            )
            return nil
        }
        let ceiledW = ceil(pixelW)
        let ceiledH = ceil(pixelH)
        guard ceiledW.isFinite, ceiledH.isFinite else { return nil }
        // Avoid `Int` overflow if dimensions are pathologically large.
        let maxDrawable: CGFloat = 32768
        let clampedW = min(ceiledW, maxDrawable)
        let clampedH = min(ceiledH, maxDrawable)
        guard clampedW <= Double(Int.max), clampedH <= Double(Int.max) else { return nil }

        let width = max(1, Int(clampedW))
        let height = max(1, Int(clampedH))
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    @MainActor
    private func requestDrawIfPossible() {
        guard texture != nil else { return }
        if metalDrawInFlight {
            let now = DispatchTime.now().uptimeNanoseconds
            if metalDrawInFlightSinceUptimeNs > 0, now >= metalDrawInFlightSinceUptimeNs {
                let inFlightMs = Int64((now - metalDrawInFlightSinceUptimeNs) / 1_000_000)
                // Self-heal if GPU completion never arrives (observed as endless inFlight coalescing + frozen remote tile).
                if inFlightMs > 1_500, now &- lastInFlightRecoveryUptimeNs >= 1_200_000_000 {
                    lastInFlightRecoveryUptimeNs = now
                    logMetalDiagnostic(
                        "Recovering stuck inFlight draw after \(inFlightMs)ms; forcing draw reservation reset (bounds=\(bounds.size), drawableSize=\(drawableSize))\(metalLayoutDebugSuffix())",
                        intervalNs: 300_000_000
                    )
                    metalDrawInFlight = false
                    metalDrawInFlightSinceUptimeNs = 0
                }
            }
        }
        guard metalDrawInFlight == false else {
            let priorPending = metalDrawPending
            metalDrawPending = true
            let age = metalInFlightAgeMs()
            logMetalDiagnostic(
                "Metal draw coalesced (inFlight ~\(age)ms); will present after GPU completes. priorPending=\(priorPending) bounds=\(bounds.size) drawableSize=\(drawableSize) lastNonZeroBounds=\(lastNonZeroBoundsSize)\(metalLayoutDebugSuffix())",
                intervalNs: 400_000_000
            )
            return
        }
        // Reserve before `currentDrawableSize()` / `drawableSize` — they can trigger layout → nested
        // `requestDrawIfPossible` and would otherwise double-acquire the same CAMetalLayer drawable.
        metalDrawInFlight = true
        metalDrawInFlightSinceUptimeNs = DispatchTime.now().uptimeNanoseconds
        guard let targetDrawableSize = currentDrawableSize() else {
            metalDrawInFlight = false
            metalDrawInFlightSinceUptimeNs = 0
            // No window (e.g. view detached while closing) → nil drawable size is expected; avoid warning spam.
            if shouldRenderOnMetal, window != nil {
                logMetalDiagnostic(
                    "Cannot compute drawable pixel size: bounds=\(bounds.size) lastNonZero=\(lastNonZeroBoundsSize) window=\(window != nil) shouldRenderOnMetal=\(shouldRenderOnMetal)"
                )
            }
            return
        }
        if abs(targetDrawableSize.width - drawableSize.width) > 0.5
            || abs(targetDrawableSize.height - drawableSize.height) > 0.5 {
            drawableSize = targetDrawableSize
            logDrawableSizeChange(targetDrawableSize)
        }
        guard let metalCommandQueue else {
            metalDrawInFlight = false
            metalDrawInFlightSinceUptimeNs = 0
            logger.log(level: .error, message: "Failed to create Metal command queue")
            return
        }
        handleOutputStream(metalCommandQueue)
    }
    
    /// Receives an updated frame texture from the renderer.
    func passTexture(texture: any MTLTexture) async throws {
        await MainActor.run {
            self.texture = texture
            if type == .sample {
                lastRemoteTextureReceivedUptimeNs = DispatchTime.now().uptimeNanoseconds
                ensureRemoteVideoPresentWatchdogIfNeeded()
            }
            requestDrawIfPossible()
        }
    }
}

protocol RendererDelegate: AnyObject,  Sendable {}
#endif
