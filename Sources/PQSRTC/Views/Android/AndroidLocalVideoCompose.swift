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
                    localCaptureView.configureRoundedOutline(radiusDp: Float(12))
                    AndroidRTCViewSupport.detachFromParent(view: host)
                    host
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
                    _ = AndroidRTCViewSupport.localPreviewHostContainer(
                        previewView: localCaptureView.previewDisplayView,
                        cornerRadiusDp: Float(12)
                    )
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
                    _ = AndroidRTCViewSupport.remoteCameraHostContainer(
                        renderer: renderer,
                        prefersAspectFit: false,
                        cornerRadiusDp: Float(0),
                        fillWhenOrientationMatches: true
                    )
                    captureView.rendererDidUpdateLayoutFromCompose()
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
                    captureView.rendererDidUpdateLayoutFromCompose()
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
    /// screen share. On phones this selects the horizontal 16:9 collection; full-screen
    /// conference keeps the vertical grid.
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
            let isPhoneLayout = min(configuration.screenWidthDp, configuration.screenHeightDp) < 600
            // Horizontal participant collection is only for the screen-share camera strip on
            // phones. Full-screen conference view keeps the vertical 16:9 grid.
            let useScreenSharePhoneHorizontalStrip =
                usesCompactParticipantStrip && isPhoneLayout && itemCount > 1

            if useScreenSharePhoneHorizontalStrip {
                let callControlsInsetDp = 112
                Row(
                    modifier: Modifier
                        .fillMaxSize()
                        .padding(bottom: callControlsInsetDp.dp)
                        .navigationBarsPadding()
                        .horizontalScroll(rememberScrollState())
                        .padding(contentPaddingDp.dp),
                    horizontalArrangement: Arrangement.spacedBy(tileSpacingDp.dp),
                    verticalAlignment: androidx.compose.ui.Alignment.CenterVertically
                ) {
                    for (view, showRaisedHand) in flaggedViews {
                        let rendererSlotKey = Int(view.surfaceViewRenderer.hashCode())
                        androidx.compose.runtime.key(rendererSlotKey) {
                            ConferenceTile(
                                view: view,
                                showRaisedHand: showRaisedHand,
                                cornerRadiusDp: tileCornerRadiusDp,
                                enablesPipDrag: capturedEnablesCallChromeDrag,
                                modifier: Modifier
                                    .fillMaxHeight()
                                    .aspectRatio(Float(16.0 / 9.0))
                            )
                        }
                    }
                }
            } else {
                let grid = conferenceGridDimensions(for: itemCount, isPortrait: isPortrait)
                let rows = chunked(flaggedViews, size: grid.columns)
                Column(
                    modifier: Modifier.fillMaxSize().padding(contentPaddingDp.dp),
                    verticalArrangement: Arrangement.spacedBy(tileSpacingDp.dp)
                ) {
                    for row in rows {
                        Row(
                            modifier: Modifier.weight(Float(1.0)).fillMaxWidth(),
                            horizontalArrangement: Arrangement.spacedBy(tileSpacingDp.dp)
                        ) {
                            for (view, showRaisedHand) in row {
                                let rendererSlotKey = Int(view.surfaceViewRenderer.hashCode())
                                androidx.compose.runtime.key(rendererSlotKey) {
                                    if itemCount == 1 {
                                        // Solo tile keeps the full-bleed layout.
                                        ConferenceTile(
                                            view: view,
                                            showRaisedHand: showRaisedHand,
                                            cornerRadiusDp: tileCornerRadiusDp,
                                            enablesPipDrag: capturedEnablesCallChromeDrag,
                                            modifier: Modifier
                                                .weight(Float(1.0))
                                                .fillMaxHeight()
                                        )
                                    } else {
                                        // Equal grid cell hosting a centered uniform 16:9 tile so
                                        // every participant container has the same width/height.
                                        Box(
                                            modifier: Modifier
                                                .weight(Float(1.0))
                                                .fillMaxHeight(),
                                            contentAlignment: androidx.compose.ui.Alignment.Center
                                        ) {
                                            ConferenceTile(
                                                view: view,
                                                showRaisedHand: showRaisedHand,
                                                cornerRadiusDp: tileCornerRadiusDp,
                                                enablesPipDrag: capturedEnablesCallChromeDrag,
                                                modifier: Modifier.aspectRatio(Float(16.0 / 9.0))
                                            )
                                        }
                                    }
                                }
                            }
                            let missingColumns = max(0, grid.columns - row.count)
                            if missingColumns > 0 {
                                for _ in 0..<missingColumns {
                                    Spacer(modifier: Modifier.weight(Float(1.0)).fillMaxHeight())
                                }
                            }
                        }
                    }
                    let missingRows = max(0, grid.rows - rows.count)
                    if missingRows > 0 {
                        for _ in 0..<missingRows {
                            Spacer(modifier: Modifier.weight(Float(1.0)).fillMaxWidth())
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
        modifier: Modifier
    ) {
        let tileModifier = enablesPipDrag
            ? modifier.background(androidx.compose.ui.graphics.Color.Black)
            : modifier
                .clip(RoundedCornerShape(cornerRadiusDp.dp))
                .background(androidx.compose.ui.graphics.Color.Black)
        Box(
            modifier: tileModifier
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { _ in
                    _ = client.safelyInitializeSurfaceRenderer(view.surfaceViewRenderer, mirror: false)
                    view.rendererDidInitialize()
                    let host = AndroidRTCViewSupport.remoteCameraHostContainer(
                        renderer: view.surfaceViewRenderer,
                        prefersAspectFit: prefersAspectFit,
                        cornerRadiusDp: Float(cornerRadiusDp),
                        fillWhenOrientationMatches: !prefersAspectFit
                    )
                    AndroidRTCViewSupport.detachFromParent(view: host)
                    if enablesPipDrag {
                        AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
                            seed: host,
                            key: "pip",
                            enableTap: true,
                            edgeDp: Float(16)
                        )
                    }
                    host
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
                    let host = AndroidRTCViewSupport.remoteCameraHostContainer(
                        renderer: view.surfaceViewRenderer,
                        prefersAspectFit: prefersAspectFit,
                        cornerRadiusDp: Float(cornerRadiusDp),
                        fillWhenOrientationMatches: !prefersAspectFit
                    )
                    if enablesPipDrag {
                        AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
                            seed: host,
                            key: "pip",
                            enableTap: true,
                            edgeDp: Float(16)
                        )
                    } else {
                        AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(
                            key: "pip"
                        )
                    }
                    view.rendererDidUpdateLayoutFromCompose()
                    _ = layoutGeneration
                    onParticipantSurfaceLayout(view)
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

    private func conferenceGridDimensions(for itemCount: Int, isPortrait: Bool) -> (columns: Int, rows: Int) {
        switch itemCount {
        case 0:
            return (1, 1)
        case 1:
            return (1, 1)
        case 2:
            return isPortrait ? (1, 2) : (2, 1)
        case 3...4:
            return (2, 2)
        case 5...6:
            return (3, 2)
        case 7...9:
            return (3, 3)
        default:
            return (4, 3)
        }
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

    private func conferenceTileCornerRadiusDp(for itemCount: Int) -> Int {
        itemCount > 1 ? 12 : soloTileCornerRadiusDp
    }

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
    private static let minimizeLogger = NeedleTailLogger()
    private static let lifecycleLogger = NeedleTailLogger()
    /// Lazily created view for rendering a remote screen share.
    var screenCaptureView: AndroidSampleCaptureView {
        if let existing = _screenCaptureView { return existing }
        let created = AndroidCaptureViewFactory.createSampleCaptureView(client: _client)
        created.setHidden(videoSurfacesHidden)
        _screenCaptureView = created
        return created
    }
    var coordinator: AndroidVideoCallCoordinator?
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
#if SKIP
        AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: "pip")
        AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: "local")
        AndroidCallChromeNativeSupport.setInAppPipTapHandler(handler: nil)
#endif
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
    /// In-app and system PiP show remote video only. Keep `AndroidLocalVideoView` mounted
    /// and hide the SurfaceView — unmounting runs Compose `onDispose` and releases EGL.
    private let showsLocalPreview: Bool
    /// Native SurfaceView drag owns pointer move. This restores chrome on a PiP tap.
    private let onInAppPipTap: (() -> Void)?
    private static let minimizeLogger = NeedleTailLogger()
    /// One call UI at a time. A per-appear UUID remounts a new renderer pool on every
    /// chrome/PiP transition and releases EGL on the main thread.
    private static let activeCallResourceKey = "android-active-video-call"
    @State var resourceKey: String
    @State var currentRemotePage: Int = 0
    /// Non-zero so the local SurfaceView is never first measured at 0×0 (that skips surface
    /// creation and leaves the preview queued forever).
    @State var localViewSize: CGSize = CGSize(width: 140, height: 249)
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
        onInAppPipTap: (() -> Void)? = nil
    ) {
        self.session = session
        self.remoteCount = remoteCount
        self.actionBridge = actionBridge
        self.conferenceRaisedHands = conferenceRaisedHands
        self.hidesVideoSurfaces = hidesVideoSurfaces
        self.expandsIntoSafeArea = expandsIntoSafeArea
        self.showsLocalPreview = showsLocalPreview
        self.onInAppPipTap = onInAppPipTap
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

    /// Size the renderer pool from roster/remote count. Group calls keep two slots mounted so the
    /// first assigned participant does not remount through a fullscreen `SurfaceViewRenderer`.
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
        let displayedRemoteCaptureViews = isMultipartyCall
            ? visibleRemoteCaptureViews
            : Array(resources.remoteCaptureViews.prefix(max(effectiveRemoteCount, 1)))
        let remotePageSize = hasActiveRemoteScreenShare ? 8 : 12
        let remotePages = paginateRemotes(displayedRemoteCaptureViews, pageSize: remotePageSize)
        let activeRemoteCount = displayedRemoteCaptureViews.count
        // Solo fullscreen remote fills when orientations match; multi-remote grids (and the
        // screen-share camera strip) keep aspect-fit letterboxing inside tiles.
        let remotePrefersAspectFit = activeRemoteCount > 1 || hasActiveRemoteScreenShare
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

        ZStack {
            GeometryReader { geo in
                // Explicit overlay: Skip's GeometryReader can stack a ViewBuilder tuple like a
                // column, which measures the local SurfaceView at 0×0 and never creates a surface.
                ZStack(alignment: .topLeading) {
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
                            .frame(height: geo.size.height * screenShareHeightFraction)
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
                                        usesCompactParticipantStrip: hasActiveRemoteScreenShare,
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
                                usesCompactParticipantStrip: hasActiveRemoteScreenShare,
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
                    .frame(width: geo.size.width, height: geo.size.height)

                    let previewW = localViewSize.width
                    let previewH = localViewSize.height
                    let previewEdge: CGFloat = 20
                    let previewBottomPad = localPreviewBottomPadding(in: geo)
                    let previewMaxX = max(previewEdge, geo.size.width - previewW - previewEdge)
                    let previewMaxY = max(previewEdge, geo.size.height - previewH - previewBottomPad)
                    let previewDefaultX = previewMaxX
                    let previewDefaultY = previewMaxY
                    // Default bottom-trailing only. Native translationX/Y owns drag
                    // so pointer-move does not recompose Skip/Compose or resize EGL.
                    let previewX: CGFloat = showsLocalPreview
                        ? previewDefaultX
                        : geo.size.width + 400
                    let previewY: CGFloat = showsLocalPreview ? previewDefaultY : 0

                    AndroidLocalVideoView(
                        client: session.rtcClient,
                        captureView: resources.localCaptureView,
                        onDispose: {}
                    )
                    .frame(width: previewW, height: previewH)
                    .padding(.leading, previewX)
                    .padding(.top, previewY)
                    .onAppear {
                        NeedleTailLogger().log(level: .debug, message: "GEO SIZE \(geo.size)")
                        if showsLocalPreview {
                            localViewSize = setSize(size: geo.size)
                        }
                    }
                    .onChange(of: geo.size) { _, newValue in
                        NeedleTailLogger().log(level: .debug, message: "NEW SIZE \(newValue)")
                        if showsLocalPreview {
                            localViewSize = setSize(size: newValue)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .onChange(of: remotePages.count) { _, newCount in
            guard newCount > 0 else {
                currentRemotePage = 0
                return
            }
            currentRemotePage = min(currentRemotePage, newCount - 1)
        }
        .task(id: "\(isScreenSharing)-\(hasActiveRemoteScreenShare)") {
            let controller = resources.controller
            let isSharing = isScreenSharing || hasActiveRemoteScreenShare
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
#if SKIP
            if visible {
                let previewView = resources.localCaptureView.previewDisplayView
                if let host = AndroidRTCViewSupport.localPreviewHostOrNull(previewView: previewView) {
                    AndroidCallChromeNativeSupport.resetNativeCallChromeDrag(key: "local")
                    AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
                        seed: host,
                        key: "local",
                        enableTap: false,
                        edgeDp: Float(20)
                    )
                }
            } else {
                AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: "local")
            }
#endif
        }
        .onChange(of: expandsIntoSafeArea) { _, fullBleed in
#if SKIP
            if fullBleed {
                AndroidCallChromeNativeSupport.resetNativeCallChromeDrag(key: "pip")
                AndroidCallChromeNativeSupport.detachNativeCallChromeDrag(key: "pip")
                AndroidCallChromeNativeSupport.resetNativeCallChromeDrag(key: "local")
                AndroidCallChromeNativeSupport.setInAppPipTapHandler(handler: nil)
            } else {
                AndroidCallChromeNativeSupport.setInAppPipTapHandler(handler: onInAppPipTap)
            }
#endif
            applyCallVideoSurfaceVisibility(
                resources: resources,
                source: "onChange expandsIntoSafeArea"
            )
        }
        .task(id: "\(hidesVideoSurfaces)-\(showsLocalPreview)") { @MainActor in
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView task(id:) hidesVideoSurfaces=\(hidesVideoSurfaces) showsLocalPreview=\(showsLocalPreview)"
            )
            applyCallVideoSurfaceVisibility(resources: resources, source: "task")
        }
        .onAppear {
            if isLiveCallState(callState) {
                didEnterLiveCall = true
            }
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView onAppear hidesVideoSurfaces=\(hidesVideoSurfaces) showsLocalPreview=\(showsLocalPreview)"
            )
            applyCallVideoSurfaceVisibility(resources: resources, source: "onAppear")
#if SKIP
            if expandsIntoSafeArea {
                AndroidCallChromeNativeSupport.setInAppPipTapHandler(handler: nil)
            } else {
                AndroidCallChromeNativeSupport.setInAppPipTapHandler(handler: onInAppPipTap)
            }
#endif
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
            || endedCall
            || isTerminalCallState(callState)
            || (isIdleCallState(callState) && didEnterLiveCall)
        guard shouldTeardown else {
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] skipping renderer teardown on transient disappear reason=\(reason) state=\(callState)"
            )
            return
        }
        didEnterLiveCall = false
        resources.releaseAllVideoRenderers()
        Task { @MainActor in
            actionBridge?.clearBinding()
            await resources.controller.stop()
            AndroidVideoCallResourceStore.remove(for: resourceKey)
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

    /// Multiparty grids mount a stable pool prefix so `AndroidRemoteGrid` itemCount matches the
    /// expected roster layout without remounting assigned tiles through a transient one-up grid.
    @MainActor
    private func multipartyRemoteCaptureViews(from resources: AndroidVideoCallResources) async -> [AndroidSampleCaptureView] {
        let assignedCount = await resources.controller.assignedParticipantCount()
        let slotCount = AndroidMultipartyVideoLayout.multipartyGridSlotCount(
            assignedParticipantCount: assignedCount,
            rosterRemoteSlotCount: effectiveRemoteCount,
            poolSize: resources.remoteCaptureViews.count
        )
        mountedMultipartyRemoteSlotCount = slotCount
        return Array(resources.remoteCaptureViews.prefix(slotCount))
    }

    @MainActor
    private func refreshGridRaisedHandFlags(resources: AndroidVideoCallResources) async {
        await resources.controller.updateConferenceRaisedHands(conferenceRaisedHands)
        let views = isMultipartyCall
            ? await multipartyRemoteCaptureViews(from: resources)
            : resources.remoteCaptureViews
        gridRaisedHandFlags = await resources.controller.raisedHandFlags(for: views)
    }

    @MainActor
    private func refreshVisibleRemoteCaptureViews(resources: AndroidVideoCallResources) async {
        let previousViews = visibleRemoteCaptureViews
        let previousSignature = await resources.controller.participantAssignmentSignature()
        let previousVisibleCount = previousViews.count
        if !isMultipartyCall {
            mountedMultipartyRemoteSlotCount = 0
        }
        visibleRemoteCaptureViews = isMultipartyCall
            ? await multipartyRemoteCaptureViews(from: resources)
            : resources.remoteCaptureViews
        let signature = await resources.controller.participantAssignmentSignature()
        let nextVisibleCount = visibleRemoteCaptureViews.count
        let gridLayoutChanged = AndroidMultipartyVideoLayout.shouldReattachAssignedParticipantVideo(
            previousVisibleCount: previousVisibleCount,
            nextVisibleCount: nextVisibleCount,
            previousSignature: previousSignature,
            nextSignature: signature
        )
        if gridLayoutChanged {
            for view in visibleRemoteCaptureViews {
                view.rendererDidUpdateLayoutFromCompose()
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

    /// Apply hide-all first, then the local-only PiP override so a skipped
    /// `setVideoSurfacesHidden` (already false) still hides the preview.
    /// Hangup expands chrome while this view can still be mounted — keep every
    /// native surface down once the call is over so TextureView cannot flash.
    private func applyCallVideoSurfaceVisibility(
        resources: AndroidVideoCallResources,
        source: String
    ) {
        let hideBecauseCallEnded = resources.isReleased
            || endedCall
            || isTerminalCallState(callState)
            || (isIdleCallState(callState) && didEnterLiveCall)
        let hideAll = hidesVideoSurfaces || hideBecauseCallEnded
        let hideLocal = hideAll || !showsLocalPreview
        resources.setVideoSurfacesHidden(hideAll, source: source)
        resources.applyLocalPreviewHidden(hideLocal, source: source)
        Task {
            await resources.controller.setKeepLocalPreviewHiddenForPictureInPicture(hideLocal)
        }
    }
    
    // MARK: - Size Management
    /// Bottom inset for the local preview so rounded corners stay above call controls
    /// and the Android system navigation bar (especially during screen share).
    private func localPreviewBottomPadding(in geo: GeometryProxy) -> CGFloat {
        if !expandsIntoSafeArea {
            return 8
        }
        let callControlsInset: CGFloat = 128
        let screenShareStripInset: CGFloat = hasActiveRemoteScreenShare ? 16 : 0
        return callControlsInset + geo.safeAreaInsets.bottom + screenShareStripInset
    }

    /// Computes an appropriate overlay size for the local preview based on container size.
    func setSize(size: CGSize) -> CGSize {
        let screenWidth = size.width
        let screenHeight = size.height
        let isLandscape = screenWidth > screenHeight
        let minSide = min(screenWidth, screenHeight)
        let isTablet = minSide >= 450

        let maxOverlayWidth: CGFloat = isTablet ? 240 : 180
        let widthFraction: CGFloat = isTablet ? 0.28 : 0.34
        let overlayWidth = min(maxOverlayWidth, minSide * widthFraction)
        let overlayHeight = isLandscape ? overlayWidth * (9.0 / 16.0) : overlayWidth * (16.0 / 9.0)

        return CGSize(width: overlayWidth, height: overlayHeight)
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
