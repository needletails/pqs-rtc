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
/// This is the Android equivalent of `SampleCaptureView`.
public struct AndroidRemoteVideoCompose: ContentComposer {
    private let client: AndroidRTCClient

    public init(client: AndroidRTCClient) {
        self.client = client
    }

    @Composable
    public func Compose(context: ComposeContext) {
        let captureView = remember { AndroidCaptureViewFactory.createSampleCaptureView(client: client) }
        let renderer = remember { captureView.surfaceViewRenderer }

        androidx.compose.runtime.DisposableEffect(renderer) {
            onDispose {
                // Ensure proper cleanup when the composable leaves scope
                client.removeRenderer(renderer)
                // SKIP INSERT: try { renderer.clearImage() } catch (e: Exception) { /* Ignore if context destroyed */ }
                client.safeReleaseRenderer(renderer)
            }
        }

        Box(modifier = context.modifier) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory = { ctx in
                    // Initialize renderer on the UI thread
                    client.initializeSurfaceRenderer(renderer, mirror = false)
                    renderer
                },
                update = { view in
                    // Optional: respond to Compose state changes if needed
                }
            )
        }
    }
}


@MainActor var setRemote = false

// MARK: - Android Video Call Compose View (Parent)
/// Parent compose that renders a collection of remote views.
///
/// This view is responsible only for view creation and lifecycle callbacks; the actual call wiring
/// is performed by `AndroidVideoCallController`.
public struct AndroidRemoteGridCompose: ContentComposer {
    
    private let client: AndroidRTCClient
    private let remoteCaptureViews: [AndroidSampleCaptureView]
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.onDispose = onDispose
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        androidx.compose.runtime.DisposableEffect(remoteCaptureViews) {
            onDispose {
                for view in remoteCaptureViews {
                    client.removeRenderer(view.surfaceViewRenderer)
                    client.safeReleaseRenderer(view.surfaceViewRenderer)
                }
                onDispose()
            }
        }
        
        Box(
            modifier: context.modifier.fillMaxSize()
        ) {
            // Remote grid (simple vertical stack placeholder)
            Column(modifier: Modifier.fillMaxSize()) {
                for view in remoteCaptureViews {
                    androidx.compose.ui.viewinterop.AndroidView(
                        factory: { ctx in
                            client.initializeSurfaceRenderer(view.surfaceViewRenderer, mirror: false)
                            view.surfaceViewRenderer
                        },
                        modifier: Modifier.weight(Float(1.0)).fillMaxWidth(),
                        update: { _ in }
                    )
                }
            }
        }
    }
}
#endif

#if os(Android) || SKIP
@MainActor
fileprivate final class AndroidVideoCallCoordinator: VideoCallDelegate {
    private var errorMessage: Binding<String>
    private var endedCall: Binding<Bool>
    private var callState: Binding<CallStateMachine.State>

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
}

@MainActor
fileprivate final class AndroidVideoCallResources {
    let controller: AndroidVideoCallController
    let localCaptureView: AndroidPreviewCaptureView
    let remoteCaptureViews: [AndroidSampleCaptureView]
    var coordinator: AndroidVideoCallCoordinator?

    init(session: RTCSession, remoteCount: Int) {
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
    
    public init(client: AndroidRTCClient) {
        self.client = client
    }
    
    public var body: some View {
        ComposeView {
            AndroidRemoteVideoCompose(client: client)
        }
    }
}

/// SwiftUI wrapper that hosts a grid of remote video renderers.
public struct AndroidRemoteGrid: View {
    private let client: AndroidRTCClient
    private let remoteCaptureViews: [AndroidSampleCaptureView]
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        remoteCaptureViews: [AndroidSampleCaptureView],
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCaptureViews = remoteCaptureViews
        self.onDispose = onDispose
    }
    
    public var body: some View {
        ComposeView {
            AndroidRemoteGridCompose(
                client: client,
                remoteCaptureViews: remoteCaptureViews,
                onDispose: onDispose
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
    @State var localViewSize: CGSize = .zero
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
    
    public init(
        session: RTCSession,
        remoteCount: Int = 1,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>
    ) {
        self.session = session
        self.remoteCount = remoteCount
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self._resourceKey = State(initialValue: UUID().uuidString)
    }
    
    public var body: some View {
        let resources = AndroidVideoCallResourceStore.resources(
            for: resourceKey,
            session: session,
            remoteCount: remoteCount
        )

        ZStack {
            GeometryReader { geo in
                AndroidRemoteGrid(
                    client: session.rtcClient,
                    remoteCaptureViews: resources.remoteCaptureViews,
                    onDispose: {
                        Task { @MainActor in
                            await resources.controller.stop()
                        }
                    }
                )
                
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
        } else {
            let coordinator = AndroidVideoCallCoordinator(
                errorMessage: $errorMessage,
                endedCall: $endedCall,
                callState: $callState
            )
            resources.coordinator = coordinator
            await resources.controller.setVideoCallDelegate(coordinator)
        }

        delegate = resources.controller
        await resources.controller.setRemoteViews(remotes: resources.remoteCaptureViews)
        await resources.controller.setLocalView(local: resources.localCaptureView)
        await resources.controller.start()
    }
    
    // MARK: - Size Management
    /// Computes an appropriate overlay size for the local preview based on container size.
    func setSize(size: CGSize) -> CGSize {
        let screenWidth = size.width
        let screenHeight = size.height
        let isLandscape = screenWidth > screenHeight
        let ar = getAspectRatio(width: screenWidth, height: screenHeight)
        let minSide = min(screenWidth, screenHeight)
        let isTablet = minSide >= 450
        
        var overlayWidth: CGFloat = 0
        var overlayHeight: CGFloat = 0
        if isLandscape {
            if isTablet {
                overlayWidth = screenWidth / 4.0
                overlayHeight = (screenWidth / 4.0) / ar
            } else { // phone
                overlayWidth = screenWidth / 3.0
                overlayHeight = (screenWidth / 3.0) / ar
            }
        } else { // portrait
            if isTablet {
                overlayWidth = screenHeight / 4.0
                overlayHeight = (screenHeight / 4.0) * ar
            } else { // phone
                overlayWidth = screenHeight / 4.5
                overlayHeight = (screenHeight / 5.5) * ar
            }
        }
        return CGSize(width: overlayWidth, height: overlayHeight)
    }
    
    private func getAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        return max(width, height) / min(width, height)
    }
    
}
#endif
