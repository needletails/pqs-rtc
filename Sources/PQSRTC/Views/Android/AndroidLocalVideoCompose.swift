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

        androidx.compose.runtime.DisposableEffect(localCaptureView) {
            onDispose {
                client.removeRenderer(localCaptureView.surfaceViewRenderer)
                client.safeReleaseRenderer(localCaptureView.surfaceViewRenderer)
                onDisposeCallback()
            }
        }
        Box(
            modifier: context.modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(12.dp))
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    localCaptureView.configureRoundedOutline(radiusDp: Float(12))
                    _ = client.safelyInitializeSurfaceRenderer(localCaptureView.surfaceViewRenderer, mirror: mirrorLocalPreview)
                    localCaptureView.setMirror(mirrorLocalPreview)
                    // Match content to parent container by filling while preserving aspect
                    localCaptureView.surfaceViewRenderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                    AndroidRTCViewSupport.setZOrderMediaOverlay(renderer: localCaptureView.surfaceViewRenderer)
                    AndroidRTCViewSupport.applyRoundedOutline(view: localCaptureView.surfaceViewRenderer, radiusDp: Float(12))
                    AndroidRTCViewSupport.detachFromParent(view: localCaptureView.surfaceViewRenderer)
                    localCaptureView.surfaceViewRenderer
                },
                modifier: Modifier
                    .fillMaxSize(),
                update: { _ in }
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
                    renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                    captureView.rendererDidInitialize()
                    // Wrap-content host so the renderer measures to the sender's rotated frame
                    // aspect (letterbox) instead of Compose fillMaxSize forcing a center crop.
                    // Round the container (the visible tile), not the renderer: rounding only the
                    // letterboxed renderer leaves mixed rounded/squared corners on the tile.
                    let container = AndroidRTCViewSupport.aspectFitContainer(renderer: renderer)
                    AndroidRTCViewSupport.clearRoundedOutline(view: renderer)
                    AndroidRTCViewSupport.applyRoundedOutline(view: container, radiusDp: Float(12))
                    AndroidRTCViewSupport.detachFromParent(view: container)
                    container
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
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
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        raisedHandFlags: [Bool] = [],
        prefersAspectFit: Bool = true,
        cleanupOnDispose: Bool = true,
        usesCompactParticipantStrip: Bool = false,
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.raisedHandFlags = raisedHandFlags
        self.prefersAspectFit = prefersAspectFit
        self.cleanupOnDispose = cleanupOnDispose
        self.usesCompactParticipantStrip = usesCompactParticipantStrip
        self.onDispose = onDispose
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        androidx.compose.runtime.DisposableEffect(remoteCaptureViews) {
            onDispose {
                if cleanupOnDispose {
                    for view in remoteCaptureViews {
                        client.removeRenderer(view.surfaceViewRenderer)
                        client.safeReleaseRenderer(view.surfaceViewRenderer)
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

    /// One participant tile: black 16:9 (or full-bleed) container with rounded corners hosting
    /// the aspect-fit renderer container, so the video letterboxes to the sender's orientation
    /// while the visible tile stays uniform.
    @Composable
    private func ConferenceTile(
        view: AndroidSampleCaptureView,
        showRaisedHand: Bool,
        cornerRadiusDp: Int,
        modifier: Modifier
    ) {
        Box(
            modifier: modifier
                .clip(RoundedCornerShape(cornerRadiusDp.dp))
                .background(androidx.compose.ui.graphics.Color.Black)
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { _ in
                    _ = client.safelyInitializeSurfaceRenderer(view.surfaceViewRenderer, mirror: false)
                    view.surfaceViewRenderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                    view.rendererDidInitialize()
                    // Wrap-content host so each grid tile letterboxes to the
                    // sender's rotated frame aspect like Apple tiles. Round the
                    // container (the visible tile), not the letterboxed renderer,
                    // so tile corners are uniform.
                    let container = AndroidRTCViewSupport.aspectFitContainer(
                        renderer: view.surfaceViewRenderer
                    )
                    AndroidRTCViewSupport.clearRoundedOutline(
                        view: view.surfaceViewRenderer
                    )
                    AndroidRTCViewSupport.applyRoundedOutline(
                        view: container,
                        radiusDp: Float(cornerRadiusDp)
                    )
                    AndroidRTCViewSupport.detachFromParent(view: container)
                    container
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in
                    view.rendererDidUpdateLayoutFromCompose()
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
        itemCount > 1 ? 12 : 0
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
        Task { @MainActor in
            await Task.yield()
            isScreenSharing?.wrappedValue = isSharing
        }
    }

    public func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async {
        Task { @MainActor in
            await Task.yield()
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
    private static let minimizeLogger = NeedleTailLogger()
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
        remoteCount: Int
    ) -> AndroidVideoCallResources {
        if let existing = storage[key] {
            existing.ensureRemoteCapacity(atLeast: remoteCount)
            return existing
        }

        let created = AndroidVideoCallResources(session: session, remoteCount: remoteCount)
        storage[key] = created
        return created
    }

    static func remove(for key: String) {
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
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        raisedHandFlags: [Bool] = [],
        prefersAspectFit: Bool = true,
        cleanupOnDispose: Bool = true,
        usesCompactParticipantStrip: Bool = false,
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.raisedHandFlags = raisedHandFlags
        self.prefersAspectFit = prefersAspectFit
        self.cleanupOnDispose = cleanupOnDispose
        self.usesCompactParticipantStrip = usesCompactParticipantStrip
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
    private static let minimizeLogger = NeedleTailLogger()
    @State var resourceKey: String
    @State var currentRemotePage: Int = 0
    @State var localViewSize: CGSize = .zero
    @State var gridRaisedHandFlags: [Bool] = []
    @State var visibleRemoteCaptureViews: [AndroidSampleCaptureView] = []
    @State var mountedMultipartyRemoteSlotCount: Int = 0
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
        hidesVideoSurfaces: Bool = false
    ) {
        self.session = session
        self.remoteCount = remoteCount
        self.actionBridge = actionBridge
        self.conferenceRaisedHands = conferenceRaisedHands
        self.hidesVideoSurfaces = hidesVideoSurfaces
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self._isScreenSharing = isScreenSharing
        self._hasActiveRemoteScreenShare = hasActiveRemoteScreenShare
        self._resourceKey = State(initialValue: UUID().uuidString)
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
            remoteCount: effectiveRemoteCount
        )
        let displayedRemoteCaptureViews = isMultipartyCall
            ? visibleRemoteCaptureViews
            : Array(resources.remoteCaptureViews.prefix(max(effectiveRemoteCount, 1)))
        let remotePageSize = hasActiveRemoteScreenShare ? 8 : 12
        let remotePages = paginateRemotes(displayedRemoteCaptureViews, pageSize: remotePageSize)
        let activeRemoteCount = displayedRemoteCaptureViews.count
        let screenShareHeightFraction: CGFloat = {
            guard hasActiveRemoteScreenShare else { return 0 }
            return activeRemoteCount <= 1 ? 0.64 : 0.68
        }()

        ZStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if hasActiveRemoteScreenShare {
                        AndroidScreenShareView(
                            client: session.rtcClient,
                            captureView: resources.screenCaptureView,
                            onSurfaceLayout: {
                                Task { @MainActor in
                                    await resources.controller.setScreenView(resources.screenCaptureView)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: geo.size.height * screenShareHeightFraction)
                        .onAppear {
                            Task { @MainActor in
                                await resources.controller.setScreenView(resources.screenCaptureView)
                            }
                        }
                        .onChange(of: hasActiveRemoteScreenShare) { _, isSharing in
                            guard isSharing else { return }
                            Task { @MainActor in
                                await resources.controller.setScreenView(resources.screenCaptureView)
                            }
                        }
                        .background(Color.black)
                    }

                    if remotePages.count > 1 {
                        TabView(selection: $currentRemotePage) {
                            ForEach(Array(remotePages.enumerated()), id: \.offset) { idx, remotes in
                                AndroidRemoteGrid(
                                    client: session.rtcClient,
                                    remoteCaptureViews: remotes,
                                    raisedHandFlags: raisedHandFlags(for: remotes, allViews: displayedRemoteCaptureViews),
                                    prefersAspectFit: true,
                                    cleanupOnDispose: false,
                                    usesCompactParticipantStrip: hasActiveRemoteScreenShare,
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
                            prefersAspectFit: true,
                            cleanupOnDispose: false,
                            usesCompactParticipantStrip: hasActiveRemoteScreenShare,
                            onDispose: {}
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(hasActiveRemoteScreenShare ? 0.92 : 1.0))
                    }
                }
                
                AndroidLocalVideoView(
                    client: session.rtcClient,
                    captureView: resources.localCaptureView,
                    onDispose: {}
                )
                    .frame(width: localViewSize.width, height: localViewSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .zIndex(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, localPreviewBottomPadding(in: geo))
                    .onAppear {
                        NeedleTailLogger().log(level: .debug, message: "GEO SIZE \(geo.size)")
                        localViewSize = setSize(size: geo.size)
                    }
                    .onChange(of: geo.size) { _, newValue in
                        NeedleTailLogger().log(level: .debug, message: "NEW SIZE \(newValue)")
                        localViewSize = setSize(size: newValue)
                    }
            }
        }
        .ignoresSafeArea()
        .onChange(of: remotePages.count) { _, newCount in
            guard newCount > 0 else {
                currentRemotePage = 0
                return
            }
            currentRemotePage = min(currentRemotePage, newCount - 1)
        }
        .onChange(of: hidesVideoSurfaces) { _, hidden in
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView onChange hidesVideoSurfaces=\(hidden)"
            )
            resources.setVideoSurfacesHidden(hidden, source: "onChange")
        }
        .task(id: hidesVideoSurfaces) { @MainActor in
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView task(id:) hidesVideoSurfaces=\(hidesVideoSurfaces)"
            )
            resources.setVideoSurfacesHidden(hidesVideoSurfaces, source: "task")
        }
        .onAppear {
            Self.minimizeLogger.log(
                level: .info,
                message: "[CallChromeMinimize] AndroidVideoCallView onAppear hidesVideoSurfaces=\(hidesVideoSurfaces)"
            )
            resources.setVideoSurfacesHidden(hidesVideoSurfaces, source: "onAppear")
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
                    remoteCount: slotCount
                )
                guard updatedResources.remoteCaptureViews.count > 0 else { return }
                await updatedResources.controller.setRemoteViews(remotes: updatedResources.remoteCaptureViews)
                await refreshGridRaisedHandFlags(resources: updatedResources)
                await refreshVisibleRemoteCaptureViews(resources: updatedResources)
            }
        }
        .onChange(of: callState) { _, _ in
            Task { @MainActor in
                let slotCount = effectiveRemoteCount
                guard slotCount > 1 else { return }
                let updatedResources = AndroidVideoCallResourceStore.resources(
                    for: resourceKey,
                    session: session,
                    remoteCount: slotCount
                )
                await updatedResources.controller.setRemoteViews(remotes: updatedResources.remoteCaptureViews)
                await refreshGridRaisedHandFlags(resources: updatedResources)
                await refreshVisibleRemoteCaptureViews(resources: updatedResources)
            }
        }
        .task(id: raisedHandsRefreshToken) {
            await refreshGridRaisedHandFlags(resources: resources)
        }
        .onDisappear {
            Task { @MainActor in
                actionBridge?.clearBinding()
                await resources.controller.stop()
                AndroidVideoCallResourceStore.remove(for: resourceKey)
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
                view.rendererDidUpdateLayout()
            }
            await resources.controller.reattachAssignedParticipantVideoIfNeeded()
        }
    }

    @MainActor
    private func configureController(resources: AndroidVideoCallResources) async {
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
    
    // MARK: - Size Management
    /// Bottom inset for the local preview so rounded corners stay above call controls
    /// and the Android system navigation bar (especially during screen share).
    private func localPreviewBottomPadding(in geo: GeometryProxy) -> CGFloat {
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
