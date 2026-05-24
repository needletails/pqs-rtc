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
import android.graphics.__
import android.view.__

// SKIP INSERT: private fun ntApplyRoundedOutline(view: android.view.View, radiusDp: Float) {
// SKIP INSERT:     val radiusPx = radiusDp * view.resources.displayMetrics.density
// SKIP INSERT:     view.clipToOutline = true
// SKIP INSERT:     view.outlineProvider = object : android.view.ViewOutlineProvider() {
// SKIP INSERT:         override fun getOutline(v: android.view.View, outline: android.graphics.Outline) {
// SKIP INSERT:             outline.setRoundRect(0, 0, v.width, v.height, radiusPx)
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT: }

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

        androidx.compose.runtime.DisposableEffect(localCaptureView) {
            onDispose {
                client.removeRenderer(localCaptureView.surfaceViewRenderer)
                client.safeReleaseRenderer(localCaptureView.surfaceViewRenderer)
                onDisposeCallback()
            }
        }
        Box(
            modifier: context.modifier.fillMaxSize()
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    client.initializeSurfaceRenderer(localCaptureView.surfaceViewRenderer, mirror: true)
                    // Match content to parent container by filling while preserving aspect
                    localCaptureView.surfaceViewRenderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                    // SKIP INSERT: localCaptureView.surfaceViewRenderer.setZOrderMediaOverlay(true)
                    // SKIP INSERT: ntApplyRoundedOutline(localCaptureView.surfaceViewRenderer, 12f)
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
                // SKIP INSERT: try { renderer.clearImage() } catch (e: Exception) { /* Ignore if context destroyed */ }
                client.safeReleaseRenderer(renderer)
            }
        }

        Box(modifier: context.modifier.fillMaxSize()) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    client.initializeSurfaceRenderer(renderer, mirror: false)
                    renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                    renderer
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in }
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

    public init(
        client: AndroidRTCClient,
        captureView: AndroidSampleCaptureView,
        presenterName: String = "Presenting"
    ) {
        self.client = client
        self.captureView = captureView
        self.presenterName = presenterName
    }

    @Composable
    public func Compose(context: ComposeContext) {
        let renderer = captureView.surfaceViewRenderer

        androidx.compose.runtime.DisposableEffect(renderer) {
            onDispose {
                client.removeRenderer(renderer)
                client.safeReleaseRenderer(renderer)
            }
        }

        Box(modifier: context.modifier.fillMaxSize()) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    client.initializeSurfaceRenderer(renderer, mirror: false)
                    renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                    renderer
                },
                modifier: Modifier.fillMaxSize(),
                update: { _ in }
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
    private let cleanupOnDispose: Bool
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        cleanupOnDispose: Bool = true,
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.cleanupOnDispose = cleanupOnDispose
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
            let grid = conferenceGridDimensions(for: remoteCaptureViews.count)
            let rows = chunked(remoteCaptureViews, size: grid.columns)
            Column(modifier: Modifier.fillMaxSize()) {
                for row in rows {
                    Row(modifier: Modifier.weight(Float(1.0)).fillMaxWidth()) {
                        for view in row {
                            androidx.compose.ui.viewinterop.AndroidView(
                                factory: { _ in
                                    client.initializeSurfaceRenderer(view.surfaceViewRenderer, mirror: false)
                                    view.surfaceViewRenderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                                    view.surfaceViewRenderer
                                },
                                modifier: Modifier.weight(Float(1.0)).fillMaxWidth().fillMaxHeight(),
                                update: { _ in }
                            )
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

    private func conferenceGridDimensions(for itemCount: Int) -> (columns: Int, rows: Int) {
        switch itemCount {
        case 0:
            return (1, 1)
        case 1:
            return (1, 1)
        case 2:
            return (2, 1)
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

#if os(Android) || SKIP
@MainActor
fileprivate final class AndroidVideoCallCoordinator: VideoCallDelegate {
    private var errorMessage: Binding<String>
    private var endedCall: Binding<Bool>
    private var callState: Binding<CallStateMachine.State>
    var isScreenSharing: Binding<Bool>?
    var hasActiveRemoteScreenShare: Binding<Bool>?

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
        isScreenSharing?.wrappedValue = isSharing
    }

    public func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async {
        hasActiveRemoteScreenShare?.wrappedValue = isSharing
    }
}

@MainActor
fileprivate final class AndroidVideoCallResources {
    let controller: AndroidVideoCallController
    let localCaptureView: AndroidPreviewCaptureView
    let remoteCaptureViews: [AndroidSampleCaptureView]
    /// Lazily created view for rendering a remote screen share.
    lazy var screenCaptureView: AndroidSampleCaptureView = AndroidCaptureViewFactory.createSampleCaptureView(client: _client)
    var coordinator: AndroidVideoCallCoordinator?
    private let _client: AndroidRTCClient

    init(session: RTCSession, remoteCount: Int) {
        self._client = session.rtcClient
        self.controller = AndroidVideoCallController(session: session)
        self.localCaptureView = AndroidCaptureViewFactory.createPreviewCaptureView(client: session.rtcClient)

        var remotes: [AndroidSampleCaptureView] = []
        if remoteCount > 0 {
            for _ in 0..<remoteCount {
                remotes.append(AndroidCaptureViewFactory.createSampleCaptureView(client: session.rtcClient))
            }
        }
        self.remoteCaptureViews = remotes
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
    private let cleanupOnDispose: Bool
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        cleanupOnDispose: Bool = true,
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.cleanupOnDispose = cleanupOnDispose
        self.onDispose = onDispose
    }
    
    public var body: some View {
        ComposeView {
            AndroidRemoteGridCompose(
                client: client,
                remoteCaptureViews: remoteCaptureViews,
                cleanupOnDispose: cleanupOnDispose,
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

    public init(
        client: AndroidRTCClient,
        captureView: AndroidSampleCaptureView,
        presenterName: String = "Presenting"
    ) {
        self.client = client
        self.captureView = captureView
        self.presenterName = presenterName
    }

    public var body: some View {
        ComposeView {
            AndroidScreenShareCompose(
                client: client,
                captureView: captureView,
                presenterName: presenterName
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
    @State var resourceKey: String
    @State var currentRemotePage: Int = 0
    @State var localViewSize: CGSize = .zero
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
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        isScreenSharing: Binding<Bool> = .constant(false),
        hasActiveRemoteScreenShare: Binding<Bool> = .constant(false)
    ) {
        self.session = session
        self.remoteCount = remoteCount
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
    
    public var body: some View {
        let resources = AndroidVideoCallResourceStore.resources(
            for: resourceKey,
            session: session,
            remoteCount: remoteCount
        )
        let remotePageSize = hasActiveRemoteScreenShare ? 8 : 12
        let remotePages = paginateRemotes(resources.remoteCaptureViews, pageSize: remotePageSize)

        ZStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if hasActiveRemoteScreenShare {
                        AndroidScreenShareView(
                            client: session.rtcClient,
                            captureView: resources.screenCaptureView
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: geo.size.height * 0.66)
                        .onAppear {
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
                                    cleanupOnDispose: false,
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
                            remoteCaptureViews: resources.remoteCaptureViews,
                            onDispose: {
                                Task { @MainActor in
                                    await resources.controller.stop()
                                }
                            }
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
                    .clipped()
                    .zIndex(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 100)
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
        .onAppear {
            Task { @MainActor in
                await configureController(resources: resources)
            }
        }
        .onDisappear {
            Task { @MainActor in
                await resources.controller.stop()
                AndroidVideoCallResourceStore.remove(for: resourceKey)
            }
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
        } else {
            let coordinator = AndroidVideoCallCoordinator(
                errorMessage: $errorMessage,
                endedCall: $endedCall,
                callState: $callState
            )
            coordinator.isScreenSharing = $isScreenSharing
            coordinator.hasActiveRemoteScreenShare = $hasActiveRemoteScreenShare
            resources.coordinator = coordinator
            await resources.controller.setVideoCallDelegate(coordinator)
        }

        delegate = resources.controller
        await resources.controller.setVideoViews(
            local: resources.localCaptureView,
            remotes: resources.remoteCaptureViews
        )
        await resources.controller.start()
    }
    
    // MARK: - Size Management
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
