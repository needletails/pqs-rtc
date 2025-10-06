//  AndroidCaptureViews.swift
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

#if SKIP
import Foundation
import org.webrtc.__
import kotlin.__

// MARK: - Android Preview Capture View (Equivalent to PreviewCaptureView)
/// Android equivalent of PreviewCaptureView - provides local video preview
/// NeedleTailRTC calls into this view and handles all state management
public class AndroidPreviewCaptureView {
    
    // MARK: - Properties
    
    /// The underlying SurfaceViewRenderer for local video
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer {
        return _surfaceViewRenderer
    }
    
    /// Logger for production debugging
    private let _surfaceViewRenderer: org.webrtc.SurfaceViewRenderer
    
    // MARK: - Initialization
    
    public init() {
        self._surfaceViewRenderer = org.webrtc.SurfaceViewRenderer(ProcessInfo.processInfo.androidContext)
        // Initialize renderer with shared EGL and mirror for local preview
        RTCClient.shared.initializeSurfaceRenderer(self._surfaceViewRenderer, mirror: true)
    }
    
    // MARK: - Configuration
    
    /// Set mirror mode for local video (selfie view)
    public func setMirror(_ mirrored: Bool) {
        _surfaceViewRenderer.setMirror(mirrored)
    }
    
    /// Release resources
    public func release() {
        _surfaceViewRenderer.release()
    }

    /// Attach a local video track to this preview renderer
    public func attach(_ track: RTCVideoTrack) { RTCClient.shared.attach(track, to: _surfaceViewRenderer) }

    /// Detach a local video track from this preview renderer
    public func detach(_ track: RTCVideoTrack) {
        RTCClient.shared.detach(track, from: _surfaceViewRenderer)
    }
}

// MARK: - Android Sample Capture View (Equivalent to SampleCaptureView)
/// Android equivalent of SampleCaptureView - provides remote video rendering
/// NeedleTailRTC calls into this view and handles all state management
public class AndroidSampleCaptureView {
    
    // MARK: - Properties
    
    /// The underlying SurfaceViewRenderer for remote video
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer {
        return _surfaceViewRenderer
    }
    
    /// Logger for production debugging
    private let _surfaceViewRenderer: org.webrtc.SurfaceViewRenderer
    
    // MARK: - Initialization
    public init() {
        self._surfaceViewRenderer = org.webrtc.SurfaceViewRenderer(ProcessInfo.processInfo.androidContext)
        // Initialize renderer with shared EGL (no mirror for remote)
        RTCClient.shared.initializeSurfaceRenderer(self._surfaceViewRenderer, mirror: false)
    }
    
    // MARK: - Configuration
    
    /// Set mirror mode for remote video (typically false)
    public func setMirror(_ mirrored: Bool) {
        _surfaceViewRenderer.setMirror(mirrored)
    }
    
    /// Release resources
    public func release() {
        _surfaceViewRenderer.release()
    }

    /// Attach a remote video track to this renderer
    public func attach(_ track: RTCVideoTrack) {
        RTCClient.shared.attach(track, to: _surfaceViewRenderer)
    }

    /// Detach a remote video track from this renderer
    public func detach(_ track: RTCVideoTrack) {
        RTCClient.shared.detach(track, from: _surfaceViewRenderer)
    }
}

// MARK: - Android Capture View Factory
/// Factory for creating Android capture views (equivalent to iOS view creation)
public struct AndroidCaptureViewFactory {
    
    /// Create a local video capture view (equivalent to PreviewCaptureView)
    public static func createPreviewCaptureView() -> AndroidPreviewCaptureView {
        return AndroidPreviewCaptureView()
    }
    
    /// Create a remote video capture view (equivalent to SampleCaptureView)
    public static func createSampleCaptureView() -> AndroidSampleCaptureView {
        return AndroidSampleCaptureView()
    }
}
#endif
