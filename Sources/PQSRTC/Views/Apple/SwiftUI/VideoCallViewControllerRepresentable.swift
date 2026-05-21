//
//  VideoCallViewControllerRepresentable.swift
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

#if !os(Android)
import Foundation
import SwiftUI
#endif

#if os(iOS)
import UIKit

/// Forwards mute/end actions to the hosted ``VideoCallViewController``.
///
/// Host apps should keep one instance in `@State` and pass it into ``VideoCallViewControllerRepresentable``
/// instead of relying on `Binding<CallActionDelegate?>` to hold the controller: assigning a
/// `UIViewController` into that binding is not reliably persisted across SwiftUI updates in some stacks
/// (e.g. SkipFuseUI), which leaves overlay controls with a `nil` delegate.
@MainActor
public final class VideoCallActionBridge: CallActionDelegate, @unchecked Sendable {
    public weak var viewController: VideoCallViewController?

    public init() {}

    public func endCall() async {
        await viewController?.endCall()
    }

    public func muteAudio() async {
        await viewController?.muteAudio()
    }

    public func setAudioMuted(_ muted: Bool) async {
        await viewController?.setAudioMuted(muted)
    }

    public func muteVideo() async {
        await viewController?.muteVideo()
    }

    public func showPictureInPicture(_ show: Bool) async {
        await viewController?.showPictureInPicture(show)
    }

    public func startScreenShare(target: ScreenShareTarget) async {
        await viewController?.startScreenShare(target: target)
    }

    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        await viewController?.startScreenShare(target: target, options: options)
    }

    public func stopScreenShare() async {
        await viewController?.stopScreenShare()
    }

    /// Audio-only calls: route playback to speaker or receiver/Bluetooth (matches system Phone behavior).
    public func setSpeakerOutputEnabled(_ enabled: Bool) {
        viewController?.setSpeakerOutputEnabled(enabled)
    }
}

@MainActor
/// SwiftUI wrapper around the platform `VideoCallViewController` (iOS).
///
/// This representable bridges the SDK’s UIKit call UI into SwiftUI and wires up:
/// - `CallActionDelegate` (user actions like end/mute)
/// - `VideoCallDelegate` (state/error callbacks)
/// - optional embedded controls via a SwiftUI `View`
public struct VideoCallViewControllerRepresentable: UIViewControllerRepresentable {
    
    private let session: RTCSession
    /// When set, the representable assigns the live controller to this bridge; overlay code can call mute/end on the bridge without depending on `delegate` binding writes.
    private let actionBridge: VideoCallActionBridge?
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
    /// Mirrors ``VideoCallViewController`` mute flags into SwiftUI overlay controls (`CallActionDelegate` → concrete VC casts are unreliable).
    @Binding var isVideoMuted: Bool
    @Binding var isAudioMuted: Bool
    /// Mirrors local screen sharing state from the hosted controller.
    @Binding var isScreenSharing: Bool
    /// `true` when any remote participant is actively screen-sharing.
    @Binding var hasActiveRemoteScreenShare: Bool
    private let initialLocalVideoMuted: Bool
    private let initialLocalAudioMuted: Bool
    private let conferenceRaisedHands: [String: Bool]
    private let conferenceRaisedHandBadgeTopClearance: CGFloat
    private let controlsView: AnyView?

    /// Creates a representable that hosts a `VideoCallViewController`.
    ///
    /// - Parameters:
    ///   - session: The `RTCSession` driving call state.
    ///   - delegate: A binding that will be set to the created controller (implements `CallActionDelegate`).
    ///   - errorMessage: Receives user-presentable error messages.
    ///   - endedCall: Set to `true` when the call ends.
    ///   - width: Receives view width updates (primarily used by macOS; kept for API parity).
    ///   - height: Receives view height updates (primarily used by macOS; kept for API parity).
    ///   - callState: Receives call state updates.
    ///   - isVideoMuted: Updated when the controller toggles camera mute.
    ///   - isAudioMuted: Updated when the controller toggles mic mute.
    ///   - isScreenSharing: Updated when the controller starts/stops local screen sharing.
    ///   - hasActiveRemoteScreenShare: Updated when a remote participant starts/stops screen sharing.
    ///   - actionBridge: Optional stable object that receives the controller reference (see ``VideoCallActionBridge``).
    ///   - controlsView: Optional SwiftUI controls view embedded into the controller.
    public init(
        session: RTCSession,
        actionBridge: VideoCallActionBridge? = nil,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        isVideoMuted: Binding<Bool>,
        isAudioMuted: Binding<Bool>,
        isScreenSharing: Binding<Bool> = .constant(false),
        hasActiveRemoteScreenShare: Binding<Bool> = .constant(false),
        conferenceRaisedHands: [String: Bool] = [:],
        conferenceRaisedHandBadgeTopClearance: CGFloat = 0,
        initialLocalVideoMuted: Bool = false,
        initialLocalAudioMuted: Bool = false,
        controlsView: AnyView? = nil
    ) {
        self.session = session
        self.actionBridge = actionBridge
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self._isVideoMuted = isVideoMuted
        self._isAudioMuted = isAudioMuted
        self._isScreenSharing = isScreenSharing
        self._hasActiveRemoteScreenShare = hasActiveRemoteScreenShare
        self.initialLocalVideoMuted = initialLocalVideoMuted
        self.initialLocalAudioMuted = initialLocalAudioMuted
        self.conferenceRaisedHands = conferenceRaisedHands
        self.conferenceRaisedHandBadgeTopClearance = conferenceRaisedHandBadgeTopClearance
        self.controlsView = controlsView
    }
    
    public init<Controls: View>(
        session: RTCSession,
        actionBridge: VideoCallActionBridge? = nil,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        isVideoMuted: Binding<Bool>,
        isAudioMuted: Binding<Bool>,
        isScreenSharing: Binding<Bool> = .constant(false),
        hasActiveRemoteScreenShare: Binding<Bool> = .constant(false),
        conferenceRaisedHands: [String: Bool] = [:],
        conferenceRaisedHandBadgeTopClearance: CGFloat = 0,
        initialLocalVideoMuted: Bool = false,
        initialLocalAudioMuted: Bool = false,
        @ViewBuilder controlsView: () -> Controls
    ) {
        self.init(
            session: session,
            actionBridge: actionBridge,
            delegate: delegate,
            errorMessage: errorMessage,
            endedCall: endedCall,
            width: width,
            height: height,
            callState: callState,
            isVideoMuted: isVideoMuted,
            isAudioMuted: isAudioMuted,
            isScreenSharing: isScreenSharing,
            hasActiveRemoteScreenShare: hasActiveRemoteScreenShare,
            conferenceRaisedHands: conferenceRaisedHands,
            conferenceRaisedHandBadgeTopClearance: conferenceRaisedHandBadgeTopClearance,
            initialLocalVideoMuted: initialLocalVideoMuted,
            initialLocalAudioMuted: initialLocalAudioMuted,
            controlsView: AnyView(controlsView())
        )
    }
    
    public func makeUIViewController(context: Context) -> VideoCallViewController {
        let vc = VideoCallViewController(session: session)
        if let actionBridge {
            actionBridge.viewController = vc
            delegate = actionBridge
        } else {
            delegate = vc
        }
        vc.videoCallDelegate = context.coordinator
        vc.applyInitialLocalMuteDisplayState(
            videoMuted: initialLocalVideoMuted,
            audioMuted: initialLocalAudioMuted
        )
        
        if let controlsView {
            let hosting = UIHostingController(rootView: controlsView)
            hosting.view.backgroundColor = .clear
            vc.addChild(hosting)
            vc.setControlsView(hosting.view)
            hosting.didMove(toParent: vc)
        }
        return vc
    }

    public func updateUIViewController(_ uiViewController: VideoCallViewController, context: Context) {
        // Coordinator is created once; without refreshing `parent`, its `@Binding` copies stay stale and
        // writes (e.g. `localMuteDisplayDidChange`) never reach the current `CallView` `@State`.
        context.coordinator.parent = self
        if let actionBridge {
            actionBridge.viewController = uiViewController
            delegate = actionBridge
        } else {
            delegate = uiViewController
        }
        uiViewController.videoCallDelegate = context.coordinator
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    /// Receives callbacks from `VideoCallViewController` and updates SwiftUI bindings.
    public final class Coordinator: NSObject, VideoCallDelegate {
        var parent: VideoCallViewControllerRepresentable
        
        init(_ parent: VideoCallViewControllerRepresentable) {
            self.parent = parent
        }
        
        public func passErrorMessage(_ message: String) async {
            DispatchQueue.main.async {
                self.parent.errorMessage = message
            }
        }
        public func deliverCallState(_ state: CallStateMachine.State) async {
            DispatchQueue.main.async {
                self.parent.callState = state
            }
        }
        public func endedCall(_ didEnd: Bool) async {
            DispatchQueue.main.async {
                self.parent.endedCall = didEnd
            }
        }

        public func localMuteDisplayDidChange(videoMuted: Bool, audioMuted: Bool) async {
            DispatchQueue.main.async {
                self.parent.isVideoMuted = videoMuted
                self.parent.isAudioMuted = audioMuted
            }
        }

        public func screenShareDidChange(isSharing: Bool) async {
            DispatchQueue.main.async {
                self.parent.isScreenSharing = isSharing
            }
        }

        public func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async {
            DispatchQueue.main.async {
                self.parent.hasActiveRemoteScreenShare = isSharing
            }
        }
    }
}

#elseif os(macOS)
import AppKit
import NeedleTailLogger

/// Forwards mute/end actions to the hosted ``VideoCallViewController`` (macOS).
@MainActor
public final class VideoCallActionBridge: CallActionDelegate, @unchecked Sendable {
    public weak var viewController: VideoCallViewController?

    public init() {}

    public func endCall() async {
        await viewController?.endCall()
    }

    public func muteAudio() async {
        await viewController?.muteAudio()
    }

    public func setAudioMuted(_ muted: Bool) async {
        await viewController?.setAudioMuted(muted)
    }

    public func muteVideo() async {
        await viewController?.muteVideo()
    }

    public func showPictureInPicture(_ show: Bool) async {
        await viewController?.showPictureInPicture(show)
    }

    public func startScreenShare(target: ScreenShareTarget) async {
        await viewController?.startScreenShare(target: target)
    }

    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        await viewController?.startScreenShare(target: target, options: options)
    }

    public func stopScreenShare() async {
        await viewController?.stopScreenShare()
    }

    public func setSpeakerOutputEnabled(_ enabled: Bool) {
        viewController?.setSpeakerOutputEnabled(enabled)
    }
}

@MainActor
/// SwiftUI wrapper around the platform `VideoCallViewController` (macOS).
///
/// This representable bridges the SDK’s AppKit call UI into SwiftUI and wires up:
/// - `CallActionDelegate` (user actions like end/mute)
/// - `VideoCallDelegate` (state/error callbacks, plus size updates on macOS)
/// - optional embedded controls via a SwiftUI `View`
public struct VideoCallViewControllerRepresentable: NSViewControllerRepresentable {

    private let session: RTCSession
    private let actionBridge: VideoCallActionBridge?
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
    @Binding var isVideoMuted: Bool
    @Binding var isAudioMuted: Bool
    @Binding var isScreenSharing: Bool
    @Binding var hasActiveRemoteScreenShare: Bool
    private let initialLocalVideoMuted: Bool
    private let initialLocalAudioMuted: Bool
    private let conferenceRaisedHands: [String: Bool]
    private let conferenceRaisedHandBadgeTopClearance: CGFloat
    private let controlsView: AnyView?

    /// Creates a representable that hosts a `VideoCallViewController`.
    ///
    /// - Parameters:
    ///   - session: The `RTCSession` driving call state.
    ///   - delegate: A binding that will be set to the created controller (implements `CallActionDelegate`).
    ///   - errorMessage: Receives user-presentable error messages.
    ///   - endedCall: Set to `true` when the call ends.
    ///   - width: Receives view width updates.
    ///   - height: Receives view height updates.
    ///   - callState: Receives call state updates.
    ///   - isVideoMuted: Updated when the controller toggles camera mute.
    ///   - isAudioMuted: Updated when the controller toggles mic mute.
    ///   - isScreenSharing: Updated when the controller starts/stops local screen sharing.
    ///   - hasActiveRemoteScreenShare: Updated when a remote participant starts/stops screen sharing.
    ///   - actionBridge: Optional stable object that receives the controller reference (see ``VideoCallActionBridge``).
    ///   - controlsView: Optional SwiftUI controls view embedded into the controller.
    public init(
        session: RTCSession,
        actionBridge: VideoCallActionBridge? = nil,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        isVideoMuted: Binding<Bool>,
        isAudioMuted: Binding<Bool>,
        isScreenSharing: Binding<Bool> = .constant(false),
        hasActiveRemoteScreenShare: Binding<Bool> = .constant(false),
        conferenceRaisedHands: [String: Bool] = [:],
        conferenceRaisedHandBadgeTopClearance: CGFloat = 0,
        initialLocalVideoMuted: Bool = false,
        initialLocalAudioMuted: Bool = false,
        controlsView: AnyView? = nil
    ) {
        self.session = session
        self.actionBridge = actionBridge
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self._isVideoMuted = isVideoMuted
        self._isAudioMuted = isAudioMuted
        self._isScreenSharing = isScreenSharing
        self._hasActiveRemoteScreenShare = hasActiveRemoteScreenShare
        self.initialLocalVideoMuted = initialLocalVideoMuted
        self.initialLocalAudioMuted = initialLocalAudioMuted
        self.conferenceRaisedHands = conferenceRaisedHands
        self.conferenceRaisedHandBadgeTopClearance = conferenceRaisedHandBadgeTopClearance
        self.controlsView = controlsView
    }
    
    public init<Controls: View>(
        session: RTCSession,
        actionBridge: VideoCallActionBridge? = nil,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        isVideoMuted: Binding<Bool>,
        isAudioMuted: Binding<Bool>,
        isScreenSharing: Binding<Bool> = .constant(false),
        hasActiveRemoteScreenShare: Binding<Bool> = .constant(false),
        conferenceRaisedHands: [String: Bool] = [:],
        conferenceRaisedHandBadgeTopClearance: CGFloat = 0,
        initialLocalVideoMuted: Bool = false,
        initialLocalAudioMuted: Bool = false,
        @ViewBuilder controlsView: () -> Controls
    ) {
        self.init(
            session: session,
            actionBridge: actionBridge,
            delegate: delegate,
            errorMessage: errorMessage,
            endedCall: endedCall,
            width: width,
            height: height,
            callState: callState,
            isVideoMuted: isVideoMuted,
            isAudioMuted: isAudioMuted,
            isScreenSharing: isScreenSharing,
            hasActiveRemoteScreenShare: hasActiveRemoteScreenShare,
            conferenceRaisedHands: conferenceRaisedHands,
            conferenceRaisedHandBadgeTopClearance: conferenceRaisedHandBadgeTopClearance,
            initialLocalVideoMuted: initialLocalVideoMuted,
            initialLocalAudioMuted: initialLocalAudioMuted,
            controlsView: AnyView(controlsView())
        )
    }
    public func makeNSViewController(context: Context) -> VideoCallViewController {
        let vc = VideoCallViewController(session: session)
        if let actionBridge {
            actionBridge.viewController = vc
            delegate = actionBridge
        } else {
            delegate = vc
        }
        vc.usesEmbeddedControls = true
        vc.videoCallDelegate = context.coordinator
        vc.applyInitialLocalMuteDisplayState(
            videoMuted: initialLocalVideoMuted,
            audioMuted: initialLocalAudioMuted
        )
        
        if let controlsView {
            let hosting = NSHostingController(rootView: controlsView)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            vc.addChild(hosting)
            vc.setControlsView(hosting.view)
        }
        return vc
    }

    public func updateNSViewController(_ nsViewController: VideoCallViewController, context: Context) {
        context.coordinator.parent = self
        if let actionBridge {
            actionBridge.viewController = nsViewController
            delegate = actionBridge
        } else {
            delegate = nsViewController
        }
        nsViewController.videoCallDelegate = context.coordinator
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    /// Receives callbacks from `VideoCallViewController` and updates SwiftUI bindings.
    public final class Coordinator: NSObject, VideoCallDelegate {
        private static let layoutProbeLog = NeedleTailLogger("[VideoCallLayoutProbe][Representable]")
        private static let isLayoutProbeEnabled: Bool = {
            #if DEBUG
            true
            #else
            ProcessInfo.processInfo.environment["PQSRTC_LAYOUT_PROBE"] == "1"
            #endif
        }()
        /// Throttles identical `passSize` lines (SDK sends fixed minima, not live window size).
        private var lastPassSizeSignature: String = ""

        var parent: VideoCallViewControllerRepresentable
        
        init(_ parent: VideoCallViewControllerRepresentable) {
            self.parent = parent
        }
        
        public func passErrorMessage(_ message: String) async {
            DispatchQueue.main.async {
                self.parent.errorMessage = message
            }
        }
        public func deliverCallState(_ state: CallStateMachine.State) async {
            DispatchQueue.main.async {
                self.parent.callState = state
            }
        }
        public func endedCall(_ didEnd: Bool) async {
            DispatchQueue.main.async {
                self.parent.endedCall = didEnd
            }
        }
        /// Receives size updates from the underlying AppKit controller.
        public func passSize(_ size: NSSize) async {
            let w = Int(size.width)
            let h = Int(size.height)
            let sig = "\(w)x\(h)"
            if sig != lastPassSizeSignature {
                lastPassSizeSignature = sig
                guard Self.isLayoutProbeEnabled else {
                    DispatchQueue.main.async {
                        self.parent.width = size.width
                        self.parent.height = size.height
                    }
                    return
                }
                Self.layoutProbeLog.log(
                    level: .debug,
                    message: "[VideoCallLayoutProbe] passSize binding update -> \(w)x\(h) note=hostVoIPUsesThisForMinFrameNotLiveWindowSizeUnlessSDKContractChanges"
                )
            }
            DispatchQueue.main.async {
                self.parent.width = size.width
                self.parent.height = size.height
            }
        }

        public func localMuteDisplayDidChange(videoMuted: Bool, audioMuted: Bool) async {
            DispatchQueue.main.async {
                self.parent.isVideoMuted = videoMuted
                self.parent.isAudioMuted = audioMuted
            }
        }

        public func screenShareDidChange(isSharing: Bool) async {
            DispatchQueue.main.async {
                self.parent.isScreenSharing = isSharing
            }
        }

        public func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async {
            DispatchQueue.main.async {
                self.parent.hasActiveRemoteScreenShare = isSharing
            }
        }
    }
}
#endif
