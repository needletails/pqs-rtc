//  AndroidCaptureViews.swift
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

#if SKIP
import Foundation
import org.webrtc.__
import kotlin.__
import android.view.__

// SKIP INSERT: // Custom renderer to allow rotation adjustments or normalization similar to iOS
// SKIP INSERT: class CustomSurfaceViewRenderer : org.webrtc.SurfaceViewRenderer {
// SKIP INSERT:     private var extraRotation: Int = 0
// SKIP INSERT:     private var normalizeToUpright: Boolean = false
// SKIP INSERT:     constructor(context: android.content.Context?) : super(context)
// SKIP INSERT:     constructor(context: android.content.Context?, attrs: android.util.AttributeSet?) : super(context, attrs)
// SKIP INSERT:     fun setExtraRotation(degrees: Int) { extraRotation = ((degrees % 360) + 360) % 360 }
// SKIP INSERT:     fun setNormalizeToUpright(normalize: Boolean) { normalizeToUpright = normalize }
// SKIP INSERT:     override fun onFrame(frame: org.webrtc.VideoFrame) {
// SKIP INSERT:         val newRotation = if (normalizeToUpright) {
// SKIP INSERT:             // Flatten incoming rotation to 0 so content is upright like iOS path
// SKIP INSERT:             0
// SKIP INSERT:         } else {
// SKIP INSERT:             (frame.rotation + extraRotation) % 360
// SKIP INSERT:         }
// SKIP INSERT:         if (newRotation == frame.rotation) { super.onFrame(frame); return }
// SKIP INSERT:         val corrected = org.webrtc.VideoFrame(frame.buffer, newRotation, frame.timestampNs)
// SKIP INSERT:         super.onFrame(corrected)
// SKIP INSERT:         corrected.release()
// SKIP INSERT:     }
// SKIP INSERT: }

// MARK: - Android Preview Capture View (Equivalent to PreviewCaptureView)
/// Android equivalent of `PreviewCaptureView` that renders the local preview video.
///
/// The SDK creates and manages this view, attaching and detaching the local `RTCVideoTrack`
/// as the call transitions between states.
public final class AndroidPreviewCaptureView: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// The underlying SurfaceViewRenderer for local video.
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer { _surfaceViewRenderer }
    
    /// Underlying renderer (SurfaceViewRenderer on Android).
    private var _surfaceViewRenderer: org.webrtc.SurfaceViewRenderer!
    
    /// The Android WebRTC client that owns EGL and renderer lifecycle.
    private let client: AndroidRTCClient
    
    // MARK: - Initialization
    /// Creates a preview capture view bound to an `AndroidRTCClient`.
    ///
    /// The underlying renderer is created in Skip/Kotlin via `// SKIP INSERT:`.
    public init(client: AndroidRTCClient) {
        self.client = client
        // SKIP INSERT: this@AndroidPreviewCaptureView._surfaceViewRenderer = CustomSurfaceViewRenderer(ProcessInfo.processInfo.androidContext)
        // SKIP INSERT: (this@AndroidPreviewCaptureView._surfaceViewRenderer as CustomSurfaceViewRenderer).setNormalizeToUpright(false)
        // SKIP INSERT: (this@AndroidPreviewCaptureView._surfaceViewRenderer as CustomSurfaceViewRenderer).setExtraRotation(90)
        // SKIP INSERT: this@AndroidPreviewCaptureView._surfaceViewRenderer.setId(android.view.View.generateViewId())
        // SKIP INSERT: android.util.Log.d("ANDROIDPREVIEWCAPTUREVIEW", "INITIALIZED APCV")
    }
    
    // MARK: - Configuration
    
    /// Sets mirror mode for local video (selfie view).
    public func setMirror(_ mirrored: Bool) { _surfaceViewRenderer.setMirror(mirrored) }
    
    /// Releases renderer resources safely, handling cases where the OpenGL context may be destroyed.
    public func release() {
        // SKIP INSERT: try {
        // SKIP INSERT:     _surfaceViewRenderer.release()
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:     android.util.Log.w("AndroidPreviewCaptureView", "Error releasing renderer (context may be destroyed): ${e.message}")
        // SKIP INSERT: }
    }

    /// Attaches a local video track to this preview renderer.
    public func attach(_ track: RTCVideoTrack) {
        // SKIP INSERT: try {
        // SKIP INSERT:     track.platformTrack.addSink(_surfaceViewRenderer)
        // SKIP INSERT: } catch (e: java.lang.IllegalStateException) {
        // SKIP INSERT:     android.util.Log.w("AndroidPreviewCaptureView", "Attempted to attach disposed track: ${e.message}")
        // SKIP INSERT: }
    }

    /// Detaches a local video track from this preview renderer.
    public func detach(_ track: RTCVideoTrack) {
        // SKIP INSERT: try {
        // SKIP INSERT:     track.platformTrack.removeSink(_surfaceViewRenderer)
        // SKIP INSERT: } catch (e: java.lang.IllegalStateException) {
        // SKIP INSERT:     // Ignore if already detached or disposed
        // SKIP INSERT: }
    }
}

// MARK: - Android Sample Capture View (Equivalent to SampleCaptureView)
/// Android equivalent of `SampleCaptureView` that renders remote video.
///
/// The view queues the remote `RTCVideoTrack` until the underlying surface is ready, then
/// attaches it to the renderer.
public final class AndroidSampleCaptureView: @unchecked Sendable, Equatable {
    
    // MARK: - Properties
    
    /// The underlying SurfaceViewRenderer for remote video.
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer {
        return _surfaceViewRenderer
    }
    
    /// Underlying renderer (custom subclass of SurfaceViewRenderer on Android).
    private var _surfaceViewRenderer: org.webrtc.SurfaceViewRenderer!
    
    /// The Android WebRTC client that owns EGL and renderer lifecycle.
    private let client: AndroidRTCClient
    
    /// Pending track to attach when the surface becomes ready.
    private var pendingTrack: RTCVideoTrack?
    
    /// Flag to track if the surface-ready callback has been set up.
    private var surfaceCallbackSetup = false
    
    // MARK: - Initialization
    /// Creates a remote sample capture view bound to an `AndroidRTCClient`.
    ///
    /// The underlying renderer is created in Skip/Kotlin via `// SKIP INSERT:`.
    public init(client: AndroidRTCClient) {
        self.client = client
        // SKIP INSERT: this@AndroidSampleCaptureView._surfaceViewRenderer = CustomSurfaceViewRenderer(ProcessInfo.processInfo.androidContext)
        // SKIP INSERT: (this@AndroidSampleCaptureView._surfaceViewRenderer as CustomSurfaceViewRenderer).setNormalizeToUpright(false)
        // SKIP INSERT: (this@AndroidSampleCaptureView._surfaceViewRenderer as CustomSurfaceViewRenderer).setExtraRotation(0)
        // SKIP INSERT: this@AndroidSampleCaptureView._surfaceViewRenderer.setId(android.view.View.generateViewId())
        // SKIP INSERT: android.util.Log.d("ANDROIDSAMPLECAPTUREVIEW", "INITIALIZED ASCV")
    }
    
    // MARK: - Configuration
    
    /// Sets mirror mode for remote video (typically `false`).
    public func setMirror(_ mirrored: Bool) {
        _surfaceViewRenderer.setMirror(mirrored)
    }

    /// Releases renderer resources safely, handling cases where the OpenGL context may be destroyed.
    public func release() {
        pendingTrack = nil
        // SKIP INSERT: try {
        // SKIP INSERT:     _surfaceViewRenderer.release()
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:     android.util.Log.w("AndroidSampleCaptureView", "Error releasing renderer (context may be destroyed): ${e.message}")
        // SKIP INSERT: }
    }

    /// Returns `true` if the underlying surface is ready for rendering.
    private func isSurfaceReady() -> Bool {
        // SKIP INSERT: try {
        // SKIP INSERT:     val holder = _surfaceViewRenderer.holder
        // SKIP INSERT:     val surface = holder?.surface
        // SKIP INSERT:     val hasSize = _surfaceViewRenderer.width > 0 && _surfaceViewRenderer.height > 0
        // SKIP INSERT:     return surface != null && surface.isValid && hasSize
        // SKIP INSERT: } catch (e: Exception) {
        // SKIP INSERT:     return false
        // SKIP INSERT: }
        return false
    }
    
    /// Sets up a surface holder callback to detect when the surface becomes ready.
    private func setupSurfaceCallback() {
        // SKIP INSERT: if (surfaceCallbackSetup) return
        // SKIP INSERT: surfaceCallbackSetup = true
        // SKIP INSERT: try {
        // SKIP INSERT:     val holder = _surfaceViewRenderer.holder
        // SKIP INSERT:     holder?.addCallback(object : android.view.SurfaceHolder.Callback {
        // SKIP INSERT:         override fun surfaceCreated(holder: android.view.SurfaceHolder) {
        // SKIP INSERT:             android.util.Log.d("AndroidSampleCaptureView", "Surface created")
        // SKIP INSERT:             attachPendingTrackIfReady()
        // SKIP INSERT:         }
        // SKIP INSERT:         
        // SKIP INSERT:         override fun surfaceChanged(holder: android.view.SurfaceHolder, format: Int, width: Int, height: Int) {
        // SKIP INSERT:             android.util.Log.d("AndroidSampleCaptureView", "Surface changed: ${width}x${height}")
        // SKIP INSERT:             attachPendingTrackIfReady()
        // SKIP INSERT:         }
        // SKIP INSERT:         
        // SKIP INSERT:         override fun surfaceDestroyed(holder: android.view.SurfaceHolder) {
        // SKIP INSERT:             android.util.Log.d("AndroidSampleCaptureView", "Surface destroyed")
        // SKIP INSERT:         }
        // SKIP INSERT:     })
        // SKIP INSERT: } catch (e: Exception) {
        // SKIP INSERT:     android.util.Log.w("AndroidSampleCaptureView", "Failed to setup surface callback: ${e.message}")
        // SKIP INSERT: }
    }
    
    /// Attaches the pending track if the surface is ready.
    private func attachPendingTrackIfReady() {
        // SKIP INSERT: val track = pendingTrack ?: return
        // SKIP INSERT: if (isSurfaceReady()) {
        // SKIP INSERT:     try {
        // SKIP INSERT:         track.platformTrack.addSink(_surfaceViewRenderer)
        // SKIP INSERT:         android.util.Log.d("AndroidSampleCaptureView", "Attached pending track after surface ready")
        // SKIP INSERT:         pendingTrack = null
        // SKIP INSERT:     } catch (e: java.lang.IllegalStateException) {
        // SKIP INSERT:         android.util.Log.w("AndroidSampleCaptureView", "Failed to attach pending track: ${e.message}")
        // SKIP INSERT:     }
        // SKIP INSERT: }
    }

    /// Attaches a remote video track to this renderer.
    ///
    /// If the surface is not ready, the track is queued and attached when the surface becomes available.
    public func attach(_ track: RTCVideoTrack) {
        // SKIP INSERT: setupSurfaceCallback()
        // SKIP INSERT: if (isSurfaceReady()) {
        // SKIP INSERT:     try {
        // SKIP INSERT:         track.platformTrack.addSink(_surfaceViewRenderer)
        // SKIP INSERT:         android.util.Log.d("AndroidSampleCaptureView", "Attached track immediately - surface ready")
        // SKIP INSERT:     } catch (e: java.lang.IllegalStateException) {
        // SKIP INSERT:         android.util.Log.w("AndroidSampleCaptureView", "Attempted to attach disposed track: ${e.message}")
        // SKIP INSERT:     }
        // SKIP INSERT: } else {
        // SKIP INSERT:     pendingTrack = track
        // SKIP INSERT:     android.util.Log.d("AndroidSampleCaptureView", "Surface not ready, queued track for later attachment")
        // SKIP INSERT: }
    }

    /// Detaches a remote video track from this renderer.
    public func detach(_ track: RTCVideoTrack) {
        // SKIP INSERT: try {
        // SKIP INSERT:     track.platformTrack.removeSink(_surfaceViewRenderer)
        // SKIP INSERT: } catch (e: java.lang.IllegalStateException) {
        // SKIP INSERT:     // Ignore if already detached or disposed
        // SKIP INSERT: }
        // SKIP INSERT: // Clear pending track if it matches
        // SKIP INSERT: if (pendingTrack?.platformTrack == track.platformTrack) {
        // SKIP INSERT:     pendingTrack = null
        // SKIP INSERT: }
    }
}

// MARK: - Android Capture View Factory
/// Factory for creating Android capture views.
public struct AndroidCaptureViewFactory {
    
    /// Creates a local video capture view (equivalent to `PreviewCaptureView`).
    public static func createPreviewCaptureView(client: AndroidRTCClient) -> AndroidPreviewCaptureView {
        return AndroidPreviewCaptureView(client: client)
    }
    
    /// Creates a remote video capture view (equivalent to `SampleCaptureView`).
    public static func createSampleCaptureView(client: AndroidRTCClient) -> AndroidSampleCaptureView {
        return AndroidSampleCaptureView(client: client)
    }
}
#endif
