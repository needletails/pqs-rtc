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
        #if DEBUG
        assert(didShutdown, "didShutdown should be true upon PreviewCaptureView deallocation")
        #endif

        // Be defensive: if a caller forgets to remove the session, ensure we don't keep
        // the capture session attached to a deallocating preview layer.
        if !didShutdown {
            if Thread.isMainThread {
                previewLayer.session = nil
            } else {
                DispatchQueue.main.sync {
                    self.previewLayer.session = nil
                }
            }
            didShutdown = true
        }
        #if DEBUG
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
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        self.layer = layer
        
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView initialized with frame: \(frame)")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Configures the preview layer with a capture session
    /// - Parameter session: The AVCaptureSession to display
    func configure(with session: AVCaptureSession) {
        // Capture the layer reference to avoid weak self issues during deallocation
        let layer = self.previewLayer
        DispatchQueue.main.async {
            layer.session = session
            
            #if DEBUG
            self.logger.log(level: .debug, message: "PreviewCaptureView configured with session")
            #endif
        }
    }
    
    /// Removes the capture session from the preview layer
    func removeSession() {
        // Capture the layer reference to avoid weak self issues during deallocation
        let layer = self.previewLayer
        DispatchQueue.main.async {
            layer.session = nil
            
            #if DEBUG
            self.logger.log(level: .debug, message: "PreviewCaptureView session removed")
            #endif
        }
    }
    
    // MARK: - Memory Management
    
    deinit {
        // NSView deinit may not be on main thread - use captured layer reference
        DispatchQueue.main.sync {
            let layer = self.previewLayer
            layer.session = nil
        }
        
        #if DEBUG
        logger.log(level: .debug, message: "PreviewCaptureView deallocated")
        #endif
    }
}
#endif
#endif
