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

// MARK: - Android Preview Capture View (Equivalent to PreviewCaptureView)
/// Android equivalent of `PreviewCaptureView` that renders the local preview video.
///
/// The SDK creates and manages this view, attaching and detaching the local `RTCVideoTrack`
/// as the call transitions between states.
public final class AndroidPreviewCaptureView: @unchecked Sendable {

    private let native: AndroidPreviewCaptureViewNative

    /// The underlying SurfaceViewRenderer for local video.
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer {
        native.surfaceViewRenderer
    }

    /// Creates a preview capture view bound to an `AndroidRTCClient`.
    public init(client: AndroidRTCClient) {
        native = AndroidPreviewCaptureViewNative(client: client)
    }

    /// Sets mirror mode for local video (selfie view).
    public func setMirror(_ mirrored: Bool) {
        native.setMirror(mirrored: mirrored)
    }

    /// Hides or shows the underlying SurfaceView. SurfaceViews ignore Compose alpha/size/offset
    /// modifiers, so this is the only reliable way to hide video while the call chrome is minimized.
    public func setHidden(_ hidden: Bool) {
        native.setHidden(hidden: hidden)
    }

    /// Releases renderer resources safely, handling cases where the OpenGL context may be destroyed.
    public func release() {
        native.release()
    }

    /// Attaches a local video track to this preview renderer.
    public func attach(_ track: RTCVideoTrack) {
        native.attach(track: track)
    }

    /// Detaches a local video track from this preview renderer.
    public func detach(_ track: RTCVideoTrack) {
        native.detach(track: track)
    }

    /// Keeps the local preview clipped to rounded corners as the PiP surface is resized.
    public func configureRoundedOutline(radiusDp: Float = Float(12)) {
        native.configureRoundedOutline(radiusDp: radiusDp)
    }
}

// MARK: - Android Sample Capture View (Equivalent to SampleCaptureView)
/// Android equivalent of `SampleCaptureView` that renders remote video.
///
/// The view queues the remote `RTCVideoTrack` until the underlying surface is ready, then
/// attaches it to the renderer.
public final class AndroidSampleCaptureView: @unchecked Sendable, Equatable {

    private let native: AndroidSampleCaptureViewNative

    /// The underlying SurfaceViewRenderer for remote video.
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer {
        native.surfaceViewRenderer
    }

    /// Creates a remote sample capture view bound to an `AndroidRTCClient`.
    public init(client: AndroidRTCClient) {
        native = AndroidSampleCaptureViewNative(client: client)
    }

    /// Sets mirror mode for remote video (typically `false`).
    public func setMirror(_ mirrored: Bool) {
        native.setMirror(mirrored: mirrored)
    }

    /// Hides or shows the underlying SurfaceView. SurfaceViews ignore Compose alpha/size/offset
    /// modifiers, so this is the only reliable way to hide video while the call chrome is minimized.
    public func setHidden(_ hidden: Bool) {
        native.setHidden(hidden: hidden)
    }

    /// Labels the underlying renderer for attach/EGL diagnostics.
    public func setRendererParticipantLabel(_ participantId: String) {
        native.setRendererParticipantLabel(label: participantId)
    }

    /// Whether the tile confirmed at least one frame on the current EGL generation.
    public func rendererHadConfirmedFirstFrameSinceSinkAttach() -> Bool {
        native.rendererHadConfirmedFirstFrameSinceSinkAttach()
    }

    /// Whether the current sink binding has delivered at least one frame without EGL reinit.
    public func rendererHasDeliveredFramesSinceCurrentSinkAttach() -> Bool {
        native.rendererHasDeliveredFramesSinceCurrentSinkAttach()
    }

    /// Whether this tile ever confirmed a first frame for the currently attached track id.
    public func rendererEverConfirmedFirstFrameForAttachedTrack() -> Bool {
        native.rendererEverConfirmedFirstFrameForAttachedTrack()
    }

    /// True when a track is queued or the surface is not ready for a pending bind.
    public func rendererHasPendingTrackBind() -> Bool {
        native.rendererHasPendingTrackBind()
    }

    /// Reinitializes EGL once for a live attached track that has not produced a first frame.
    public func forceReinitializeRendererForAttachedTrackIfPreFirstFrame() -> Bool {
        native.forceReinitializeRendererForAttachedTrackIfPreFirstFrame()
    }

    /// Reinitializes EGL for a live attached track after frame delivery stops.
    public func forceReinitializeRendererForAttachedTrackIfFrameStale(staleThresholdMs: Int = 6_000) -> Bool {
        native.forceReinitializeRendererForAttachedTrackIfFrameStale(staleThresholdMs: Int64(staleThresholdMs))
    }

    /// True when a previously live tile has not rendered frames recently while the sink remains bound.
    public func rendererFramesStaleWhileBound(staleThresholdMs: Int = 6_000) -> Bool {
        native.rendererFramesStaleWhileBound(staleThresholdMs: Int64(staleThresholdMs))
    }

    /// True when a live-wrapper rebind is deferred until the current stale wrapper stops delivering frames.
    public func hasPendingLiveWrapperRebind() -> Bool {
        native.hasPendingLiveWrapperRebind()
    }

    /// Defers swapping to the live receiver wrapper until the stale wrapper stops delivering frames.
    public func requestPendingLiveWrapperRebind() {
        native.requestPendingLiveWrapperRebind()
    }

    /// Applies a deferred live-wrapper rebind once the stale wrapper stops delivering recent frames.
    @discardableResult
    public func applyPendingLiveWrapperRebindIfEligible(track: RTCVideoTrack, forceApply: Bool = false) -> Bool {
        native.applyPendingLiveWrapperRebindIfEligible(track: track, forceApply: forceApply)
    }

    /// Installs a retry hook that can re-resolve the latest live participant track after Compose
    /// finishes creating the Android surface.
    public func setSurfaceReadyRetry(_ retry: @escaping () -> Void) {
        native.setSurfaceReadyRetry(retry: retry)
    }

    public func detachCurrentTrack() {
        native.detachCurrentTrack()
    }

    /// Called by Compose after initializing the renderer. EGL reinit drops any prior sink, so
    /// reconcile against the current participant track instead of trusting cached sink state.
    public func rendererDidInitialize() {
        native.rendererDidInitialize()
    }

    /// Called by Compose on renderer updates. If the backing view size changed, native code
    /// reconciles the sink against the already assigned track.
    public func rendererDidUpdateLayout() {
        native.rendererDidUpdateLayout()
    }

    /// Deferred layout reconcile for Compose `AndroidView.update` — avoids synchronous EGL work
    /// during the layout pass (multiparty grids were triggering main-thread ANRs).
    public func rendererDidUpdateLayoutFromCompose() {
        native.rendererDidUpdateLayoutFromCompose()
    }

    /// True when the tile has a live sink but the renderer dimensions changed since the last bind.
    public func rendererLayoutNeedsSinkReconcile() -> Bool {
        native.rendererLayoutNeedsSinkReconcile()
    }

    /// Returns whether the native renderer currently has an attached WebRTC sink.
    public func hasActiveSink() -> Bool {
        native.hasActiveSink()
    }

    /// Track id currently bound to the renderer sink, if any.
    public func attachedTrackId() -> String? {
        native.attachedTrackId()
    }

    /// Whether the renderer can keep its current sink for the requested receiver.
    public func attachedTrackSharesRendererSink(with track: RTCVideoTrack) -> Bool {
        native.attachedTrackSharesRendererSink(track: track)
    }

    /// Atomic main-thread attach/skip probe flags: 1 = active sink, 2 = shares sink, 4 = layout reconcile, 8 = attached track live.
    public func participantRendererAttachProbeFlags(with track: RTCVideoTrack) -> Int {
        native.participantRendererAttachProbeFlags(track: track)
    }

    /// Whether the renderer's attached Java wrapper is still live.
    public func attachedTrackIsLive() -> Bool {
        native.attachedTrackIsLive()
    }

    /// Native renderer layout snapshot for attach/EGL diagnostics.
    public func rendererAttachDiagnosticSummary() -> String {
        native.rendererAttachDiagnosticSummary()
    }

    /// Attaches a remote video track to this renderer.
    ///
    /// If the surface is not ready, the track is queued and attached when the surface becomes available.
    @discardableResult
    public func attach(_ track: RTCVideoTrack) -> Bool {
        native.attach(track: track)
    }

    /// Detaches a remote video track from this renderer.
    public func detach(_ track: RTCVideoTrack) {
        native.detach(track: track)
    }

    public func clearSurfaceReadyRetry() {
        native.clearSurfaceReadyRetry()
    }

    /// Event-driven hook fired when the current sink binding confirms its first rendered frame.
    public func setSinkAttachFirstFrameObserver(_ observer: (() -> Void)?) {
        native.setSinkAttachFirstFrameObserver(observer: observer)
    }

    public func clearSinkAttachFirstFrameObserver() {
        native.clearSinkAttachFirstFrameObserver()
    }

    public static func == (lhs: AndroidSampleCaptureView, rhs: AndroidSampleCaptureView) -> Bool {
        lhs.native === rhs.native
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
