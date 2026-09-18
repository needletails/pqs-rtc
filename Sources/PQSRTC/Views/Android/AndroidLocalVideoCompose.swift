//  AndroidComposeViews.swift
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
#if os(Android) || SKIP
import SkipFuseUI
import NeedleTailLogger

#if SKIP
import androidx.compose.runtime.__
import androidx.compose.ui.__
import androidx.compose.foundation.__
import androidx.compose.foundation.layout.__
import androidx.compose.ui.unit.__
import androidx.compose.foundation.shape.__
import androidx.compose.ui.draw.__
import androidx.compose.ui.platform.__
import androidx.compose.ui.viewinterop.__

// MARK: - Android Local Video Compose View
/// Compose view that hosts the local preview renderer.
///
/// This is the Android equivalent of `PreviewCaptureView`. The SDK initializes the underlying
/// `SurfaceViewRenderer` and invokes the launch/dispose callbacks so the controller can wire the
/// view into an `RTCSession`.
public struct AndroidLocalVideoCompose: ContentComposer {
    
    private let client: AndroidRTCClient
    private let captureView: AndroidPreviewCaptureView
    private let onDisposeCallback: () -> Void
    
    public init(
        client: AndroidRTCClient,
        captureView: AndroidPreviewCaptureView,
        onDispose: @escaping () -> Void) {
            self.client = client
            self.captureView = captureView
            self.onDisposeCallback = onDispose
        }
    
    @Composable
    public func Compose(context: ComposeContext) {
        let localCaptureView = captureView
        AndroidCaptureUIPreferenceCache.refreshFromStoredPreferences()
        let mirrorLocalPreview = AndroidCaptureUIPreferenceCache.isLocalVideoMirroredEnabled()

        // Pooled for the whole call. Releasing here on Compose remount (minimize / PiP /
        // safe-area toggles) tears EGL down on the main thread and forces a full reinit.
        androidx.compose.runtime.DisposableEffect(localCaptureView) {
            onDispose {
                onDisposeCallback()
            }
        }
        Box(modifier: context.modifier.fillMaxSize()) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { _ in
                    localCaptureView.setMirror(mirrorLocalPreview)
                    _ = client.safelyInitializeLocalPreview(
                        localCaptureView,
                        mirror: mirrorLocalPreview
                    )
                    let host = AndroidRTCViewSupport.localPreviewHostContainer(
                        previewView: localCaptureView.previewDisplayView,
                        cornerRadiusDp: Float(12)
                    )
                    // Compose clip cannot round the SurfaceView overlay.
                    // configureRoundedOutline applies GL rounded-rect on the overlay.
                    localCaptureView.configureRoundedOutline(radiusDp: Float(12))
                    AndroidRTCViewSupport.detachFromParent(view: host)
                    host
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
                    // Do not re-wrap the SurfaceView host on parent recomposition.
                    // That destroys the surface (`LocalPreviewDropping frame - No surface`).
                }
            )
        }
    }
}

// MARK: - Android Remote Video Compose View
/// Compose view that hosts a remote video renderer.
///
/// Accepts a pre-created `AndroidSampleCaptureView` whose track has been (or will be)
/// assigned externally by the controller. This is the Android equivalent of
/// `SampleCaptureView` on Apple.
public struct AndroidRemoteVideoCompose: ContentComposer {
    private let client: AndroidRTCClient
    private let captureView: AndroidSampleCaptureView

    public init(client: AndroidRTCClient, captureView: AndroidSampleCaptureView) {
        self.client = client
        self.captureView = captureView
    }

    @Composable
    public func Compose(context: ComposeContext) {
        let renderer = captureView.surfaceViewRenderer

        androidx.compose.runtime.DisposableEffect(renderer) {
            onDispose {
                client.removeRenderer(renderer)
                AndroidRTCViewSupport.clearRendererImage(renderer: renderer)
                client.safeReleaseRenderer(renderer)
            }
        }

        Box(modifier: context.modifier.fillMaxSize()) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    _ = client.safelyInitializeSurfaceRenderer(renderer, mirror: false)
                    captureView.rendererDidInitialize()
                    // Solo remote: fill only when remote upright orientation matches local viewport.
                    let container = AndroidRTCViewSupport.remoteCameraHostContainer(
                        renderer: renderer,
                        prefersAspectFit: false,
                        cornerRadiusDp: Float(0),
                        fillWhenOrientationMatches: true
                    )
                    AndroidRTCViewSupport.detachFromParent(view: container)
                    container
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
                    _ = captureView.rendererDidUpdateLayoutFromCompose()
                }
            )
        }
    }
}


// MARK: - Android Screen Share Compose View
/// Compose view that renders a remote screen share as a dominant tile with a "Presenting" badge.
public struct AndroidScreenShareCompose: ContentComposer {

    private let client: AndroidRTCClient
    private let captureView: AndroidSampleCaptureView
    private let presenterName: String
    private let onSurfaceLayout: () -> Void

    public init(
        client: AndroidRTCClient,
        captureView: AndroidSampleCaptureView,
        presenterName: String = "Presenting",
        onSurfaceLayout: @escaping () -> Void = {}
    ) {
        self.client = client
        self.captureView = captureView
        self.presenterName = presenterName
        self.onSurfaceLayout = onSurfaceLayout
    }

    @Composable
    public func Compose(context: ComposeContext) {
        let renderer = captureView.surfaceViewRenderer

        // The screen renderer is pooled for the whole call; do not release it when Compose
        // recomposes during layout changes or screen-share visibility toggles.
        androidx.compose.runtime.DisposableEffect(renderer) {
            onDispose { }
        }

        Box(modifier = context.modifier.fillMaxSize()) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    _ = client.safelyInitializeSurfaceRenderer(renderer, mirror: false)
                    renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                    captureView.rendererDidInitialize()
                    let container = AndroidRTCViewSupport.aspectFitContainer(renderer: renderer)
                    AndroidRTCViewSupport.detachFromParent(view: container)
                    container
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
                    _ = captureView.rendererDidUpdateLayoutFromCompose()
                    onSurfaceLayout()
                }
            )

            // "Presenting" badge overlay
            Box(
                modifier: Modifier
                    .align(androidx.compose.ui.Alignment.TopStart)
                    .padding(8.dp)
                    .background(
                        color: androidx.compose.ui.graphics.Color(0xCC000000.toInt()),
                        shape: RoundedCornerShape(6.dp)
                    )
                    .padding(horizontal: 8.dp, vertical: 4.dp)
            ) {
                androidx.compose.material3.Text(
                    text: presenterName,
                    color: androidx.compose.ui.graphics.Color.White,
                    fontSize: 12.sp
                )
            }
        }
    }
}

// MARK: - Android Video Call Compose View (Parent)
/// Parent compose that renders a collection of remote views.
///
/// This view is responsible only for view creation and lifecycle callbacks; the actual call wiring
/// is performed by `AndroidVideoCallController`.
public struct AndroidRemoteGridCompose: ContentComposer {
    
    private let client: AndroidRTCClient
    private let remoteCaptureViews: [AndroidSampleCaptureView]
    private let raisedHandFlags: [Bool]
    private let prefersAspectFit: Bool
    private let cleanupOnDispose: Bool
    /// When true, participant tiles live in the short camera strip below/beside an active
    /// screen share. On phones this selects the horizontal collection with tiles that
    /// follow device orientation (9:16 portrait, 16:9 landscape). Full-screen conference
    /// keeps the vertical 16:9 grid.
    private let usesCompactParticipantStrip: Bool
    /// Solo (1:1) tile corner radius. Full-screen stays 0; in-app PiP uses a native
    /// outline so SurfaceViews actually clip. Multi-tile grids keep 12.
    private let soloTileCornerRadiusDp: Int
    /// Registers the native remote host as the one draggable in-app PiP tile. This is
    /// intentionally independent from per-participant corner styling. Never use
    /// `LocalView.current` here — Skip's Compose host is the full messaging view.
    private let enablesCallChromeDrag: Bool
    /// Read from `AndroidView.update` so Compose invalidates on generation change. Do not pass
    /// this (or any `UInt64`) through a Skip-bridged Swift closure — `JULong.fromJavaObject`
    /// aborts (`swift_unexpectedError`) when the tile attaches.
    private let layoutGeneration: Int64
    private let onParticipantSurfaceLayout: (AndroidSampleCaptureView) -> Void
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        raisedHandFlags: [Bool] = [],
        prefersAspectFit: Bool = true,
        cleanupOnDispose: Bool = true,
        usesCompactParticipantStrip: Bool = false,
        soloTileCornerRadiusDp: Int = 0,
        enablesCallChromeDrag: Bool = false,
        layoutGeneration: Int64 = 0,
        onParticipantSurfaceLayout: @escaping (AndroidSampleCaptureView) -> Void = { _ in },
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.raisedHandFlags = raisedHandFlags
        self.prefersAspectFit = prefersAspectFit
        self.cleanupOnDispose = cleanupOnDispose
        self.usesCompactParticipantStrip = usesCompactParticipantStrip
        self.soloTileCornerRadiusDp = soloTileCornerRadiusDp
        self.enablesCallChromeDrag = enablesCallChromeDrag
        self.layoutGeneration = layoutGeneration
        self.onParticipantSurfaceLayout = onParticipantSurfaceLayout
        self.onDispose = onDispose
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        let capturedEnablesCallChromeDrag = enablesCallChromeDrag
        androidx.compose.runtime.DisposableEffect(capturedEnablesCallChromeDrag) {
            onDispose {
                if capturedEnablesCallChromeDrag {
                    AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: "pip")
                }
            }
        }
        androidx.compose.runtime.DisposableEffect(remoteCaptureViews) {
            onDispose {
                if cleanupOnDispose {
                    for view in remoteCaptureViews {
                        view.releaseCaptureResources()
                    }
                    onDispose()
                }
            }
        }
        
        Box(
            modifier: context.modifier.fillMaxSize()
        ) {
            let configuration = LocalConfiguration.current
            let isPortrait = configuration.screenHeightDp >= configuration.screenWidthDp
            let paddedRaisedHandFlags = raisedHandFlags + Array(
                repeating: false,
                count: max(0, remoteCaptureViews.count - raisedHandFlags.count)
            )
            let flaggedViews = zip(remoteCaptureViews, paddedRaisedHandFlags).map { ($0.0, $0.1) }
            let itemCount = remoteCaptureViews.count
            let contentPaddingDp = conferenceContentPaddingDp(for: itemCount)
            let tileSpacingDp = conferenceTileSpacingDp(
                screenWidthDp: configuration.screenWidthDp,
                itemCount: itemCount
            )
            let tileCornerRadiusDp = conferenceTileCornerRadiusDp(for: itemCount)
            // Screen-share leftover is always a short wide band (phone and tablet).
            // Conference view uses the orientation grid instead.
            // Skip cannot see Swift-only `GroupCallVideoLayoutPolicy`; keep this
            // primitive-only and aligned with `androidConferenceGridDimensions`
            // / Android leftover-band 16:9 tiles.
            let compactTile = screenShareCompactCameraTileDp(
                screenWidthDp: configuration.screenWidthDp,
                screenHeightDp: configuration.screenHeightDp,
                itemCount: itemCount
            )
            let cameraTileWidthDp = compactTile.width
            let cameraTileHeightDp = compactTile.height
            let useScreenShareCompactStrip =
                usesCompactParticipantStrip && itemCount >= 1 && itemCount <= 4

            if useScreenShareCompactStrip {
                let callControlsInsetDp = 112
                Row(
                    modifier: Modifier
                        .fillMaxSize()
                        .padding(bottom: callControlsInsetDp.dp)
                        .navigationBarsPadding()
                        .horizontalScroll(rememberScrollState())
                        .padding(contentPaddingDp.dp),
                    horizontalArrangement: itemCount == 1
                        ? Arrangement.Center
                        : Arrangement.spacedBy(tileSpacingDp.dp),
                    verticalAlignment: androidx.compose.ui.Alignment.Top
                ) {
                    for (view, showRaisedHand) in flaggedViews {
                        let rendererSlotKey = Int(view.surfaceViewRenderer.hashCode())
                        androidx.compose.runtime.key(rendererSlotKey) {
                            ConferenceTile(
                                view: view,
                                showRaisedHand: showRaisedHand,
                                cornerRadiusDp: tileCornerRadiusDp,
                                enablesPipDrag: capturedEnablesCallChromeDrag,
                                gridItemCount: itemCount,
                                modifier: Modifier
                                    .width(cameraTileWidthDp.dp)
                                    .height(cameraTileHeightDp.dp)
                            )
                        }
                    }
                }
            } else if itemCount == 1 {
                // Do not keep the leftover in a Column/Row `aspectRatio` cell.
                // Device3 22:45:36 published `mounted count=1` and the SurfaceView
                // stayed 317×564 for minutes — `applySolo` letterboxed against
                // the still-16:9 host and this tree never remasured fillMaxSize.
                for (view, showRaisedHand) in flaggedViews {
                    let rendererSlotKey = Int(view.surfaceViewRenderer.hashCode())
                    let tileKey = rendererSlotKey &* 31 &+ 2
                    androidx.compose.runtime.key(tileKey) {
                        ConferenceTile(
                            view: view,
                            showRaisedHand: showRaisedHand,
                            cornerRadiusDp: tileCornerRadiusDp,
                            enablesPipDrag: capturedEnablesCallChromeDrag,
                            gridItemCount: itemCount,
                            modifier: Modifier.fillMaxSize()
                        )
                    }
                }
            } else {
                let grid = conferenceGridDimensions(for: itemCount, isPortrait: isPortrait)
                let rows = chunked(flaggedViews, size: grid.columns)
                // Nested Compose inside SwiftUI `.ignoresSafeArea()` often reports
                // `WindowInsets.statusBars` as 0. Read the window inset in px.
                let density = LocalDensity.current
                let hostView = LocalView.current
                let statusTopPx = androidx.core.view.ViewCompat.getRootWindowInsets(hostView)?
                    .getInsets(androidx.core.view.WindowInsetsCompat.Type.statusBars())?
                    .top ?? 0
                let statusTopDp = with(density) { statusTopPx.toDp().value }
                let rememberedStatusTopDp = remember { mutableStateOf(Float(0)) }
                if statusTopDp > Float(0) {
                    rememberedStatusTopDp.value = statusTopDp
                }
                let insetTopDp = statusTopDp > Float(0) ? statusTopDp : rememberedStatusTopDp.value
                // 1-up stays full-bleed under the status bar (iOS fullscreen). N-up
                // conference tiles sit below it. Hold the last non-zero inset so
                // rotation 0-blips do not bounce the grid.
                var gridModifier: Modifier = Modifier.fillMaxSize()
                if itemCount > 1 {
                    if insetTopDp > Float(0) {
                        gridModifier = gridModifier.padding(top: insetTopDp.dp)
                    } else {
                        gridModifier = gridModifier.statusBarsPadding()
                    }
                }
                Column(
                    modifier: gridModifier.padding(contentPaddingDp.dp),
                    verticalArrangement: Arrangement.spacedBy(tileSpacingDp.dp),
                    horizontalAlignment: androidx.compose.ui.Alignment.CenterHorizontally
                ) {
                    for row in rows {
                        Row(
                            modifier: itemCount == 1
                                ? Modifier.fillMaxSize()
                                : Modifier.fillMaxWidth(),
                            horizontalArrangement: Arrangement.spacedBy(tileSpacingDp.dp)
                        ) {
                            for (view, showRaisedHand) in row {
                                let rendererSlotKey = Int(view.surfaceViewRenderer.hashCode())
                                // Stable across 1↔N. Same formula as `composeTileKey`.
                                // Remounting the leftover on shrink first-measured 317×564
                                // (Device3 22:18:41). Do not call the Swift policy from
                                // this SKIP Compose body — it is compiled-only.
                                let tileKey = rendererSlotKey &* 31 &+ 2
                                androidx.compose.runtime.key(tileKey) {
                                    // 1:1 stays full-bleed; conference uses uniform 16:9 cells.
                                    // Native letterbox waits for this tile size — do not wrap
                                    // the SurfaceView while fillMaxSize ↔ aspectRatio remasures.
                                    let tileModifier: Modifier = itemCount == 1
                                        ? Modifier.fillMaxSize()
                                        : Modifier
                                            .weight(Float(1.0))
                                            .aspectRatio(Float(16.0 / 9.0))
                                    ConferenceTile(
                                        view: view,
                                        showRaisedHand: showRaisedHand,
                                        cornerRadiusDp: tileCornerRadiusDp,
                                        enablesPipDrag: capturedEnablesCallChromeDrag,
                                        gridItemCount: itemCount,
                                        modifier: tileModifier
                                    )
                                }
                            }
                            let missingColumns = max(0, grid.columns - row.count)
                            if missingColumns > 0 {
                                for _ in 0..<missingColumns {
                                    Spacer(modifier: Modifier.weight(Float(1.0)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One participant tile. Multi-remote grids letterbox (`prefersAspectFit`) so portrait
    /// senders keep their orientation inside uniform tiles. A solo fullscreen remote
    /// (`prefersAspectFit == false`) fills only when remote upright orientation matches the
    /// local viewport; mismatched portrait/landscape pairs stay letterboxed.
    @Composable
    private func ConferenceTile(
        view: AndroidSampleCaptureView,
        showRaisedHand: Bool,
        cornerRadiusDp: Int,
        enablesPipDrag: Bool,
        gridItemCount: Int,
        modifier: Modifier
    ) {
        // Apple `RemoteViewItem`: 12pt continuous corner + 0.75pt white 12%
        // stroke on N-up cells. Compose clip cannot round a SurfaceView
        // hole-punch (lesson 17) — inset the renderer so the stroke lives
        // outside the hole. 1-up stays full-bleed (no tile chrome).
        let showTileChrome = gridItemCount > 1 && !enablesPipDrag && cornerRadiusDp > 0
        let tileShape = RoundedCornerShape(cornerRadiusDp.dp)
        let tileModifier: Modifier
        if showTileChrome {
            tileModifier = modifier
                .clip(tileShape)
                .background(
                    color: androidx.compose.ui.graphics.Color.Black,
                    shape: tileShape
                )
                .border(
                    width: conferenceTileBorderWidthDp.dp,
                    color: androidx.compose.ui.graphics.Color.White.copy(alpha: Float(0.12)),
                    shape: tileShape
                )
        } else if enablesPipDrag {
            tileModifier = modifier.background(androidx.compose.ui.graphics.Color.Black)
        } else {
            tileModifier = modifier
                .clip(tileShape)
                .background(androidx.compose.ui.graphics.Color.Black)
        }
        let videoModifier: Modifier = showTileChrome
            ? Modifier.fillMaxSize().padding(conferenceTileBorderWidthDp.dp)
            : Modifier.fillMaxSize()
        Box(
            modifier: tileModifier
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { _ in
                    if view.hasAssignedTrackForRendererInit() {
                        if client.safelyInitializeSurfaceRenderer(view.surfaceViewRenderer, mirror: false) {
                            view.markSurfaceRendererInitialized()
                        }
                        view.rendererDidInitialize()
                    } else {
                        view.noteIdlePoolFactorySkippedEgl()
                    }
                    // Lock conference/solo before the first host apply. Calling
                    // `remoteCameraHostContainer` first kept the leftover SOLO
                    // lock and MATCH_PARENT-FILLed the 16:9 cell (Device3 14:39).
                    if prefersAspectFit {
                        view.applyConferenceGridLayout()
                        // Rejoin leftover host can still be 1:1 while the
                        // SurfaceView is already the 16:9 cell (Device3 19:19:56).
                        _ = view.applyConferenceLetterboxForComposeTile(
                            tileWidthPx: Int(view.surfaceViewRenderer.width),
                            tileHeightPx: Int(view.surfaceViewRenderer.height)
                        )
                    } else {
                        view.applySoloFullscreenLayout()
                    }
                    let host = AndroidRTCViewSupport.aspectFitContainerOrNull(
                        renderer: view.surfaceViewRenderer
                    ) ?? AndroidRTCViewSupport.remoteCameraHostContainer(
                        renderer: view.surfaceViewRenderer,
                        prefersAspectFit: prefersAspectFit,
                        cornerRadiusDp: Float(cornerRadiusDp),
                        fillWhenOrientationMatches: !prefersAspectFit
                    )
                    AndroidRTCViewSupport.detachFromParent(view: host)
                    syncRemotePipDrag(host: host, enabled: enablesPipDrag)
                    host
                },
                modifier: videoModifier,
                update: { _ in
                    // Restyle letterbox vs fill when 1-up ↔ conference flips. Native
                    // policy keeps MATCH_PARENT until the tile settles, then one exact
                    // letterbox size — do not remasure wrap-content here.
                    // Attach PiP drag here: factory usually ran fullscreen
                    // (`enablesCallChromeDrag == false`) and never registered the tile.
                    // `rendererDidUpdateLayoutFromCompose` is size-only. A missing sink
                    // must not notify the controller (that Task/reattach loop ANRs).
                    if view.conferenceTileComposeUpdateIsNoOp() {
                        if let host = AndroidRTCViewSupport.aspectFitContainerOrNull(
                            renderer: view.surfaceViewRenderer
                        ) {
                            syncRemotePipDrag(host: host, enabled: enablesPipDrag)
                        }
                        return
                    }
                    if prefersAspectFit, let sizedHost = AndroidRTCViewSupport.aspectFitContainerOrNull(
                        renderer: view.surfaceViewRenderer
                    ) {
                        // Do not call `remoteCameraHostContainer` after a 16:9
                        // letterbox — stale leftover 1:1 host width MATCH_PARENT
                        // FILLs 1002×564 (Device3 16:46:48 → BLAST 16:49:07).
                        if view.applyConferenceLetterboxForComposeTile(
                            tileWidthPx: Int(sizedHost.width),
                            tileHeightPx: Int(sizedHost.height)
                        ) || view.applyConferenceLetterboxForComposeTile(
                            tileWidthPx: Int(view.surfaceViewRenderer.width),
                            tileHeightPx: Int(view.surfaceViewRenderer.height)
                        ) {
                            syncRemotePipDrag(host: sizedHost, enabled: enablesPipDrag)
                            _ = layoutGeneration
                            _ = gridItemCount
                            if view.rendererDidUpdateLayoutFromCompose() {
                                onParticipantSurfaceLayout(view)
                            }
                            view.rememberConferenceTileComposeHost()
                            return
                        }
                    }
                    let host = AndroidRTCViewSupport.remoteCameraHostContainer(
                        renderer: view.surfaceViewRenderer,
                        prefersAspectFit: prefersAspectFit,
                        cornerRadiusDp: Float(cornerRadiusDp),
                        fillWhenOrientationMatches: !prefersAspectFit
                    )
                    syncRemotePipDrag(host: host, enabled: enablesPipDrag)
                    _ = layoutGeneration
                    _ = gridItemCount
                    if view.rendererDidUpdateLayoutFromCompose() {
                        onParticipantSurfaceLayout(view)
                    }
                    view.rememberConferenceTileComposeHost()
                }
            )
            if showRaisedHand {
                androidx.compose.material3.Text(
                    text: "✋",
                    modifier: Modifier
                        .align(androidx.compose.ui.Alignment.TopEnd)
                        .padding(8.dp)
                )
            }
        }
    }

    private func syncRemotePipDrag(host: android.view.View, enabled: Bool) {
        if enabled {
            AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
                seed: host,
                key: "pip",
                enableTap: true,
                edgeDp: Float(16)
            )
        } else {
            AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: "pip", seed: host)
        }
    }

    private func conferenceGridDimensions(for itemCount: Int, isPortrait: Bool) -> (columns: Int, rows: Int) {
        let count = max(0, itemCount)
        switch count {
        case 0, 1:
            return (1, 1)
        case 2...4:
            return isPortrait ? (1, count) : (count, 1)
        case 5...6:
            return (3, 2)
        case 7...9:
            return (3, 3)
        default:
            let columns = 4
            return (columns, (count + columns - 1) / columns)
        }
    }

    /// First leftover-band camera tile for the compact share strip.
    /// Mirrors `GroupCallVideoLayoutPolicy.screenShareDominantFrames` Android 16:9 math
    /// without importing Swift-only layout types into Skip Kotlin.
    private func screenShareCompactCameraTileDp(
        screenWidthDp: Int,
        screenHeightDp: Int,
        itemCount: Int
    ) -> (width: Int, height: Int) {
        let count = max(1, itemCount)
        let containerW = Double(screenWidthDp)
        let containerH = Double(screenHeightDp)
        let isWide = containerW > max(1.0, containerH) * 1.08
        let aspect = 16.0 / 9.0
        let padding: Double
        switch count {
        case ...4:
            padding = 15
        case 5...9:
            padding = 11.25
        default:
            padding = 7.5
        }
        let spacing: Double = count > 1 ? (containerW < 600 ? 6.0 : 10.0) : 0.0

        let maxWidth: Double
        let maxHeight: Double
        if isWide {
            let screenFraction = count == 1 ? 0.74 : 0.82
            let cameraWidth = max(1.0, containerW * (1.0 - screenFraction))
            maxWidth = max(1.0, cameraWidth - padding * 2)
            maxHeight = max(1.0, containerH - padding * 2)
        } else {
            let screenFraction: Double
            switch count {
            case 1:
                screenFraction = 0.70
            case 2...4:
                screenFraction = 0.82
            default:
                screenFraction = 0.78
            }
            let cameraHeight = max(1.0, containerH * (1.0 - screenFraction))
            let availableW = max(1.0, containerW - padding * 2)
            let availableH = max(1.0, cameraHeight - padding * 2)
            let totalSpacing = Double(max(0, count - 1)) * spacing
            maxWidth = (availableW - totalSpacing) / Double(count)
            maxHeight = availableH
        }

        let tile = fitLandscapeTile(aspect: aspect, maxWidth: maxWidth, maxHeight: maxHeight)
        return (max(1, Int(tile.width.rounded())), max(1, Int(tile.height.rounded())))
    }

    private func fitLandscapeTile(
        aspect: Double,
        maxWidth: Double,
        maxHeight: Double
    ) -> (width: Double, height: Double) {
        guard maxWidth > 0, maxHeight > 0 else { return (120.0, 68.0) }
        if maxWidth / maxHeight > aspect {
            let height = maxHeight
            return (height * aspect, height)
        }
        let width = maxWidth
        return (width, width / aspect)
    }

    /// Matches Apple `CollectionViewSections.defaultContentInsets`, scaled down as roster grows.
    private func conferenceContentPaddingDp(for itemCount: Int) -> Int {
        guard itemCount > 1 else { return 0 }
        let scale: Double
        switch itemCount {
        case ...4:
            scale = 1.0
        case 5...9:
            scale = 0.75
        default:
            scale = 0.5
        }
        return Int((15.0 * scale).rounded())
    }

    /// Matches Apple conference tile spacing (6pt phone / 10pt tablet).
    private func conferenceTileSpacingDp(screenWidthDp: Int, itemCount: Int) -> Int {
        guard itemCount > 1 else { return 0 }
        return screenWidthDp < 600 ? 6 : 10
    }

    /// Apple `RemoteViewItem` camera cells use 12pt corners.
    private func conferenceTileCornerRadiusDp(for itemCount: Int) -> Int {
        itemCount > 1 ? 12 : soloTileCornerRadiusDp
    }

    /// Apple camera-cell `borderWidth` is 0.75pt; 1 dp is the closest stroke
    /// that stays outside the SurfaceView hole-punch after the video inset.
    private var conferenceTileBorderWidthDp: Int { 1 }

    private func chunked<T>(_ source: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [source] }
        var result: [[T]] = []
        var index = 0
        while index < source.count {
            let end = min(index + size, source.count)
            result.append(Array(source[index..<end]))
            index = end
        }
        return result
    }
}
#endif

@MainActor
fileprivate final class AndroidVideoCallCoordinator: VideoCallDelegate {
    private var errorMessage: Binding<String>
    private var endedCall: Binding<Bool>
    private var callState: Binding<CallStateMachine.State>
    var isScreenSharing: Binding<Bool>?
    var hasActiveRemoteScreenShare: Binding<Bool>?
    var remoteParticipantTilesDidChangeHandler: (() -> Void)?

    init(
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        callState: Binding<CallStateMachine.State>
    ) {
        self.errorMessage = errorMessage
        self.endedCall = endedCall
        self.callState = callState
    }

    func update(
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        callState: Binding<CallStateMachine.State>
    ) {
        self.errorMessage = errorMessage
        self.endedCall = endedCall
        self.callState = callState
    }

    public func passErrorMessage(_ message: String) async {
        errorMessage.wrappedValue = message
    }

    public func deliverCallState(_ state: CallStateMachine.State) async {
        callState.wrappedValue = state
    }

    public func endedCall(_ didEnd: Bool) async {
        endedCall.wrappedValue = didEnd
    }

    public func screenShareDidChange(isSharing: Bool) async {
        await MainActor.run {
            isScreenSharing?.wrappedValue = isSharing
        }
    }

    public func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async {
        await MainActor.run {
            hasActiveRemoteScreenShare?.wrappedValue = isSharing
        }
    }

    public func remoteParticipantTilesDidChange() async {
        Task { @MainActor in
            await Task.yield()
            remoteParticipantTilesDidChangeHandler?()
        }
    }
}

@MainActor
fileprivate final class AndroidVideoCallResources {
    let controller: AndroidVideoCallController
    let localCaptureView: AndroidPreviewCaptureView
    private(set) var remoteCaptureViews: [AndroidSampleCaptureView]
    /// Whether video surfaces are hidden (call chrome minimized to browse the app).
    private(set) var videoSurfacesHidden = false
    private var _screenCaptureView: AndroidSampleCaptureView?
    private var videoRenderersReleased = false
    var isReleased: Bool { videoRenderersReleased }
    private static let minimizeLogger = NeedleTailLogger(level: .info)
    private static let lifecycleLogger = NeedleTailLogger(level: .info)
    /// Lazily created view for rendering a remote screen share.
    var screenCaptureView: AndroidSampleCaptureView {
        if let existing = _screenCaptureView { return existing }
        let created = AndroidCaptureViewFactory.createSampleCaptureView(client: _client)
        created.setHidden(videoSurfacesHidden)
        _screenCaptureView = created
        return created
    }
    var coordinator: AndroidVideoCallCoordinator?
    /// True once this call has mapped at least one remote. Waiting-slot Compose
    /// is only for the first join; after the last remote leaves, remounting
    /// `pool.first` keeps a frozen 1:1 SurfaceView (Device3 pid 30600).
    var hasPublishedAssignedRemote = false
    /// Drops overlapping `tilesDidChange` visible-grid refreshes.
    var visibleRemoteGridRefreshGeneration: UInt = 0
    private let _client: AndroidRTCClient

    init(session: RTCSession, remoteCount: Int) {
        self._client = session.rtcClient
        self.controller = AndroidVideoCallController(session: session)
        self.localCaptureView = AndroidCaptureViewFactory.createPreviewCaptureView(client: session.rtcClient)
        self.localCaptureView.setMirror(PQSRTCCallUIPreferences.resolvedLocalVideoMirroredEnabled())
        self.remoteCaptureViews = Self.makeRemoteCaptureViews(client: session.rtcClient, count: remoteCount)
    }

    func ensureRemoteCapacity(atLeast remoteCount: Int) {
        guard remoteCount > remoteCaptureViews.count else { return }
        let additional = remoteCount - remoteCaptureViews.count
        let added = Self.makeRemoteCaptureViews(client: _client, count: additional)
        if videoSurfacesHidden {
            for view in added { view.setHidden(true) }
        }
        remoteCaptureViews.append(contentsOf: added)
    }

    /// Stops WebRTC `EglRenderer` stats threads by releasing every pooled call renderer.
    /// Remote grid uses `cleanupOnDispose: false` during the call, so this must run on end.
    /// Hide first: hangup resets chrome to expanded while the call tree can still be
    /// mounted, and that unhide race was leaving a visible TextureView on screen.
    func releaseAllVideoRenderers() {
        guard !videoRenderersReleased else { return }
        videoRenderersReleased = true
        let remoteCount = remoteCaptureViews.count
        let hadScreenView = _screenCaptureView != nil
        Self.lifecycleLogger.log(
            level: .info,
            message: """
            Releasing Android call video renderers remoteCount=\(remoteCount) \
            hasScreenView=\(hadScreenView)
            """
        )
        localCaptureView.setHidden(true)
        for view in remoteCaptureViews { view.setHidden(true) }
        _screenCaptureView?.setHidden(true)
        // Compiled Fuse Swift cannot see SKIP-only code, so this must go through the
        // transpiled bridge or the hit layer / global-layout listener outlives the call.
        AndroidCallChromeBridge.detachAllForCallEnd()
        // Local pixels are on TextureView. Do not read `surfaceViewRenderer` here:
        // hangup is often the first Skip JNI bind of that unused getter and SIGTRAPs
        // after client reset. Kotlin `releaseCaptureResources` unregisters the
        // leftover SurfaceView if the client tracked it, then always releases both.
        localCaptureView.releaseCaptureResources()
        for view in remoteCaptureViews {
            view.releaseCaptureResources()
        }
        if let screenView = _screenCaptureView {
            screenView.releaseCaptureResources()
        }
        _screenCaptureView = nil
    }
    
    /// SurfaceViews ignore Compose alpha/size/offset modifiers, so hiding the call chrome must
    /// toggle native View visibility on every renderer. Sinks stay attached; restoring is instant.
    func setVideoSurfacesHidden(_ hidden: Bool, source: String = "unknown") {
        guard videoSurfacesHidden != hidden else {
            Self.minimizeLogger.log(
                level: .debug,
                message: "[CallChromeMinimize] setVideoSurfacesHidden skipped (already \(hidden)) source=\(source)"
            )
            return
        }
        videoSurfacesHidden = hidden
        let remoteCount = remoteCaptureViews.count
        let hasScreenView = _screenCaptureView != nil
        Self.minimizeLogger.log(
            level: .info,
            message: "[CallChromeMinimize] setVideoSurfacesHidden hidden=\(hidden) source=\(source) remoteCount=\(remoteCount) hasScreenView=\(hasScreenView)"
        )
        localCaptureView.setHidden(hidden)
        for view in remoteCaptureViews { view.setHidden(hidden) }
        _screenCaptureView?.setHidden(hidden)
    }

    /// Hides only the local preview. Keep the Compose view mounted so dispose does not
    /// release the renderer; `INVISIBLE` is enough for in-app and system PiP.
    func applyLocalPreviewHidden(_ hidden: Bool, source: String = "unknown") {
        Self.minimizeLogger.log(
            level: .info,
            message: "[CallChromeMinimize] applyLocalPreviewHidden hidden=\(hidden) source=\(source)"
        )
        localCaptureView.setHidden(hidden)
    }

    private static func makeRemoteCaptureViews(
        client: AndroidRTCClient,
        count: Int
    ) -> [AndroidSampleCaptureView] {
        guard count > 0 else { return [] }
        return (0..<count).map { _ in
            AndroidCaptureViewFactory.createSampleCaptureView(client: client)
        }
    }
}

@MainActor
fileprivate enum AndroidVideoCallResourceStore {
    private static var storage: [String: AndroidVideoCallResources] = [:]

    static func resources(
        for key: String,
        session: RTCSession,
        remoteCount: Int,
        allowCreateReplacement: Bool = true
    ) -> AndroidVideoCallResources {
        if let existing = storage[key], !existing.isReleased {
            existing.ensureRemoteCapacity(atLeast: remoteCount)
            return existing
        }
        if let existing = storage[key], existing.isReleased, !allowCreateReplacement {
            return existing
        }

        let created = AndroidVideoCallResources(session: session, remoteCount: remoteCount)
        storage[key] = created
        return created
    }

    static func remove(for key: String) {
        storage[key]?.releaseAllVideoRenderers()
        storage.removeValue(forKey: key)
    }
}

// MARK: - SwiftUI Wrappers
/// SwiftUI wrapper for local video preview.
///
/// This is the SwiftUI-facing wrapper around `AndroidLocalVideoCompose`.
public struct AndroidLocalVideoView: View {
    private let client: AndroidRTCClient
    private let captureView: AndroidPreviewCaptureView
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        captureView: AndroidPreviewCaptureView,
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.captureView = captureView
        self.onDispose = onDispose
    }
    
    public var body: some View {
        ComposeView {
            AndroidLocalVideoCompose(
                client: client,
                captureView: captureView,
                onDispose: onDispose
            )
        }
    }
}

/// SwiftUI wrapper for remote video rendering.
public struct AndroidRemoteVideoView: View {
    private let client: AndroidRTCClient
    private let captureView: AndroidSampleCaptureView

    public init(client: AndroidRTCClient, captureView: AndroidSampleCaptureView) {
        self.client = client
        self.captureView = captureView
    }
    
    public var body: some View {
        ComposeView {
            AndroidRemoteVideoCompose(client: client, captureView: captureView)
        }
    }
}

/// SwiftUI wrapper that hosts a grid of remote video renderers.
public struct AndroidRemoteGrid: View {
    private let client: AndroidRTCClient
    private let remoteCaptureViews: [AndroidSampleCaptureView]
    private let raisedHandFlags: [Bool]
    private let prefersAspectFit: Bool
    private let cleanupOnDispose: Bool
    private let usesCompactParticipantStrip: Bool
    private let soloTileCornerRadiusDp: Int
    private let enablesCallChromeDrag: Bool
    private let layoutGeneration: Int64
    private let onParticipantSurfaceLayout: (AndroidSampleCaptureView) -> Void
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        raisedHandFlags: [Bool] = [],
        prefersAspectFit: Bool = true,
        cleanupOnDispose: Bool = true,
        usesCompactParticipantStrip: Bool = false,
        soloTileCornerRadiusDp: Int = 0,
        enablesCallChromeDrag: Bool = false,
        layoutGeneration: Int64 = 0,
        onParticipantSurfaceLayout: @escaping (AndroidSampleCaptureView) -> Void = { _ in },
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.raisedHandFlags = raisedHandFlags
        self.prefersAspectFit = prefersAspectFit
        self.cleanupOnDispose = cleanupOnDispose
        self.usesCompactParticipantStrip = usesCompactParticipantStrip
        self.soloTileCornerRadiusDp = soloTileCornerRadiusDp
        self.enablesCallChromeDrag = enablesCallChromeDrag
        self.layoutGeneration = layoutGeneration
        self.onParticipantSurfaceLayout = onParticipantSurfaceLayout
        self.onDispose = onDispose
    }
    
    public var body: some View {
        ComposeView {
            AndroidRemoteGridCompose(
                client: client,
                remoteCaptureViews: remoteCaptureViews,
                raisedHandFlags: raisedHandFlags,
                prefersAspectFit: prefersAspectFit,
                cleanupOnDispose: cleanupOnDispose,
                usesCompactParticipantStrip: usesCompactParticipantStrip,
                soloTileCornerRadiusDp: soloTileCornerRadiusDp,
                enablesCallChromeDrag: enablesCallChromeDrag,
                layoutGeneration: layoutGeneration,
                onParticipantSurfaceLayout: onParticipantSurfaceLayout,
                onDispose: onDispose
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(
            AndroidRemoteGridTransitionPolicy.composeGridIdentity(
                itemCount: remoteCaptureViews.count,
                prefersAspectFit: prefersAspectFit
            )
        )
    }
}

/// SwiftUI wrapper that renders a remote screen share tile.
public struct AndroidScreenShareView: View {
    private let client: AndroidRTCClient
    private let captureView: AndroidSampleCaptureView
    private let presenterName: String
    private let onSurfaceLayout: () -> Void

    public init(
        client: AndroidRTCClient,
        captureView: AndroidSampleCaptureView,
        presenterName: String = "Presenting",
        onSurfaceLayout: @escaping () -> Void = {}
    ) {
        self.client = client
        self.captureView = captureView
        self.presenterName = presenterName
        self.onSurfaceLayout = onSurfaceLayout
    }

    public var body: some View {
        ComposeView {
            AndroidScreenShareCompose(
                client: client,
                captureView: captureView,
                presenterName: presenterName,
                onSurfaceLayout: onSurfaceLayout
            )
        }
    }
}

/// SwiftUI wrapper for a complete Android video call UI.
///
/// This view composes the remote grid and local preview overlay, and wires them to an
/// `AndroidVideoCallController` that drives media rendering and user actions.
public struct AndroidVideoCallView: View {
    
    private let remoteCount: Int
    private let session: RTCSession
    private let conferenceRaisedHands: [String: Bool]
    /// Hides all native video SurfaceViews (call chrome minimized to browse the app).
    private let hidesVideoSurfaces: Bool
    /// Full-screen call UI expands past safe area. In-app floating PiP must stay boxed.
    private let expandsIntoSafeArea: Bool
    /// Keep `AndroidLocalVideoView` mounted when false and hide the SurfaceView —
    /// unmounting runs Compose `onDispose` and releases EGL.
    private let showsLocalPreview: Bool
    /// System PiP is the Activity window. Local fills that window so an outbound-only
    /// call is not a black tile. In-app minimize is remote-only and must not fill.
    private let isSystemPictureInPicture: Bool
    private var localPreviewFillsContainer: Bool {
        isSystemPictureInPicture && !expandsIntoSafeArea
    }
    /// In-app floating remote PiP keeps the local overlay mounted and hides it.
    private var hideLocalPreviewForInAppPictureInPicture: Bool {
        !expandsIntoSafeArea && !isSystemPictureInPicture
    }

    /// Native SurfaceView drag owns pointer move. This restores chrome on a PiP tap.
    private let onInAppPipTap: (() -> Void)?
    private static let minimizeLogger = NeedleTailLogger(level: .info)
    /// One call UI at a time. A per-appear UUID remounts a new renderer pool on every
    /// chrome/PiP transition and releases EGL on the main thread.
    private static let activeCallResourceKey = "android-active-video-call"
    @State var resourceKey: String
    @State var currentRemotePage: Int = 0
    /// Non-zero so the local SurfaceView is never first measured at 0×0 (that skips surface
    /// creation and leaves the preview queued forever).
    @State var localViewSize: CGSize = CGSize(width: 140, height: 249)
    @State var isLocalPreviewMinimized = false
    @State var gridRaisedHandFlags: [Bool] = []
    @State var visibleRemoteCaptureViews: [AndroidSampleCaptureView] = []
    @State var mountedMultipartyRemoteSlotCount: Int = 0
    @State var screenShareLayoutGeneration: UInt64 = 0
    /// Skip remounts fire `onDisappear` while a call is live. After the first live state,
    /// `Waiting` means hangup — release TextureView / SurfaceView EGL (LocalPreviewDuration).
    @State var didEnterLiveCall = false
    var actionBridge: AndroidVideoCallActionBridge?
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
    @Binding var isScreenSharing: Bool
    @Binding var hasActiveRemoteScreenShare: Bool
    /// Window size in SwiftUI points from `android.R.id.content` (px ÷ density).
    /// Do not probe this with Skip `GeometryReader` — even a Color.clear sibling
    /// remasures every SurfaceView (lessons 82 / 85).
    let layoutContainerSize: CGSize
    
    public init(
        session: RTCSession,
        remoteCount: Int = 1,
        actionBridge: AndroidVideoCallActionBridge? = nil,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        isScreenSharing: Binding<Bool> = .constant(false),
        hasActiveRemoteScreenShare: Binding<Bool> = .constant(false),
        conferenceRaisedHands: [String: Bool] = [:],
        hidesVideoSurfaces: Bool = false,
        expandsIntoSafeArea: Bool = true,
        showsLocalPreview: Bool = true,
        isSystemPictureInPicture: Bool = false,
        onInAppPipTap: (() -> Void)? = nil,
        layoutContainerSize: CGSize = .zero
    ) {
        self.session = session
        self.remoteCount = remoteCount
        self.actionBridge = actionBridge
        self.conferenceRaisedHands = conferenceRaisedHands
        self.hidesVideoSurfaces = hidesVideoSurfaces
        self.expandsIntoSafeArea = expandsIntoSafeArea
        self.showsLocalPreview = showsLocalPreview
        self.isSystemPictureInPicture = isSystemPictureInPicture
        self.onInAppPipTap = onInAppPipTap
        self.layoutContainerSize = layoutContainerSize
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self._isScreenSharing = isScreenSharing
        self._hasActiveRemoteScreenShare = hasActiveRemoteScreenShare
        self._resourceKey = State(initialValue: Self.activeCallResourceKey)
    }

    private var raisedHandsRefreshToken: String {
        conferenceRaisedHands
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
    }

    private var isMultipartyCall: Bool {
        switch callState {
        case .ready(let call),
             .connecting(_, let call),
             .connected(_, let call):
            if call.isTrueOneToOneSfuRoom { return false }
            let normalizedSharedId = call.sharedCommunicationId.normalizedConnectionId
            return call.conferencePassword != nil
                || call.resolvedChannelWireId != nil
                || call.recipients.count > 1
                || call.sharedCommunicationId.isGroupCall
                || normalizedSharedId.hasPrefix("conf-")
        default:
            return remoteCount > 1
        }
    }

    /// Size the renderer pool from roster/remote count. Group calls may keep extra unused
    /// slots in the pool so a later joiner can attach without allocating a new
    /// `SurfaceViewRenderer`. Visible Compose `itemCount` still follows assigned remotes.
    private var effectiveRemoteCount: Int {
        isMultipartyCall ? max(remoteCount, 2) : max(remoteCount, 1)
    }
    
    public var body: some View {
        let resources = AndroidVideoCallResourceStore.resources(
            for: resourceKey,
            session: session,
            remoteCount: effectiveRemoteCount,
            allowCreateReplacement: isLiveCallState(callState) && !endedCall
        )
        // Roster `remoteCount` only sizes the renderer pool. After refresh,
        // `visibleRemoteCaptureViews` is assigned remotes. A waiting slot is
        // only before the first mapping this call — not after the last leave.
        // Compute off the ViewBuilder: an `if` here is a view branch, so
        // assigning `()` failed Android release (`type '()' cannot conform to 'View'`).
        let displayedRemoteCaptureViews = displayedRemoteCaptureViewsForBody(
            assignedViews: visibleRemoteCaptureViews,
            poolViews: resources.remoteCaptureViews,
            hasPublishedAssignedRemote: resources.hasPublishedAssignedRemote
        )
        let remotePageSize = hasActiveRemoteScreenShare ? 8 : 12
        let remotePages = paginateRemotes(displayedRemoteCaptureViews, pageSize: remotePageSize)
        let activeRemoteCount = displayedRemoteCaptureViews.count
        // Solo fullscreen and share-strip tiles match-fill when the item matches the remote.
        // Multi-remote conference grids letterbox inside uniform 16:9 cells.
        let usesShareCameraStrip = hasActiveRemoteScreenShare || isScreenSharing
        let remotePrefersAspectFit = activeRemoteCount > 1 && !usesShareCameraStrip
        let screenShareHeightFraction: CGFloat = {
            guard hasActiveRemoteScreenShare else { return 0 }
            return activeRemoteCount <= 1 ? 0.64 : 0.68
        }()
        let capturedLayoutGeneration = screenShareLayoutGeneration
        let composeLayoutGeneration = Int64(bitPattern: capturedLayoutGeneration)
        // Native outline on the remote host — SwiftUI clipShape punches SurfaceViews.
        let soloRemoteCornerRadiusDp = expandsIntoSafeArea ? 0 : 16
        // 1-arg only: Skip `Function2` + `UInt64` aborts in `JULong.fromJavaObject` on tile attach.
        let onParticipantSurfaceLayout: (AndroidSampleCaptureView) -> Void = { view in
            Task {
                await resources.controller.participantSurfaceDidUpdateLayout(
                    view,
                    generation: capturedLayoutGeneration
                )
            }
        }

        let shareHeight: CGFloat? = {
            let height = layoutContainerSize.height
            guard hasActiveRemoteScreenShare, height > 200 else { return nil }
            return height * screenShareHeightFraction
        }()
        ZStack(alignment: .bottomTrailing) {
                // Do not wrap remotes — or this ZStack — in GeometryReader. Skip
                // rebuilds that child on every layout pass and remasures every
                // SurfaceView (Device3 18:18 storm; Color.clear probe leftover
                // Device3 pid 3069). Container size comes from the activity
                // window (px ÷ density), not a layout probe.
                    VStack(spacing: 0) {
                        if hasActiveRemoteScreenShare {
                            AndroidScreenShareView(
                                client: session.rtcClient,
                                captureView: resources.screenCaptureView,
                                onSurfaceLayout: {
                                    Task { @MainActor in
                                        guard hasActiveRemoteScreenShare else { return }
                                        let screenView = resources.screenCaptureView
                                        guard screenView.rendererLayoutNeedsSinkReconcile()
                                            || !screenView.hasActiveSink() else {
                                            return
                                        }
                                        await resources.controller.setScreenView(screenView)
                                    }
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: shareHeight, maxHeight: shareHeight ?? .infinity)
                            .background(Color.black)
                        }

                        if remotePages.count > 1 {
                            TabView(selection: $currentRemotePage) {
                                ForEach(Array(remotePages.enumerated()), id: \.offset) { idx, remotes in
                                    AndroidRemoteGrid(
                                        client: session.rtcClient,
                                        remoteCaptureViews: remotes,
                                        raisedHandFlags: raisedHandFlags(for: remotes, allViews: displayedRemoteCaptureViews),
                                        prefersAspectFit: remotePrefersAspectFit,
                                        cleanupOnDispose: false,
                                        usesCompactParticipantStrip: usesShareCameraStrip,
                                        soloTileCornerRadiusDp: soloRemoteCornerRadiusDp,
                                        enablesCallChromeDrag: !expandsIntoSafeArea && idx == currentRemotePage,
                                        layoutGeneration: composeLayoutGeneration,
                                        onParticipantSurfaceLayout: onParticipantSurfaceLayout,
                                        onDispose: {}
                                    )
                                    .tag(idx)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .always))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(hasActiveRemoteScreenShare ? 0.92 : 1.0))
                            .overlay(alignment: .top) {
                                Text("Page \(currentRemotePage + 1)/\(remotePages.count)")
                                    .font(.footnote)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                                    .padding(.top, 12)
                            }
                        } else {
                            AndroidRemoteGrid(
                                client: session.rtcClient,
                                remoteCaptureViews: displayedRemoteCaptureViews,
                                raisedHandFlags: raisedHandFlags(for: displayedRemoteCaptureViews, allViews: displayedRemoteCaptureViews),
                                prefersAspectFit: remotePrefersAspectFit,
                                cleanupOnDispose: false,
                                usesCompactParticipantStrip: usesShareCameraStrip,
                                soloTileCornerRadiusDp: soloRemoteCornerRadiusDp,
                                enablesCallChromeDrag: !expandsIntoSafeArea,
                                layoutGeneration: composeLayoutGeneration,
                                onParticipantSurfaceLayout: onParticipantSurfaceLayout,
                                onDispose: {}
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(hasActiveRemoteScreenShare ? 0.92 : 1.0))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showsLocalPreview {
                        // The local renderer is a contained overlay. Native translationX/Y owns
                        // drag so pointer movement does not recompose or resize EGL.
                        localPreviewHost(resources: resources)
                    }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .onAppear {
            applyLocalPreviewOverlaySize(from: layoutContainerSize)
        }
        .onChange(of: layoutContainerSize) { _, newValue in
            applyLocalPreviewOverlaySize(from: newValue)
        }
        .onChange(of: remotePages.count) { _, newCount in
            guard newCount > 0 else {
                currentRemotePage = 0
                return
            }
            currentRemotePage = min(currentRemotePage, newCount - 1)
        }
        .task(id: "\(hasActiveRemoteScreenShare)-\(currentRemotePage)-\(remotePages.count)-\(displayedRemoteCaptureViews.count)") {
            let controller = resources.controller
            let isSharing = hasActiveRemoteScreenShare
            let screenCaptureView = resources.screenCaptureView
            let visiblePageViews: [AndroidSampleCaptureView]
            if remotePages.count > 1, remotePages.indices.contains(currentRemotePage) {
                visiblePageViews = remotePages[currentRemotePage]
            } else {
                visiblePageViews = displayedRemoteCaptureViews
            }
            let generation = await controller.beginParticipantVideoReconcileAfterScreenShareLayoutChange(
                isSharing: isSharing,
                visibleViews: visiblePageViews
            )
            await MainActor.run {
                screenShareLayoutGeneration = generation
            }
            if isSharing {
                await controller.setScreenView(screenCaptureView)
            }
        }
        .onChange(of: hidesVideoSurfaces) { _, hidden in
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView onChange hidesVideoSurfaces=\(hidden)"
            )
            applyCallVideoSurfaceVisibility(resources: resources, source: "onChange hidesVideoSurfaces")
        }
        .onChange(of: showsLocalPreview) { _, visible in
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView onChange showsLocalPreview=\(visible)"
            )
            applyCallVideoSurfaceVisibility(resources: resources, source: "onChange showsLocalPreview")
            if visible {
                _ = AndroidCallChromeBridge.attachLocalPreviewDrag(
                    captureView: resources.localCaptureView,
                    edgeDp: Float(20)
                )
            } else {
                AndroidCallChromeBridge.detachDrag(key: "local")
            }
        }
        .onChange(of: expandsIntoSafeArea) { _, fullBleed in
            syncInAppPipChrome(resources: resources, fullBleed: fullBleed)
            applyCallVideoSurfaceVisibility(
                resources: resources,
                source: "onChange expandsIntoSafeArea"
            )
        }
        .onChange(of: isSystemPictureInPicture) { _, _ in
            syncInAppPipChrome(resources: resources, fullBleed: expandsIntoSafeArea)
            applyCallVideoSurfaceVisibility(
                resources: resources,
                source: "onChange isSystemPictureInPicture"
            )
        }
        .task(id: "\(hidesVideoSurfaces)-\(showsLocalPreview)-\(expandsIntoSafeArea)-\(isSystemPictureInPicture)") { @MainActor in
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView task(id:) hidesVideoSurfaces=\(hidesVideoSurfaces) showsLocalPreview=\(showsLocalPreview)"
            )
            applyCallVideoSurfaceVisibility(resources: resources, source: "task")
            syncInAppPipChrome(resources: resources, fullBleed: expandsIntoSafeArea)
        }
        .onAppear {
            AndroidCallChromeBridge.setElapsedTickingAllowed(true)
            if isLiveCallState(callState) {
                didEnterLiveCall = true
            }
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView onAppear hidesVideoSurfaces=\(hidesVideoSurfaces) showsLocalPreview=\(showsLocalPreview)"
            )
            applyCallVideoSurfaceVisibility(resources: resources, source: "onAppear")
            syncInAppPipChrome(resources: resources, fullBleed: expandsIntoSafeArea)
            Task { @MainActor in
                await configureController(resources: resources)
            }
        }
        .onChange(of: remoteCount) { _, newCount in
            Task { @MainActor in
                let slotCount = max(newCount, effectiveRemoteCount)
                let updatedResources = AndroidVideoCallResourceStore.resources(
                    for: resourceKey,
                    session: session,
                    remoteCount: slotCount,
                    allowCreateReplacement: isLiveCallState(callState) && !endedCall
                )
                guard !updatedResources.isReleased, updatedResources.remoteCaptureViews.count > 0 else { return }
                await updatedResources.controller.setRemoteViews(remotes: updatedResources.remoteCaptureViews)
                await refreshGridRaisedHandFlags(resources: updatedResources)
                await refreshVisibleRemoteCaptureViews(resources: updatedResources)
            }
        }
        .onChange(of: callState) { _, newState in
            if isLiveCallState(newState) {
                didEnterLiveCall = true
            }
            // The initial onAppear commonly runs while state is Waiting and hides
            // the TextureView. Apply visibility on the concrete live-state event;
            // otherwise it stays hidden until minimize/restore changes another prop.
            applyCallVideoSurfaceVisibility(
                resources: resources,
                source: "onChange callState"
            )
            if isTerminalCallState(newState) || (isIdleCallState(newState) && didEnterLiveCall) {
                teardownCallVideoResourcesIfNeeded(
                    resources: resources,
                    reason: "terminal callState",
                    force: true
                )
                didEnterLiveCall = false
            }
            Task { @MainActor in
                let slotCount = effectiveRemoteCount
                guard slotCount > 1, !isTerminalCallState(newState) else { return }
                let updatedResources = AndroidVideoCallResourceStore.resources(
                    for: resourceKey,
                    session: session,
                    remoteCount: slotCount,
                    allowCreateReplacement: false
                )
                guard !updatedResources.isReleased else { return }
                await updatedResources.controller.setRemoteViews(remotes: updatedResources.remoteCaptureViews)
                await refreshGridRaisedHandFlags(resources: updatedResources)
                await refreshVisibleRemoteCaptureViews(resources: updatedResources)
            }
        }
        .onChange(of: endedCall) { _, ended in
            guard ended else { return }
            teardownCallVideoResourcesIfNeeded(
                resources: resources,
                reason: "endedCall",
                force: true
            )
        }
        .task(id: raisedHandsRefreshToken) {
            await refreshGridRaisedHandFlags(resources: resources)
        }
        .onDisappear {
            teardownCallVideoResourcesIfNeeded(
                resources: resources,
                reason: "onDisappear",
                force: false
            )
        }
    }

    private func isTerminalCallState(_ state: CallStateMachine.State) -> Bool {
        switch state {
        case .ended, .failed, .callAnsweredAuxDevice:
            return true
        default:
            return false
        }
    }

    private func isLiveCallState(_ state: CallStateMachine.State) -> Bool {
        switch state {
        case .ready, .connecting, .connected, .held:
            return true
        default:
            return false
        }
    }

    private func isIdleCallState(_ state: CallStateMachine.State) -> Bool {
        switch state {
        case .waiting:
            return true
        default:
            return false
        }
    }

    /// Skip SwiftUI remounts fire `onDisappear` while the call is still live. Only tear
    /// EGL / the controller down when the call is actually ending. Peer hangup often
    /// lands on `Waiting` (Ended is coalesced), which used to skip and leave LocalPreview
    /// `EglRenderer` stats running.
    @MainActor
    private func teardownCallVideoResourcesIfNeeded(
        resources: AndroidVideoCallResources,
        reason: String,
        force: Bool
    ) {
        let shouldTeardown = force
            || AndroidRemoteGridTransitionPolicy.shouldTeardownRenderersOnDisappear(
                didEnterLiveCall: didEnterLiveCall,
                showsLocalPreview: showsLocalPreview,
                endedCall: endedCall,
                isTerminalCallState: isTerminalCallState(callState),
                isIdleAfterLiveCall: isIdleCallState(callState) && didEnterLiveCall
            )
        guard shouldTeardown else {
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] skipping renderer teardown on transient disappear reason=\(reason) state=\(callState) showsLocalPreview=\(showsLocalPreview)"
            )
            return
        }
        Self.minimizeLogger.log(
            level: .info,
            message: "[CallChromeMinimize] tearing down call video renderers reason=\(reason) state=\(callState) showsLocalPreview=\(showsLocalPreview)"
        )
        didEnterLiveCall = false
        resources.releaseAllVideoRenderers()
        let controller = resources.controller
        let storeKey = resourceKey
        let actionBridge = actionBridge
        // Abort on the controller actor immediately. A MainActor-isolated Task
        // was starved by hangup PerformTraversals, so the coordinator kept
        // attaching after surfaces were gone (Device3 17:53:47).
        Task {
            await controller.abortAttachWorkForCallEnd()
            await controller.stop()
            await MainActor.run {
                actionBridge?.clearBinding()
                AndroidVideoCallResourceStore.remove(for: storeKey)
            }
        }
    }

    @MainActor
    private func raisedHandFlags(
        for views: [AndroidSampleCaptureView],
        allViews: [AndroidSampleCaptureView]
    ) -> [Bool] {
        guard !gridRaisedHandFlags.isEmpty, views.count == gridRaisedHandFlags.count else {
            return Array(repeating: false, count: views.count)
        }
        return views.map { view in
            guard let index = allViews.firstIndex(where: { $0 === view }),
                  index < gridRaisedHandFlags.count else {
                return false
            }
            return gridRaisedHandFlags[index]
        }
    }

    /// Waiting slot only before the first assigned remote. After the last leave,
    /// return empty so the leftover 1:1 SurfaceView is not remounted.
    private func displayedRemoteCaptureViewsForBody(
        assignedViews: [AndroidSampleCaptureView],
        poolViews: [AndroidSampleCaptureView],
        hasPublishedAssignedRemote: Bool
    ) -> [AndroidSampleCaptureView] {
        if !assignedViews.isEmpty {
            return assignedViews
        }
        if hasPublishedAssignedRemote {
            return []
        }
        return AndroidMultipartyVideoLayout.mountedRemoteViews(
            assignedViews: [],
            poolViews: poolViews,
            allowWaitingSlot: true
        )
    }

    /// Compose `itemCount` follows assigned remotes, matching iOS live collection items.
    /// Extra pool renderers stay allocated; they are not shown as empty tiles.
    @MainActor
    private func multipartyRemoteCaptureViews(from resources: AndroidVideoCallResources) async -> [AndroidSampleCaptureView] {
        let assigned = await resources.controller.assignedRemoteViews()
        let assignedCount = await resources.controller.assignedParticipantCount()
        if assignedCount > 0 {
            resources.hasPublishedAssignedRemote = true
        }
        let allowWaitingSlot = !resources.hasPublishedAssignedRemote
        let slotCount = AndroidMultipartyVideoLayout.multipartyGridSlotCount(
            assignedParticipantCount: assignedCount,
            poolSize: resources.remoteCaptureViews.count,
            allowWaitingSlot: allowWaitingSlot
        )
        mountedMultipartyRemoteSlotCount = slotCount
        return AndroidMultipartyVideoLayout.mountedRemoteViews(
            assignedViews: assigned,
            poolViews: resources.remoteCaptureViews,
            allowWaitingSlot: allowWaitingSlot
        )
    }

    @MainActor
    private func refreshGridRaisedHandFlags(resources: AndroidVideoCallResources) async {
        await resources.controller.updateConferenceRaisedHands(conferenceRaisedHands)
        let views = await multipartyRemoteCaptureViews(from: resources)
        gridRaisedHandFlags = await resources.controller.raisedHandFlags(for: views)
    }

    @MainActor
    private func refreshVisibleRemoteCaptureViews(resources: AndroidVideoCallResources) async {
        resources.visibleRemoteGridRefreshGeneration =
            AndroidRemoteGridTransitionPolicy.nextVisibleRemoteRefreshGeneration(
                current: resources.visibleRemoteGridRefreshGeneration
            )
        let startedGeneration = resources.visibleRemoteGridRefreshGeneration
        let previousViews = visibleRemoteCaptureViews
        let previousSignature = await resources.controller.participantAssignmentSignature()
        guard AndroidRemoteGridTransitionPolicy.shouldCommitVisibleRemoteRefresh(
            startedGeneration: startedGeneration,
            currentGeneration: resources.visibleRemoteGridRefreshGeneration
        ) else { return }
        let previousVisibleCount = previousViews.count
        let nextViews = await multipartyRemoteCaptureViews(from: resources)
        let signature = await resources.controller.participantAssignmentSignature()
        guard AndroidRemoteGridTransitionPolicy.shouldCommitVisibleRemoteRefresh(
            startedGeneration: startedGeneration,
            currentGeneration: resources.visibleRemoteGridRefreshGeneration
        ) else { return }
        let nextVisibleCount = nextViews.count
        if nextViews.isEmpty {
            for view in previousViews {
                view.detachCurrentTrack()
            }
        }
        if previousVisibleCount != nextVisibleCount {
            NeedleTailLogger(level: .info).log(
                level: .info,
                message: "Android remote grid mounted count=\(nextVisibleCount) previous=\(previousVisibleCount)"
            )
        }
        // Lock native scale on the leftover tile before `@State` remounts
        // Compose. Publishing first is what FILLed 1080×2520 → 1002×564.
        if AndroidRemoteGridTransitionPolicy.shouldApplyNativeGridLayoutBeforePublishingVisibleViews(
            previousVisibleCount: previousVisibleCount,
            nextVisibleCount: nextVisibleCount
        ) {
            if previousVisibleCount > 1 && nextVisibleCount == 1 {
                for view in nextViews {
                    view.applySoloFullscreenLayout()
                }
            }
            if previousVisibleCount == 1 && nextVisibleCount > 1 {
                for view in previousViews {
                    view.applyConferenceGridLayout()
                }
                for view in nextViews {
                    view.applyConferenceGridLayout()
                }
            }
        }
        visibleRemoteCaptureViews = nextViews
        if AndroidRemoteGridTransitionPolicy.shouldBumpComposeLayoutGenerationOnVisibleCountChange(
            previousVisibleCount: previousVisibleCount,
            nextVisibleCount: nextVisibleCount
        ) {
            screenShareLayoutGeneration &+= 1
        }
        let waitForComposeLayout = !hasActiveRemoteScreenShare
            && !isScreenSharing
            && AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach(
                previousVisibleCount: previousVisibleCount,
                nextVisibleCount: nextVisibleCount
            )
        if waitForComposeLayout {
            for view in visibleRemoteCaptureViews {
                _ = view.rendererDidUpdateLayoutFromCompose()
            }
            let generation = await resources.controller.beginParticipantVideoReconcileAfterGridSlotLayoutChange(
                visibleViews: visibleRemoteCaptureViews
            )
            screenShareLayoutGeneration = generation
            return
        }
        let gridLayoutChanged = AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: previousVisibleCount,
            nextVisibleCount: nextVisibleCount,
            previousSignature: previousSignature,
            nextSignature: signature
        )
        if gridLayoutChanged {
            for view in visibleRemoteCaptureViews {
                _ = view.rendererDidUpdateLayoutFromCompose()
            }
            await resources.controller.reattachAssignedParticipantVideoIfNeeded()
        }
    }

    @MainActor
    private func configureController(resources: AndroidVideoCallResources) async {
        guard !resources.isReleased else { return }
        if let coordinator = resources.coordinator {
            coordinator.update(
                errorMessage: $errorMessage,
                endedCall: $endedCall,
                callState: $callState
            )
            coordinator.isScreenSharing = $isScreenSharing
            coordinator.hasActiveRemoteScreenShare = $hasActiveRemoteScreenShare
            coordinator.remoteParticipantTilesDidChangeHandler = {
                Task { @MainActor in
                    await refreshVisibleRemoteCaptureViews(resources: resources)
                    await refreshGridRaisedHandFlags(resources: resources)
                }
            }
        } else {
            let coordinator = AndroidVideoCallCoordinator(
                errorMessage: $errorMessage,
                endedCall: $endedCall,
                callState: $callState
            )
            coordinator.isScreenSharing = $isScreenSharing
            coordinator.hasActiveRemoteScreenShare = $hasActiveRemoteScreenShare
            coordinator.remoteParticipantTilesDidChangeHandler = {
                Task { @MainActor in
                    await refreshVisibleRemoteCaptureViews(resources: resources)
                    await refreshGridRaisedHandFlags(resources: resources)
                }
            }
            resources.coordinator = coordinator
            await resources.controller.setVideoCallDelegate(coordinator)
        }

        delegate = resources.controller
        actionBridge?.bind(resources.controller)
        await resources.controller.setVideoViews(
            local: resources.localCaptureView,
            remotes: resources.remoteCaptureViews
        )
        await refreshVisibleRemoteCaptureViews(resources: resources)
        await refreshGridRaisedHandFlags(resources: resources)
        await resources.controller.start()
    }

    @ViewBuilder
    private func localPreviewHost(
        resources: AndroidVideoCallResources
    ) -> some View {
        if localPreviewFillsContainer {
            AndroidLocalVideoView(
                client: session.rtcClient,
                captureView: resources.localCaptureView,
                onDispose: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AndroidLocalVideoView(
                client: session.rtcClient,
                captureView: resources.localCaptureView,
                onDispose: {}
            )
            .frame(width: localViewSize.width, height: localViewSize.height)
            .padding(.trailing, 20)
            .padding(.bottom, localPreviewBottomPadding)
            .onChange(of: isLocalPreviewMinimized) { _, minimized in
                Self.minimizeLogger.log(
                    level: .info,
                    message: "[CallChromeMinimize] local preview overlay minimized=\(minimized)"
                )
                if layoutContainerSize.width > 1, layoutContainerSize.height > 1 {
                    localViewSize = setSize(size: layoutContainerSize)
                }
                AndroidCallChromeBridge.resetDrag(key: "local")
            }
        }
    }

    /// In-app minimize is a remote-only floating tile. Keep local mounted and hide
    /// it; attach native drag/tap after the host is boxed (not in the fullscreen factory).
    private func syncInAppPipChrome(
        resources: AndroidVideoCallResources,
        fullBleed: Bool
    ) {
        if fullBleed || isSystemPictureInPicture {
            AndroidCallChromeBridge.resetDrag(key: "pip")
            AndroidCallChromeBridge.detachDrag(key: "pip")
            AndroidCallChromeBridge.setTileTapHandler(key: "pip", handler: nil)
            AndroidCallChromeBridge.setInAppPipTapHandler(nil)
            if showsLocalPreview {
                let localMinimized = $isLocalPreviewMinimized
                AndroidCallChromeBridge.setTileTapHandler(
                    key: "local",
                    handler: {
                        localMinimized.wrappedValue.toggle()
                    }
                )
                _ = AndroidCallChromeBridge.attachLocalPreviewDrag(
                    captureView: resources.localCaptureView,
                    edgeDp: Float(20)
                )
            } else {
                AndroidCallChromeBridge.setTileTapHandler(key: "local", handler: nil)
            }
            return
        }
        AndroidCallChromeBridge.setTileTapHandler(key: "local", handler: nil)
        AndroidCallChromeBridge.setTileTapHandler(key: "pip", handler: onInAppPipTap)
        AndroidCallChromeBridge.setInAppPipTapHandler(onInAppPipTap)
        AndroidCallChromeBridge.detachDrag(key: "local")
        attachRemotePipDragIfNeeded(resources: resources)
    }

    private func toggleLocalPreviewOverlaySize() {
        isLocalPreviewMinimized.toggle()
        Self.minimizeLogger.log(
            level: .info,
            message: "[CallChromeMinimize] local preview overlay minimized=\(isLocalPreviewMinimized)"
        )
    }

    private func attachRemotePipDragIfNeeded(resources: AndroidVideoCallResources) {
        let views = visibleRemoteCaptureViews.isEmpty
            ? resources.remoteCaptureViews
            : visibleRemoteCaptureViews
        for view in views {
            if AndroidCallChromeBridge.attachRemotePipDrag(captureView: view, edgeDp: Float(16)) {
                return
            }
        }
    }

    private func applyCallVideoSurfaceVisibility(
        resources: AndroidVideoCallResources,
        source: String
    ) {
        let hideBecauseCallEnded = resources.isReleased
            || endedCall
            || isTerminalCallState(callState)
            || (isIdleCallState(callState) && didEnterLiveCall)
        let hideAll = hidesVideoSurfaces || hideBecauseCallEnded || localPreviewFillsContainer
        let hideLocal = hideBecauseCallEnded
            || hidesVideoSurfaces
            || !showsLocalPreview
            || hideLocalPreviewForInAppPictureInPicture
        resources.setVideoSurfacesHidden(hideAll, source: source)
        resources.applyLocalPreviewHidden(hideLocal, source: source)
        Task {
            await resources.controller.setKeepLocalPreviewHiddenForPictureInPicture(hideLocal)
        }
    }
    
    // MARK: - Size Management
    /// Bottom inset for the local preview so rounded corners stay above call controls
    /// and the Android system navigation bar (especially during screen share).
    private var localPreviewBottomPadding: CGFloat {
        if !expandsIntoSafeArea {
            return 8
        }
        let callControlsInset: CGFloat = 128
        let screenShareStripInset: CGFloat = hasActiveRemoteScreenShare ? 16 : 0
        return callControlsInset + screenShareStripInset
    }

    private func applyLocalPreviewOverlaySize(from container: CGSize) {
        guard container.width > 1, container.height > 1 else { return }
        let proposed = setSize(size: container)
        guard AndroidRendererLayoutPolicy.shouldReplaceLocalPreviewOverlaySize(
            currentWidth: Double(localViewSize.width),
            currentHeight: Double(localViewSize.height),
            proposedWidth: Double(proposed.width),
            proposedHeight: Double(proposed.height)
        ) else {
            return
        }
        localViewSize = proposed
    }

    /// Computes an appropriate overlay size for the local preview based on container size.
    func setSize(size: CGSize) -> CGSize {
        let policySize = GroupCallVideoLayoutPolicy.localPreviewOverlaySize(
            platform: .android,
            containerSize: GroupCallLayoutSize(
                width: Double(size.width),
                height: Double(size.height)
            ),
            isTablet: min(size.width, size.height) >= 450,
            isMinimized: isLocalPreviewMinimized
        )
        return CGSize(width: policySize.width, height: policySize.height)
    }

    private func paginateRemotes(_ source: [AndroidSampleCaptureView], pageSize: Int) -> [[AndroidSampleCaptureView]] {
        guard pageSize > 0 else { return [source] }
        guard !source.isEmpty else { return [[]] }
        var pages: [[AndroidSampleCaptureView]] = []
        var index = 0
        while index < source.count {
            let end = min(index + pageSize, source.count)
            pages.append(Array(source[index..<end]))
            index = end
        }
        return pages
    }
    
}
#endif
