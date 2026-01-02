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

import SkipUI
import SwiftUI
import NeedleTailLogger
#if canImport(SkipSwiftUI)
import SkipSwiftUI
#endif
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
    private let onLaunchEffect: (AndroidPreviewCaptureView) -> Void
    private let onDisposeCallback: () -> Void
    
    private lazy var localCaptureView: AndroidPreviewCaptureView = {
        return AndroidCaptureViewFactory.createPreviewCaptureView(client: client)
    }()
    
    public init(
        client: AndroidRTCClient,
        onLaunchEffect: @escaping (AndroidPreviewCaptureView) -> Void,
        onDispose: @escaping () -> Void) {
            self.client = client
            self.onLaunchEffect = onLaunchEffect
            self.onDisposeCallback = onDispose
        }
    
    @Composable
    public func Compose(context: ComposeContext) {
        androidx.compose.runtime.DisposableEffect(true) {
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
                    // Signal to controller after renderer is initialized to avoid race conditions
                    onLaunchEffect(localCaptureView)
                    localCaptureView.surfaceViewRenderer
                },
                modifier: Modifier
                    .fillMaxSize(),
                update: { _ in }
            )
        }
    }
    
    /// Returns the underlying preview capture view.
    public func getCaptureView() -> AndroidPreviewCaptureView {
        return localCaptureView
    }
}

// MARK: - Android Remote Video Compose View
/// Compose view that hosts a remote video renderer.
///
/// This is the Android equivalent of `SampleCaptureView`.
public struct AndroidRemoteVideoCompose: ContentComposer {
    private let client: AndroidRTCClient
    let captureView: AndroidSampleCaptureView

    public init(client: AndroidRTCClient) {
        self.client = client
        self.captureView = AndroidCaptureViewFactory.createSampleCaptureView(client: client)
    }

    @Composable
    public func Compose(context: ComposeContext) {
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

    public func getCaptureView() -> AndroidSampleCaptureView {
        return captureView
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
    private let remoteCount: Int
    private let onLaunchEffect: ([AndroidSampleCaptureView]) -> Void
    private let onDispose: () -> Void
    
    // Lazy initialization to prevent multiple creation
    private lazy var remoteCaptureViews: [AndroidSampleCaptureView] = {
        var remotes: [AndroidSampleCaptureView] = []
        if remoteCount > 0 {
            for _ in 0..<remoteCount {
                remotes.append(AndroidCaptureViewFactory.createSampleCaptureView(client: client))
            }
        }
        return remotes
    }()
    
    public init(
        client: AndroidRTCClient,
        remoteCount: Int = 1,
        onLaunchEffect: @escaping ([AndroidSampleCaptureView]) -> Void,
        onDispose: @escaping () -> Void
    ) {
        self.client = client
        self.remoteCount = remoteCount
        self.onLaunchEffect = onLaunchEffect
        self.onDispose = onDispose
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        // Start/stop controller with attached views
        androidx.compose.runtime.LaunchedEffect(key1: true) {
            onLaunchEffect(remoteCaptureViews)
        }
        androidx.compose.runtime.DisposableEffect(true) {
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
    
    public func getCaptureViews() -> [AndroidSampleCaptureView] {
        return remoteCaptureViews
    }
}
#endif

#if canImport(SkipSwiftUI)
extension SkipSwiftUI.View {
    func roundedAndroidVideoCall() -> some SkipSwiftUI.View {
        self.clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#else
extension SwiftUI.View {
    func roundedAndroidVideoCall() -> some SwiftUI.View {
        self.clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif

#if os(Android)
// MARK: - SwiftUI Wrappers
/// SwiftUI wrapper for local video preview.
///
/// This is the SwiftUI-facing wrapper around `AndroidLocalVideoCompose`.
public struct AndroidLocalVideoView: SkipSwiftUI.View {
    @State var composeView: AndroidLocalVideoCompose
    
    private let onLaunchEffect: (AndroidPreviewCaptureView) -> Void
    private let onDispose: () -> Void
    
    public init(
        client: AndroidRTCClient,
        onLaunchEffect: @escaping (AndroidPreviewCaptureView) -> Void,
        onDispose: @escaping () -> Void
    ) {
        self.onLaunchEffect = onLaunchEffect
        self.onDispose = onDispose
        self._composeView = State(initialValue: AndroidLocalVideoCompose(
            client: client,
            onLaunchEffect: onLaunchEffect,
            onDispose: onDispose))
    }
    
    public var body: some SkipSwiftUI.View {
        ComposeView {
            composeView
        }
    }
    
    /// Returns the underlying preview capture view.
    public func getCaptureView() -> AndroidPreviewCaptureView {
        return composeView.getCaptureView()
    }
}

/// SwiftUI wrapper for remote video rendering.
public struct AndroidRemoteVideoView: SkipSwiftUI.View {
    @State var composeView: AndroidRemoteVideoCompose
    
    public init(client: AndroidRTCClient) {
        self._composeView = State(initialValue: AndroidRemoteVideoCompose(client: client))
    }
    
    public var body: some SkipSwiftUI.View {
        ComposeView {
            composeView
        }
    }
    
    /// Returns the underlying sample capture view.
    public func getCaptureView() -> AndroidSampleCaptureView {
        return composeView.getCaptureView()
    }
}

/// SwiftUI wrapper that hosts a grid of remote video renderers.
public struct AndroidRemoteGrid: SkipSwiftUI.View {
    @State var composeView: AndroidRemoteGridCompose
    
    public init(
        client: AndroidRTCClient,
        remoteCount: Int,
        onLaunchEffect: @escaping ([AndroidSampleCaptureView]) -> Void,
        onDispose: @escaping () -> Void
    ) {
        self._composeView = State(initialValue:
                                    AndroidRemoteGridCompose(
                                        client: client,
                                        remoteCount: remoteCount) { (remoteCaptureViews) in
                                            onLaunchEffect(remoteCaptureViews)
                                        } onDispose: {
                                            onDispose()
                                        }
                                  
        )
    }
    
    public var body: some SkipSwiftUI.View {
        ComposeView {
            composeView
        }
    }
    
    /// Returns the underlying remote capture views.
    public func getCaptureViews() -> [AndroidSampleCaptureView] {
        return composeView.getCaptureViews()
    }
}

/// SwiftUI wrapper for a complete Android video call UI.
///
/// This view composes the remote grid and local preview overlay, and wires them to an
/// `AndroidVideoCallController` that drives media rendering and user actions.
public struct AndroidVideoCallView: SkipSwiftUI.View {
    
    private let remoteCount: Int
    private let session: RTCSession
    private let controller: AndroidVideoCallController
    @State var coordinator: Coordinator?
    @State var localViewSize: CGSize = .zero
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var videoUpgraded: Bool
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
    
    public init(
        session: RTCSession,
        remoteCount: Int = 1,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        videoUpgraded: Binding<Bool>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>
    ) {
        self.session = session
        self.remoteCount = remoteCount
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._videoUpgraded = videoUpgraded
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        
        self.controller = AndroidVideoCallController(session: session)
    }
    
    public var body: some SkipSwiftUI.View {
        ZStack {
            GeometryReader { geo in
                AndroidRemoteGrid(
                    client: session.rtcClient,
                    remoteCount: remoteCount) { views in
                        NeedleTailLogger().log(level: .debug, message: "GRID VIEWS \(views)")
                        Task { @MainActor in
                            let coord = Coordinator(self)
                            coordinator = coord
                            await controller.setVideoCallDelegate(coord)
                            delegate = controller
                            await controller.setRemoteViews(remotes: views)
                        }
                    } onDispose: {
                        Task { @MainActor in
                            await controller.stop()
                        }
                    }
                
                AndroidLocalVideoView(client: session.rtcClient) { (localCaptureView) in
                    Task { @MainActor in
                        await controller.setLocalView(local: localCaptureView)
                        await controller.start()
                    }
                } onDispose: {}
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
    
    @MainActor
    /// Delegate that bridges controller events into SwiftUI bindings.
    public final class Coordinator: VideoCallDelegate {
        var parent: AndroidVideoCallView
        
        init(_ parent: AndroidVideoCallView) {
            self.parent = parent
        }
        
        public func passErrorMessage(_ message: String) async {
            self.parent.errorMessage = message
        }
        public func videoUpgraded(_ upgraded: Bool) async {
            self.parent.videoUpgraded = upgraded
        }
        public func deliverCallState(_ state: CallStateMachine.State) async {
            self.parent.callState = state
        }
        public func endedCall(_ didEnd: Bool) async {
            self.parent.endedCall = didEnd
        }
    }
}
#endif
