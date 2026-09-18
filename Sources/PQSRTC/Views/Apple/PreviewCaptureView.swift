//
//  PreviewCaptureView.swift
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
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
//

#if os(iOS) || os(macOS)
import AVKit
import NeedleTailLogger

/// Lets deinit hop an `AVCaptureVideoPreviewLayer` to the main queue without a retroactive Sendable conformance.
private struct PreviewLayerTeardown: @unchecked Sendable {
    let layer: AVCaptureVideoPreviewLayer?
}

#if os(iOS)
import UIKit

/// A UIView subclass that provides a preview layer for AVCaptureSession
/// Optimized for production use with proper memory management and error handling
internal class PreviewCaptureView: UIView {
    
    // MARK: - Properties
    
    /// The underlying AVCaptureVideoPreviewLayer
    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    nonisolated(unsafe) private var didShutdown = false
    nonisolated(unsafe) private var sessionPreviewLayer: AVCaptureVideoPreviewLayer?
    /// Logger for production debugging
    private let logger: NeedleTailLogger
    
    // MARK: - Initialization
    
    override init(frame: CGRect) {
        self.logger = NeedleTailLogger("[PreviewCaptureView]")
        super.init(frame: frame)
        setupPreviewLayer()
    }
    
    required init?(coder: NSCoder) {
        self.logger = NeedleTailLogger("[PreviewCaptureView]")
        super.init(coder: coder)
        setupPreviewLayer()
    }
    
    // MARK: - Layer Configuration
    
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    private func setupPreviewLayer() {
        sessionPreviewLayer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection {
            if #available(iOS 17.0, *) {
                connection.videoRotationAngle = 0
            } else {
                connection.videoOrientation = .portrait
            }
        }
        
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView initialized with frame: \(frame)")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Configures the preview layer with a capture session
    /// - Parameter session: The AVCaptureSession to display
    func configure(with session: AVCaptureSession) {
        // UIView is main actor bound, so we can directly set the session
        previewLayer.session = session
        
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView configured with session")
        #endif
    }
    
    /// Removes the capture session from the preview layer
    func removeSession() {
        // UIView is main actor bound, so we can directly set the session
        previewLayer.session = nil
        didShutdown = true
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView session removed")
        #endif
    }
    
    // MARK: - Memory Management
    
    deinit {
        // Be defensive: if a caller forgets to remove the session, ensure we don't keep
        // the capture session attached to a deallocating preview layer.
        let wasShutdown = didShutdown
        if !didShutdown {
            didShutdown = true
            let teardown = PreviewLayerTeardown(layer: sessionPreviewLayer)
            sessionPreviewLayer = nil
            if Thread.isMainThread {
                teardown.layer?.session = nil
            } else {
                // Avoid blocking here. Deinit can occur on WebRTC/crypto queues; synchronously
                // waiting for main can cause watchdog "hang detected" and can deadlock if main is
                // awaiting teardown work scheduled from those same queues.
                DispatchQueue.main.async {
                    teardown.layer?.session = nil
                }
            }
        }
        #if DEBUG
        if !wasShutdown {
            logger.log(level: .warning, message: "PreviewCaptureView deallocated before explicit shutdown; removed session defensively")
        }
        logger.log(level: .debug, message: "PreviewCaptureView deallocated")
        #endif
    }
}

#elseif os(macOS)
import AppKit

/// A NSView subclass that provides a preview layer for AVCaptureSession
/// Optimized for production use with proper memory management and error handling
internal class PreviewCaptureView: NSView {
    
    // MARK: - Properties
    
    /// The underlying AVCaptureVideoPreviewLayer
    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    nonisolated(unsafe) private var sessionPreviewLayer: AVCaptureVideoPreviewLayer?
    
    /// Logger for production debugging
    private let logger: NeedleTailLogger
    
    // MARK: - Initialization
    
    override init(frame frameRect: NSRect) {
        self.logger = NeedleTailLogger("[PreviewCaptureView]")
        super.init(frame: frameRect)
        setupPreviewLayer()
    }
    
    required init?(coder: NSCoder) {
        self.logger = NeedleTailLogger("[PreviewCaptureView]")
        super.init(coder: coder)
        setupPreviewLayer()
    }
    
    // MARK: - Layer Configuration
    
    private func setupPreviewLayer() {
        translatesAutoresizingMaskIntoConstraints = false
        autoresizingMask = []
        wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspect
        layer.masksToBounds = true
        self.layer = layer
        sessionPreviewLayer = layer
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView initialized with frame: \(frame)")
        #endif
    }
    
    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
    
    // MARK: - Public Methods
    
    /// Configures the preview layer with a capture session
    /// - Parameter session: The AVCaptureSession to display
    func configure(with session: AVCaptureSession) {
        // Capture the layer reference to avoid weak self issues during deallocation
        let teardown = PreviewLayerTeardown(layer: previewLayer)
        DispatchQueue.main.async {
            teardown.layer?.session = session
            
            #if DEBUG
            self.logger.log(level: .debug, message: "PreviewCaptureView configured with session")
            #endif
        }
    }
    
    /// Removes the capture session from the preview layer
    func removeSession() {
        // Capture the layer reference to avoid weak self issues during deallocation
        let teardown = PreviewLayerTeardown(layer: previewLayer)
        DispatchQueue.main.async {
            teardown.layer?.session = nil
            
            #if DEBUG
            self.logger.log(level: .debug, message: "PreviewCaptureView session removed")
            #endif
        }
    }
    
    // MARK: - Memory Management
    
    deinit {
        // NSView deinit may not be on main thread.
        // Avoid `DispatchQueue.main.sync` here: if deinit happens on main (or if the main
        // thread is blocked by WebRTC work), this can deadlock and trigger libdispatch breakpoints.
        let teardown = PreviewLayerTeardown(layer: sessionPreviewLayer)
        sessionPreviewLayer = nil
        if Thread.isMainThread {
            teardown.layer?.session = nil
        } else {
            DispatchQueue.main.async {
                teardown.layer?.session = nil
            }
        }
        
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView deallocated")
        #endif
    }
}
#endif
#endif
