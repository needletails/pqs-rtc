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

@MainActor
/// SwiftUI wrapper around the platform `VideoCallViewController` (iOS).
///
/// This representable bridges the SDK’s UIKit call UI into SwiftUI and wires up:
/// - `CallActionDelegate` (user actions like end/mute)
/// - `VideoCallDelegate` (state/error callbacks)
/// - optional embedded controls via a SwiftUI `View`
public struct VideoCallViewControllerRepresentable: UIViewControllerRepresentable {
    
    private let session: RTCSession
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
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
    ///   - controlsView: Optional SwiftUI controls view embedded into the controller.
    public init(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        controlsView: AnyView? = nil
    ) {
        self.session = session
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self.controlsView = controlsView
    }
    
    public init<Controls: View>(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        @ViewBuilder controlsView: () -> Controls
    ) {
        self.init(
            session: session,
            delegate: delegate,
            errorMessage: errorMessage,
            endedCall: endedCall,
            width: width,
            height: height,
            callState: callState,
            controlsView: AnyView(controlsView())
        )
    }
    
    public func makeUIViewController(context: Context) -> VideoCallViewController {
        let vc = VideoCallViewController(session: session)
        delegate = vc
        vc.videoCallDelegate = context.coordinator
        
        if let controlsView {
            let hosting = UIHostingController(rootView: controlsView)
            hosting.view.backgroundColor = .clear
            vc.addChild(hosting)
            vc.setControlsView(hosting.view)
            hosting.didMove(toParent: vc)
        }
        return vc
    }

    public func updateUIViewController(_ uiViewController: VideoCallViewController, context: Context) {}

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
            self.parent.errorMessage = message
        }
        public func deliverCallState(_ state: CallStateMachine.State) async {
            self.parent.callState = state
        }
        public func endedCall(_ didEnd: Bool) async {
            self.parent.endedCall = didEnd
        }
    }
}

#elseif os(macOS)
import AppKit

@MainActor
/// SwiftUI wrapper around the platform `VideoCallViewController` (macOS).
///
/// This representable bridges the SDK’s AppKit call UI into SwiftUI and wires up:
/// - `CallActionDelegate` (user actions like end/mute)
/// - `VideoCallDelegate` (state/error callbacks, plus size updates on macOS)
/// - optional embedded controls via a SwiftUI `View`
public struct VideoCallViewControllerRepresentable: NSViewControllerRepresentable {

    private let session: RTCSession
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State
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
    ///   - controlsView: Optional SwiftUI controls view embedded into the controller.
    public init(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        controlsView: AnyView? = nil
    ) {
        self.session = session
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
        self.controlsView = controlsView
    }
    
    public init<Controls: View>(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>,
        @ViewBuilder controlsView: () -> Controls
    ) {
        self.init(
            session: session,
            delegate: delegate,
            errorMessage: errorMessage,
            endedCall: endedCall,
            width: width,
            height: height,
            callState: callState,
            controlsView: AnyView(controlsView())
        )
    }
    public func makeNSViewController(context: Context) -> VideoCallViewController {
        let vc = VideoCallViewController(session: session)
        delegate = vc
        vc.videoCallDelegate = context.coordinator
        
        if let controlsView {
            let hosting = NSHostingController(rootView: controlsView)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            vc.addChild(hosting)
            vc.setControlsView(hosting.view)
        }
        return vc
    }

    public func updateNSViewController(_ nsViewController: VideoCallViewController, context: Context) {}

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
            self.parent.errorMessage = message
        }
        public func deliverCallState(_ state: CallStateMachine.State) async {
            self.parent.callState = state
        }
        public func endedCall(_ didEnd: Bool) async {
            self.parent.endedCall = didEnd
        }
        /// Receives size updates from the underlying AppKit controller.
        public func passSize(_ size: NSSize) async {
            self.parent.width = size.width
            self.parent.height = size.height
        }
    }
}
#endif


