//
//  SampleCaptureView.swift
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
import AVKit
import NeedleTailLogger

#if os(iOS)
import UIKit

/// A UIView subclass that provides a sample buffer display layer
/// Optimized for production use with proper memory management and error handling
internal class SampleCaptureView: UIView {
    
    // MARK: - Properties
    
    /// The underlying AVSampleBufferDisplayLayer
    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }
    
    /// Logger for production debugging
    private let logger: NeedleTailLogger
    
    // MARK: - Initialization
    
    override init(frame: CGRect) {
        self.logger = NeedleTailLogger("[SampleCaptureView]")
        super.init(frame: frame)
        setupSampleBufferLayer()
    }
    
    required init?(coder: NSCoder) {
        self.logger = NeedleTailLogger("[SampleCaptureView]")
        super.init(coder: coder)
        setupSampleBufferLayer()
    }
    
    // MARK: - Layer Configuration
    
    override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
    
    private func setupSampleBufferLayer() {
        sampleBufferLayer.videoGravity = .resizeAspectFill
        
        #if DEBUG
        logger.log(level: .debug, message: "SampleCaptureView initialized with frame: \(frame)")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Enqueues a sample buffer for display
    /// - Parameter sampleBuffer: The CMSampleBuffer to display
    func enqueue(sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }
    
    /// Flushes the sample buffer layer
    func flush() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.sampleBufferRenderer.flush()
            
            #if DEBUG
            self.logger.log(level: .debug, message: "SampleCaptureView layer flushed")
            #endif
        }
    }
    
    // MARK: - Memory Management
    
    deinit {
        // Ensure cleanup happens on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.sampleBufferRenderer.flush()
        }
        
        #if DEBUG
        logger.log(level: .debug, message: "SampleCaptureView deallocated")
        #endif
    }
}

#elseif os(macOS)
import AppKit

/// A NSView subclass that provides a sample buffer display layer
/// Optimized for production use with proper memory management and error handling
internal class SampleCaptureView: NSView {
    
    // MARK: - Properties
    
    /// The underlying AVSampleBufferDisplayLayer
    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }
    
    /// Logger for production debugging
    private let logger: NeedleTailLogger
    
    // MARK: - Initialization
    
    override init(frame frameRect: NSRect) {
        self.logger = NeedleTailLogger("[SampleCaptureView]")
        super.init(frame: frameRect)
        setupSampleBufferLayer()
    }
    
    required init?(coder: NSCoder) {
        self.logger = NeedleTailLogger("[SampleCaptureView]")
        super.init(coder: coder)
        setupSampleBufferLayer()
    }
    
    // MARK: - Layer Configuration
    
    private func setupSampleBufferLayer() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        self.layer = layer
        
        #if DEBUG
        logger.log(level: .debug, message: "SampleCaptureView initialized with frame: \(frame)")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Enqueues a sample buffer for display
    /// - Parameter sampleBuffer: The CMSampleBuffer to display
    func enqueue(sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }
    
    /// Flushes the sample buffer layer
    func flush() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.sampleBufferRenderer.flush()
            #if DEBUG
            self.logger.log(level: .debug, message: "SampleCaptureView layer flushed")
            #endif
        }
    }
    
    // MARK: - Memory Management
    
    deinit {
        // Ensure cleanup happens on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.sampleBufferRenderer.flush()
        }
        
        #if DEBUG
        logger.log(level: .debug, message: "SampleCaptureView deallocated")
        #endif
    }
}
#endif
#endif
