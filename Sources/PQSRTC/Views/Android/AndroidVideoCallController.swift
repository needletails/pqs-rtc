//  AndroidVideoCallController.swift
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

#if os(Android)
import Foundation
import NeedleTailLogger

/// Android-side call controller that coordinates `RTCSession` state with UI views.
///
/// This actor listens to the session's call state stream and:
/// - Notifies a `VideoCallDelegate` about state changes and errors.
/// - Attaches/detaches local and remote video renderers.
/// - Exposes user actions (end call, mute audio/video) via `CallActionDelegate`.
///
/// Threading: As an actor, it serializes call-related operations and UI wiring.
public actor AndroidVideoCallController: CallActionDelegate {
    /// Delegate that receives state updates and UI-facing events.
    public weak var videoCallDelegate: VideoCallDelegate?
    
    private unowned let session: RTCSession
    private var currentCall: Call?
    private var currentCallState: CallStateMachine.State = .waiting
    private var _currentCallState: CallStateMachine.State {
        get async {
            currentCallState
        }
    }
    private let logger = NeedleTailLogger()
    private var isRunning = true
    private var didUpgradeDowngrade = false
    private var upgradedToVideo = false
    private var isMutingAudio = false
    private var isMutingVideo = false
    
    private var localView: AndroidPreviewCaptureView?
    private var remoteView: AndroidSampleCaptureView?
    private var remoteViews: [AndroidSampleCaptureView] = []
    
    private var stateStreamTask: Task<Void, Never>?
    
    /// Creates a controller bound to a specific `RTCSession`.
    ///
    /// - Parameter session: The session that owns call state and media operations.
    public init(session: RTCSession) {
        self.session = session
    }
    
    /// Sets the remote capture views that should render inbound video.
    ///
    /// The controller will render to all provided views when connected in a video call.
    public func setRemoteViews(remotes: [AndroidSampleCaptureView]) async {
        self.remoteViews = remotes
        self.remoteView = remotes.first
        logger.log(level: .debug, message: "SET REMOTE VIEWS \(remotes)")
    }
    
    /// Sets the local preview capture view used for outbound video.
    public func setLocalView(local: AndroidPreviewCaptureView) async {
        self.localView = local
    }
    
    /// Sets (or clears) the delegate that receives UI-facing call events.
    public func setVideoCallDelegate(_ conformer: VideoCallDelegate?) async {
        self.videoCallDelegate = conformer
    }
    
    /// Starts consuming the session's call state stream.
    ///
    /// If already started, this method is a no-op.
    public func start() async {
        guard stateStreamTask == nil else {
            logger.log(level: .warning, message: "AndroidVideoCallController.start() called while already running; ignoring")
            return
        }
        stateStreamTask = Task { [weak self] in
            guard let self else { return }
            let lastStream = await session.callState.currentCallStream.last
            guard let stateStream = lastStream else { return }
            for await state in stateStream {
                let currentState = await self._currentCallState
                guard state != currentState else { continue }
                await setCurrentCallState(state)
                await videoCallDelegate?.deliverCallState(state)
                switch state {
                case .waiting:
                    break
                case .ready:
                    break
                case .connecting(let direction, let call):
                    await setCurrentCall(call)
                    switch direction {
                    case .inbound(let type), .outbound(let type):
                        switch type {
                        case .voice:
                            break
                        case .video:
                            await upgradedVideo(true)
                            await self.createPreviewView()
                        }
                    }
                case .connected(let direction, let call):
                    await setCurrentCall(call)
                    
                    switch direction {
                    case .inbound(let type), .outbound(let type):
                        switch type {
                        case .voice:
                            break
                        case .video:
                            await self.createSampleView()
                        }
                    }
                case .held:
                    break
                case .ended:
                    await tearDownCall()
                case .failed(_, _, let errorMessage):
                    await videoCallDelegate?.passErrorMessage(errorMessage)
                    await tearDownCall()
                case .callAnsweredAuxDevice:
                    await tearDownCall()
                }
            }
        }
    }
    
    private func setCurrentCall(_ call: Call) async {
        currentCall = call
    }
    
    private func setCurrentCallState(_ state: CallStateMachine.State) async {
        currentCallState = state
    }
    
    private func upgradedVideo(_ shouldUpgrade: Bool) async {
        self.upgradedToVideo = shouldUpgrade
    }
    
    public func stop() async {
        await tearDownCall()
    }
    
    // MARK: - Actions
    /// Ends the active call, notifies the transport (if available), and tears down session resources.
    ///
    /// This performs the full shutdown path (`RTCSession.shutdown(with:)`) to ensure peer connections,
    /// crypto state, and key material are cleared.
    public func endCall() async {
        guard let call = self.currentCall else {
            await tearDownCall()
            await videoCallDelegate?.endedCall(true)
            return
        }
        
        // Notify transport that the user ended the call
        if let transport = try? await session.requireTransport() {
            try? await transport.didEnd(call: call, endState: CallStateMachine.EndState.userInitiated)
        }
        
        // Fully tear down the RTC session (peer connections, crypto, keys, etc.)
        await session.shutdown(with: call)
        
        // Finally clean up local UI/stream state
        await tearDownCall()
        await videoCallDelegate?.endedCall(true)
    }
    
    public func muteAudio() async {
        isMutingAudio.toggle()
        guard let callId = self.currentCall?.sharedCommunicationId else { return }
        do {
            try await self.session.setAudioTrack(isEnabled: !self.isMutingAudio, connectionId: callId)
        } catch {
            // swallow in release; delegate already receives failures
        }
        if await self.session.callState.callType == .video {
            await self.muteVideo()
        }
    }
    
    /// Toggles the local video track enabled state for the active call.
    public func muteVideo() async {
        isMutingVideo.toggle()
        guard let callId = self.currentCall?.sharedCommunicationId else { return }
        await self.session.setVideoTrack(isEnabled: !self.isMutingVideo, connectionId: callId)
    }
    
    // MARK: - View Management
    private func createPreviewView(shouldQuery: Bool = true) async {
        guard let connectionId = currentCall?.sharedCommunicationId, let localView else { return }
        await session.renderLocalVideo(to: localView, connectionId: connectionId)
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    private func createSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        logger.log(level: .debug, message: "CREATE SAMPLE VIEW \(remoteViews)")
        if !remoteViews.isEmpty {
            for view in remoteViews {
                await session.renderRemoteVideo(to: view, connectionId: connectionId)
            }
        } else if let remoteView {
            await session.renderRemoteVideo(to: remoteView, connectionId: connectionId)
        } else {
            logger.log(level: .debug, message: "Missing remote views for rendering sample")
        }
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    private func tearDownPreviewView() async {
        guard let connectionId = currentCall?.sharedCommunicationId, let localView else { return }
        await session.removeLocal(view: localView, connectionId: connectionId)
    }
    
    private func tearDownSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if !remoteViews.isEmpty {
            for view in remoteViews {
                await session.removeRemote(view: view, connectionId: connectionId)
            }
        } else if let remoteView {
            await session.removeRemote(view: remoteView, connectionId: connectionId)
        }
    }

    // MARK: - Teardown
    private func tearDownCall() async {
        guard isRunning else { return }
        // Prevent concurrent teardown from running more than once
        isRunning = false

        // Guarantee the underlying RTCSession is returned to a pre-call baseline
        // even when teardown is triggered by remote end/failure (not user-initiated endCall()).
        if let call = self.currentCall {
            await session.shutdown(with: call)
        }
        await tearDownPreviewView()
        await tearDownSampleView()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        currentCall = nil
    }
}
#endif
