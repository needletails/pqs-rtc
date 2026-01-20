//
//  SampleCaptureView.swift
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
    nonisolated(unsafe) private var didShutdown = false
    
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
            if self.sampleBufferLayer.status == .failed {
                self.logger.log(level: .warning, message: "AVSampleBufferDisplayLayer failed: \(String(describing: self.sampleBufferLayer.error)). Flushing.")
                self.sampleBufferLayer.flush()
            }
            self.sampleBufferLayer.enqueue(sampleBuffer)
        }
    }
    
    /// Flushes the sample buffer layer
    func flush() {
        shutdown()
    }

    /// Explicit teardown entrypoint.
    ///
    /// Avoid relying on `deinit` for UI/layer cleanup; call this from the owning view/controller
    /// while the view is still on screen.
    func shutdown() {
        didShutdown = true

        let flushWork = { @Sendable @MainActor [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.flush()
            #if DEBUG
            self.logger.log(level: .debug, message: "SampleCaptureView layer flushed")
            #endif
        }

        if Thread.isMainThread {
            flushWork()
        } else {
            DispatchQueue.main.async(execute: flushWork)
        }
    }
    
    // MARK: - Memory Management
    
    deinit {
        precondition(didShutdown , "didShutdown should be true upon SampleCaptureView deallocation")
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

    nonisolated(unsafe) private var didShutdown = false
    
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
            if self.sampleBufferLayer.status == .failed {
                self.logger.log(level: .warning, message: "AVSampleBufferDisplayLayer failed: \(String(describing: self.sampleBufferLayer.error)). Flushing.")
                self.sampleBufferLayer.flush()
            }
            self.sampleBufferLayer.enqueue(sampleBuffer)
        }
    }
    
    /// Flushes the sample buffer layer
    func flush() {
        shutdown()
    }

    /// Explicit teardown entrypoint.
    ///
    /// Avoid relying on `deinit` for UI/layer cleanup; call this from the owning view/controller.
    func shutdown() {
        didShutdown = true

        let flushWork = { @Sendable @MainActor [weak self] in
            guard let self else { return }
            self.sampleBufferLayer.flush()
            #if DEBUG
            self.logger.log(level: .debug, message: "SampleCaptureView layer flushed")
            #endif
        }

        if Thread.isMainThread {
            flushWork()
        } else {
            DispatchQueue.main.async(execute: flushWork)
        }
    }
    
    // MARK: - Memory Management
    
    deinit {
        precondition(didShutdown, "didShutdown should be true upon SampleCaptureView deallocation")
    }
}
#endif
#endif
