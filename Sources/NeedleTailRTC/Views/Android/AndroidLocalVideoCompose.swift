//  AndroidComposeViews.swift
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
import SkipFuseUI
#if SKIP
import androidx.compose.runtime.__
import androidx.compose.ui.__
import androidx.compose.foundation.__
import androidx.compose.foundation.layout.__
import androidx.compose.ui.viewinterop.__

// MARK: - Android Local Video Compose View
/// Simple Compose view for local video - equivalent to iOS PreviewCaptureView
/// NeedleTailRTC calls into this view and handles all state management
public struct AndroidLocalVideoCompose: ContentComposer {
    let captureView: AndroidPreviewCaptureView
    
    public init() {
        self.captureView = AndroidCaptureViewFactory.createPreviewCaptureView()
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        Box(
            modifier: context.modifier
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    captureView.surfaceViewRenderer
                },
                update: { view in
                    // no-op; add dynamic updates if needed
                }
            )
        }
    }
    
    /// Get the capture view for NeedleTailRTC integration
    public func getCaptureView() -> AndroidPreviewCaptureView {
        return captureView
    }
}

// MARK: - Android Remote Video Compose View
/// Simple Compose view for remote video - equivalent to iOS SampleCaptureView
/// NeedleTailRTC calls into this view and handles all state management
public struct AndroidRemoteVideoCompose: ContentComposer {
    let captureView: AndroidSampleCaptureView
    
    public init() {
        self.captureView = AndroidCaptureViewFactory.createSampleCaptureView()
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        Box(
            modifier: context.modifier
        ) {
            androidx.compose.ui.viewinterop.AndroidView(
                factory: { ctx in
                    captureView.surfaceViewRenderer
                },
                update: { view in
                    // no-op; add dynamic updates if needed
                }
            )
        }
    }
    
    /// Get the capture view for NeedleTailRTC integration
    public func getCaptureView() -> AndroidSampleCaptureView {
        return captureView
    }
}

// MARK: - Android Video Call Compose View (Parent)
/// Parent compose that manages call state (via AndroidVideoCallController), renders a collection of remote views,
/// and overlays the local preview view (mirrors Apple controllers behavior).
public struct AndroidVideoCallCompose: ContentComposer {
    private let remoteCount: Int
    private let localCaptureView: AndroidPreviewCaptureView
    private let remoteCaptureViews: [AndroidSampleCaptureView]
    private let onLaunchEffect: @escaping (AndroidPreviewCaptureView, [AndroidSampleCaptureView]) -> Void
    private let onDispose: @escaping () -> Void
    
    public init(
        remoteCount: Int = 1,
        onLaunchEffect: @escaping (AndroidPreviewCaptureView, [AndroidSampleCaptureView]) -> Void,
        onDispose: @escaping () -> Void
    ) {
        self.remoteCount = remoteCount
        self.onLaunchEffect = onLaunchEffect
        self.onDispose = onDispose
        self.localCaptureView = AndroidCaptureViewFactory.createPreviewCaptureView()
        var remotes: [AndroidSampleCaptureView] = []
        if remoteCount > 0 {
            for _ in 0..<remoteCount {
                remotes.append(AndroidCaptureViewFactory.createSampleCaptureView())
            }
        }
        self.remoteCaptureViews = remotes
    }
    
    @Composable
    public func Compose(context: ComposeContext) {
        // Start/stop controller with attached views
        androidx.compose.runtime.LaunchedEffect(key1: true) {
            onLaunchEffect(localCaptureView, remoteCaptureViews)
        }
        androidx.compose.runtime.DisposableEffect(true) {
            onDispose {
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
                        factory: {
                            ctx in view.surfaceViewRenderer
                        },
                        modifier: Modifier.weight(Float(1.0)).fillMaxWidth(),
                        update: { view in
                            // no-op; add dynamic updates if needed
                        }
                    )
                }
            }
            // Local overlay (top-right)
            Box(
                modifier: Modifier.align(androidx.compose.ui.Alignment.BottomEnd)
            ) {
                androidx.compose.ui.viewinterop.AndroidView(
                    factory: { ctx in
                        localCaptureView.surfaceViewRenderer
                    },
                    update: { _ in }
                )
            }
        }
    }
}
#endif

#if os(Android)
// MARK: - SwiftUI Wrappers
/// SwiftUI wrapper for local video - equivalent to iOS PreviewCaptureView
public struct AndroidLocalVideoView: View {
    let composeView: AndroidLocalVideoCompose
    
    public init() {
        self.composeView = AndroidLocalVideoCompose()
    }
    
    public var body: some View {
        ComposeView {
            composeView
        }
    }
    
    /// Get the capture view for NeedleTailRTC integration
    public func getCaptureView() -> AndroidPreviewCaptureView {
        return composeView.getCaptureView()
    }
}

/// SwiftUI wrapper for remote video - equivalent to iOS SampleCaptureView
public struct AndroidRemoteVideoView: View {
    let composeView: AndroidRemoteVideoCompose
    
    public init() {
        self.composeView = AndroidRemoteVideoCompose()
    }
    
    public var body: some View {
        ComposeView {
            composeView
        }
    }
    
    /// Get the capture view for NeedleTailRTC integration
    public func getCaptureView() -> AndroidSampleCaptureView {
        return composeView.getCaptureView()
    }
}

/// SwiftUI wrapper for complete video call
public struct AndroidVideoCallView: View {

    private let remoteCount: Int
    private let session: RTCSession
    private let controller: AndroidVideoCallController
    @State var coordinator: Coordinator?
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
    
    public var body: some View {
        ComposeView {
            AndroidVideoCallCompose(remoteCount: remoteCount) { (localCaptureView, remoteCaptureViews) in
                Task { @MainActor in
                    let coord = Coordinator(self)
                    self.coordinator = coord
                    controller.videoCallDelegate = coord
                    delegate = controller
                    if !remoteCaptureViews.isEmpty {
                        controller.attachViews(
                            local: localCaptureView,
                            remotes: remoteCaptureViews)
                    }
                    controller.start()
                }
            } onDispose: {
                Task { @MainActor in
                    await controller.stop()
                }
            }
            
        }
    }
    
    @MainActor
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
