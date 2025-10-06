//
//  VideoCallViewControllerRepresentable.swift
//
//  Created by AI Assistant on 10/5/25.
//
//  SwiftUI wrappers for platform VideoCallViewController implementations.
//

#if !os(Android)
import Foundation
import SwiftUI
#endif

#if os(iOS)
import UIKit

@MainActor
public struct VideoCallViewControllerRepresentable: UIViewControllerRepresentable {
    
    private let session: RTCSession
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var videoUpgraded: Bool
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State

    public init(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        videoUpgraded: Binding<Bool>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>
    ) {
        self.session = session
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._videoUpgraded = videoUpgraded
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
    }
    
    public func makeUIViewController(context: Context) -> VideoCallViewController {
        let vc = VideoCallViewController(session: session)
        delegate = vc
        vc.videoCallDelegate = context.coordinator
        return vc
    }

    public func updateUIViewController(_ uiViewController: VideoCallViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    public final class Coordinator: NSObject, VideoCallDelegate {
        var parent: VideoCallViewControllerRepresentable
        
        init(_ parent: VideoCallViewControllerRepresentable) {
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

#elseif os(macOS)
import AppKit

@MainActor
public struct VideoCallViewControllerRepresentable: NSViewControllerRepresentable {

    private let session: RTCSession
    @Binding var delegate: CallActionDelegate?
    @Binding var errorMessage: String
    @Binding var videoUpgraded: Bool
    @Binding var endedCall: Bool
    @Binding var width: CGFloat
    @Binding var height: CGFloat
    @Binding var callState: CallStateMachine.State

    public init(
        session: RTCSession,
        delegate: Binding<CallActionDelegate?>,
        errorMessage: Binding<String>,
        videoUpgraded: Binding<Bool>,
        endedCall: Binding<Bool>,
        width: Binding<CGFloat>,
        height: Binding<CGFloat>,
        callState: Binding<CallStateMachine.State>
    ) {
        self.session = session
        self._delegate = delegate
        self._errorMessage = errorMessage
        self._videoUpgraded = videoUpgraded
        self._endedCall = endedCall
        self._width = width
        self._height = height
        self._callState = callState
    }
    public func makeNSViewController(context: Context) -> VideoCallViewController {
        let vc = VideoCallViewController(session: session)
        delegate = vc
        vc.videoCallDelegate = context.coordinator
        return vc
    }

    public func updateNSViewController(_ nsViewController: VideoCallViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    public final class Coordinator: NSObject, VideoCallDelegate {
        var parent: VideoCallViewControllerRepresentable
        
        init(_ parent: VideoCallViewControllerRepresentable) {
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
        public func passSize(_ size: NSSize) async {
            self.parent.width = size.width
            self.parent.height = size.height
        }
    }
}
#endif


