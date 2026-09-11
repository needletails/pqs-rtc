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

    /// Unused SurfaceView. Pixels render on `previewDisplayView`. Do not read this
    /// from hangup/teardown — Skip JNI bind of the getter SIGTRAPs after client reset.
    internal var surfaceViewRenderer: org.webrtc.SurfaceViewRenderer {
        native.surfaceViewRenderer
    }

    /// SurfaceView media overlay that shows local preview.
    internal var previewDisplayView: android.view.View {
        native.previewDisplayView
    }

    func initializePreview(eglBase: org.webrtc.EglBase, mirror: Bool) {
        native.initializePreview(eglBase: eglBase, mirror: mirror)
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
        releaseCaptureResources()
    }

    /// Unique name so Skip/Fuse cannot drop a `release()` mapping. Stops the
    /// SurfaceView `EglRenderer("LocalPreview")` stats thread.
    public func releaseCaptureResources() {
        native.releaseLocalPreviewEgl()
    }

    /// Attaches a local video track to this preview renderer.
    public func attach(_ track: RTCVideoTrack) {
        native.attach(track: track)
    }

    /// Detaches a local video track from this preview renderer.
    public func detach(_ track: RTCVideoTrack) {
        native.detach(track: track)
    }

    /// True when this PiP is already on the capturer fanout. Native Fuse
    /// `createPreviewView` uses this so Connected sync does not rebind.
    public func hasActiveSink() -> Bool {
        native.hasActiveSink()
    }

    /// Rounds the local overlay. SurfaceView hole-punch ignores `clipToOutline`;
    /// Kotlin applies `RoundedRectGlDrawer` on a translucent overlay.
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

    /// Leave 2-up → 1:1: native letterbox stays 317×564 until scale state flips.
    public func applySoloFullscreenLayout() {
        native.applySoloFullscreenLayout()
    }

    /// Join 1:1 → 2-up: leftover fullscreen fill stays until conference scale flips.
    public func applyConferenceGridLayout() {
        native.applyConferenceGridLayout()
    }

    /// Compose 16:9 cell size is the leftover letterbox viewport.
    @discardableResult
    public func applyConferenceLetterboxForComposeTile(tileWidthPx: Int, tileHeightPx: Int) -> Bool {
        native.applyConferenceLetterboxForComposeTile(
            tileWidthPx: tileWidthPx,
            tileHeightPx: tileHeightPx
        )
    }

    /// Called by Compose on renderer updates. If the backing view size changed, native code
    /// reconciles the sink against the already assigned track.
    public func rendererDidUpdateLayout() {
        native.rendererDidUpdateLayout()
    }

    /// Deferred layout reconcile for Compose `AndroidView.update` — avoids synchronous EGL work
    /// during the layout pass (multiparty grids were triggering main-thread ANRs).
    /// Returns true only when a new reconcile was posted (size or sink changed).
    @discardableResult
    public func rendererDidUpdateLayoutFromCompose() -> Bool {
        native.rendererDidUpdateLayoutFromCompose()
    }

    public func hasAssignedTrackForRendererInit() -> Bool {
        native.hasAssignedTrackForRendererInit()
    }

    public func markSurfaceRendererInitialized() {
        native.markSurfaceRendererInitialized()
    }

    public func noteIdlePoolFactorySkippedEgl() {
        native.noteIdlePoolFactorySkippedEgl()
    }

    public func conferenceTileComposeUpdateIsNoOp() -> Bool {
        native.conferenceTileComposeUpdateIsNoOp()
    }

    public func rememberConferenceTileComposeHost() {
        native.rememberConferenceTileComposeHost()
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

    /// Stops the WebRTC `EglRenderer` stats thread. Safe after EGL teardown.
    public func release() {
        releaseCaptureResources()
    }

    public func releaseCaptureResources() {
        native.release()
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

// MARK: - Android Call Chrome Bridge
/// Transpiled entry point so **compiled** Fuse Swift can reach the Kotlin
/// `AndroidCallChromeNativeSupport` object.
///
/// PQSRTC and the app are Skip `mode: native` modules: a `#if SKIP` block inside a
/// compiled Swift function body is always false, so calls placed there never run.
/// Device3 20:29–20:33: `hit layer attached` with no detach, no `reset key=`, and no
/// `detached all call chrome overlays` at hangup. Route through this type instead.
public struct AndroidCallChromeBridge {

    /// Hangup: drop every drag session, control exclusion, tap handler and the hit layer.
    public static func detachAllForCallEnd() {
        AndroidCallChromeNativeSupport.detachAllForCallEnd()
    }

    /// Reset a drag session's native translation back to rest.
    public static func resetDrag(key: String) {
        AndroidCallChromeNativeSupport.resetNativeCallChromeDrag(key: key)
    }

    /// Detach a drag session by key (removes the hit layer when the last one goes).
    public static func detachDrag(key: String) {
        AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: key)
    }

    /// Attach the native drag handle to the local preview host `TextureView`.
    /// Returns `false` when the preview is not hosted yet.
    public static func attachLocalPreviewDrag(captureView: AndroidPreviewCaptureView, edgeDp: Float) -> Bool {
        guard let host = AndroidRTCViewSupport.localPreviewHostOrNull(previewView: captureView.previewDisplayView) else {
            return false
        }
        AndroidCallChromeNativeSupport.resetNativeCallChromeDrag(key: "local")
        AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
            seed: host,
            key: "local",
            enableTap: true,
            edgeDp: edgeDp
        )
        return true
    }

    /// Attach native drag + tap to the remote in-app PiP host. Full-screen seeds
    /// defer until the tile is boxed; returns `false` only when the renderer is gone.
    public static func attachRemotePipDrag(captureView: AndroidSampleCaptureView, edgeDp: Float) -> Bool {
        let renderer = captureView.surfaceViewRenderer
        let host = AndroidRTCViewSupport.aspectFitContainerOrNull(renderer: renderer) ?? renderer
        AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
            seed: host,
            key: "pip",
            enableTap: true,
            edgeDp: edgeDp
        )
        return true
    }

    /// Install / clear the in-app PiP tap handler.
    public static func setInAppPipTapHandler(_ handler: (() -> Void)?) {
        AndroidCallChromeNativeSupport.setInAppPipTapHandler(handler: handler)
    }

    /// Per-tile tap. `local` shrinks/grows the in-call overlay; `pip` shrinks/grows
    /// the floating remote window. Restore stays on the return chip.
    public static func setTileTapHandler(key: String, handler: (() -> Void)?) {
        AndroidCallChromeNativeSupport.setTileTapHandler(key: key, handler: handler)
    }
}
#endif
