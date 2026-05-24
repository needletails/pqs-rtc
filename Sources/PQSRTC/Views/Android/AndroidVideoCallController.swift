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
/// - Dynamically assigns per-participant tracks to views for group/conference calls.
/// - Exposes user actions (end call, mute audio/video) via `CallActionDelegate`.
public actor AndroidVideoCallController: CallActionDelegate {
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
    private var screenTrackStreamTask: Task<Void, Never>?
    private var participantTrackStreamTask: Task<Void, Never>?
    private var screenView: AndroidSampleCaptureView?
    private(set) var hasActiveRemoteScreenShare = false
    private var activeRemoteScreenShareParticipantId: String?

    /// Tracks which participant is currently rendered by which view.
    private var participantViewAssignments: [String: AndroidSampleCaptureView] = [:]
    /// Pool of views not yet assigned to any participant.
    private var unassignedViews: [AndroidSampleCaptureView] = []
    /// Whether this is a group/conference call (multiple remote participants).
    private var isGroupCall: Bool {
        guard let currentCall else { return false }
        return currentCall.sharedCommunicationId.isGroupCall && !isEphemeralOneToOneSfuRoom(currentCall)
    }

    /// 1:1 calls relayed through the SFU use a transient `#<uuid>` room. They still have a single
    /// remote party, so Android should use the 1:1 renderer path rather than the group grid mapper.
    private func isEphemeralOneToOneSfuRoom(_ call: Call) -> Bool {
        guard call.recipients.count <= 1 else { return false }
        let route = (call.channelWireId ?? call.sharedCommunicationId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard route.hasPrefix("#") else { return false }
        return UUID(uuidString: route.normalizedConnectionId) != nil
    }

    public init(session: RTCSession) {
        self.session = session
    }
    
    /// Sets the remote capture views that should render inbound video.
    public func setRemoteViews(remotes: [AndroidSampleCaptureView]) async {
        self.remoteViews = remotes
        self.remoteView = remotes.first
        self.unassignedViews = remotes
        self.participantViewAssignments.removeAll()
        logger.log(level: .debug, message: "SET REMOTE VIEWS count=\(remotes.count)")
        await syncWithCurrentState(reason: "setRemoteViews")
    }
    
    /// Sets the local preview capture view used for outbound video.
    public func setLocalView(local: AndroidPreviewCaptureView) async {
        self.localView = local
        logger.log(level: .debug, message: "SET LOCAL VIEW")
        await syncWithCurrentState(reason: "setLocalView")
    }

    /// Installs all renderer views before syncing call state.
    ///
    /// Android `CallView` can appear while the session is already in `connecting`. Syncing after
    /// only the remote view is set causes the local preview bootstrap to run without a local view.
    public func setVideoViews(local: AndroidPreviewCaptureView, remotes: [AndroidSampleCaptureView]) async {
        self.localView = local
        self.remoteViews = remotes
        self.remoteView = remotes.first
        self.unassignedViews = remotes
        self.participantViewAssignments.removeAll()
        logger.log(level: .info, message: "AndroidVideoCallController installed video views local=true remoteCount=\(remotes.count)")
        await syncWithCurrentState(reason: "setVideoViews")
    }
    
    public func setVideoCallDelegate(_ conformer: VideoCallDelegate?) async {
        self.videoCallDelegate = conformer
    }
    
    /// Starts consuming the session's call state and participant track streams.
    public func start() async {
        guard stateStreamTask == nil else {
            logger.log(level: .warning, message: "AndroidVideoCallController.start() called while already running; ignoring")
            await syncWithCurrentState(reason: "start-already-running")
            return
        }
        isRunning = true
        logger.log(level: .info, message: "AndroidVideoCallController starting")
        startRemoteScreenTrackObservation()
        startParticipantTrackObservation()
        stateStreamTask = Task { [weak self] in
            guard let self else { return }

            var stateStream: AsyncStream<CallStateMachine.State>?
            while !Task.isCancelled {
                if let stream = await self.session.callState._currentCallStream.last {
                    stateStream = stream
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let stateStream else {
                logger.log(level: .error, message: "No call state stream available; cannot observe call state")
                return
            }

            let bootstrapState = await self._currentCallState
            if let current = await self.session.callState.currentState,
               current != bootstrapState {
                logger.log(level: .info, message: "AndroidVideoCallController bootstrapping state: \(current)")
                await self.handleObservedState(current)
            }

            for await state in stateStream {
                let currentState = await self._currentCallState
                guard state != currentState else { continue }
                logger.log(level: .info, message: "AndroidVideoCallController observed state: \(state)")
                await self.handleObservedState(state)
            }
        }
    }

    private func syncWithCurrentState(reason: String) async {
        guard let state = await session.callState.currentState else {
            logger.log(level: .debug, message: "AndroidVideoCallController sync skipped (\(reason)): no current state")
            return
        }
        logger.log(level: .info, message: "AndroidVideoCallController syncing with state (\(reason)): \(state)")
        await handleObservedState(state)
    }

    private func handleObservedState(_ state: CallStateMachine.State) async {
        logger.log(level: .info, message: "AndroidVideoCallController handling state: \(state)")
        await setCurrentCallState(state)
        await videoCallDelegate?.deliverCallState(state)

        switch state {
        case .waiting:
            break
        case .ready(let call):
            await setCurrentCall(call)
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
                    await self.createPreviewView()
                    await self.createSampleView()
                }
            }
        case .held:
            break
        case .ended:
            markCallEndedLocally()
        case .failed(_, _, let errorMessage):
            await videoCallDelegate?.passErrorMessage(errorMessage)
            markCallEndedLocally()
        case .callAnsweredAuxDevice:
            markCallEndedLocally()
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
        markCallEndedLocally()
    }
    
    // MARK: - Actions

    public func endCall() async {
        let call = self.currentCall
        let session = self.session

        // Dismiss call UI before any WebRTC/camera work. Android renderer and camera
        // teardown can block long enough to trip input ANRs when awaited from UI actions.
        markCallEndedLocally()
        await videoCallDelegate?.endedCall(true)

        Task.detached(priority: .userInitiated) {
            guard let call else {
                await session.shutdown(with: nil)
                return
            }

            do {
                let transport = try await session.requireTransport()
                try await transport.didEnd(call: call, endState: CallStateMachine.EndState.userInitiated)
            } catch {
                // Continue with local shutdown even if the transport is already gone.
            }
            await session.shutdown(with: call)
        }
    }
    
    public func muteAudio() async {
        await setAudioMuted(!isMutingAudio)
    }

    public func setAudioMuted(_ muted: Bool) async {
        guard let callId = self.currentCall?.sharedCommunicationId else { return }
        do {
            try await self.session.setAudioTrack(isEnabled: !muted, connectionId: callId)
            isMutingAudio = muted
        } catch {}
    }
    
    public func muteVideo() async {
        isMutingVideo.toggle()
        guard let callId = self.currentCall?.sharedCommunicationId else { return }
        await self.session.setVideoTrack(isEnabled: !self.isMutingVideo, connectionId: callId)
    }
    
    // MARK: - Screen Share Actions

    public func startScreenShare(target: ScreenShareTarget) async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        do {
            try await session.addScreenTrackToStream(target: target, connectionId: connectionId)
            await videoCallDelegate?.screenShareDidChange(isSharing: true)
        } catch {
            logger.log(level: .error, message: "Failed to start screen share: \(error)")
        }
    }

    public func stopScreenShare() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.removeScreenTrackFromStream(connectionId: connectionId)
        await videoCallDelegate?.screenShareDidChange(isSharing: false)
    }

    // MARK: - Remote Screen Track Observation

    private func startRemoteScreenTrackObservation() {
        guard screenTrackStreamTask == nil else { return }
        screenTrackStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.remoteScreenTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.handleRemoteScreenTrackEvent(event)
            }
        }
    }

    private func stopRemoteScreenTrackObservation() {
        screenTrackStreamTask?.cancel()
        screenTrackStreamTask = nil
    }

    private func handleRemoteScreenTrackEvent(_ event: RemoteScreenTrackEvent) async {
        if event.isActive {
            logger.log(level: .info, message: "Remote screen share started from participant=\(event.participantId)")
            if let view = screenView,
               let previousParticipantId = activeRemoteScreenShareParticipantId,
               previousParticipantId != event.participantId {
                await session.removeRemoteScreenVideoRenderer(
                    view,
                    connectionId: event.connectionId,
                    participantId: previousParticipantId
                )
            }
            activeRemoteScreenShareParticipantId = event.participantId
            hasActiveRemoteScreenShare = true
            if let view = screenView {
                await session.renderRemoteScreenVideo(
                    to: view,
                    connectionId: event.connectionId,
                    participantId: event.participantId
                )
            }
            await videoCallDelegate?.remoteScreenShareDidChange(participantId: event.participantId, isSharing: true)
        } else {
            logger.log(level: .info, message: "Remote screen share ended from participant=\(event.participantId)")
            let endedActiveShare = activeRemoteScreenShareParticipantId == nil
                || activeRemoteScreenShareParticipantId == event.participantId
            guard endedActiveShare else {
                logger.log(
                    level: .debug,
                    message: "Ignoring remote screen-share removal for inactive participant=\(event.participantId); activeParticipant=\(activeRemoteScreenShareParticipantId ?? "nil")"
                )
                return
            }
            if let view = screenView {
                await session.removeRemoteScreenVideoRenderer(view, connectionId: event.connectionId, participantId: event.participantId)
                screenView = nil
            }
            activeRemoteScreenShareParticipantId = nil
            hasActiveRemoteScreenShare = false
            await videoCallDelegate?.remoteScreenShareDidChange(participantId: event.participantId, isSharing: false)
        }
    }

    // MARK: - Remote Participant Track Observation (Group Calls)

    private func startParticipantTrackObservation() {
        guard participantTrackStreamTask == nil else { return }
        participantTrackStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.remoteParticipantTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.handleParticipantTrackEvent(event)
            }
        }
    }

    private func stopParticipantTrackObservation() {
        participantTrackStreamTask?.cancel()
        participantTrackStreamTask = nil
    }

    private func handleParticipantTrackEvent(_ event: RemoteParticipantTrackEvent) async {
        guard event.kind == "video" else { return }
        let connectionId = currentCall?.sharedCommunicationId ?? event.connectionId

        if event.isActive {
            logger.log(level: .info, message: "Participant track added: participant=\(event.participantId)")
            if let assignedView = participantViewAssignments[event.participantId] {
                await session.renderRemoteVideoForParticipant(
                    to: assignedView,
                    connectionId: connectionId,
                    participantId: event.participantId)
                logger.log(level: .info, message: "Reattached view to refreshed track for participant=\(event.participantId)")
                return
            }
            guard !unassignedViews.isEmpty else {
                logger.log(level: .warning, message: "No unassigned views for new participant=\(event.participantId)")
                return
            }
            let view = unassignedViews.removeFirst()
            participantViewAssignments[event.participantId] = view
            await session.renderRemoteVideoForParticipant(to: view, connectionId: connectionId, participantId: event.participantId)
            logger.log(level: .info, message: "Assigned view to participant=\(event.participantId), remaining unassigned=\(unassignedViews.count)")
        } else {
            logger.log(level: .info, message: "Participant track removed: participant=\(event.participantId)")
            let eventKey = RTCSession.conferenceParticipantIdentityKey(event.participantId)
            let assignmentKey = participantViewAssignments.keys.first { participantId in
                participantId == event.participantId
                    || (!eventKey.isEmpty && RTCSession.conferenceParticipantIdentityKey(participantId) == eventKey)
            }
            if let assignmentKey,
               let view = participantViewAssignments.removeValue(forKey: assignmentKey) {
                await session.removeRemoteForParticipant(view: view, connectionId: connectionId, participantId: event.participantId)
                unassignedViews.append(view)
                // A previously unassigned participant track may already exist in the connection map.
                // Re-scan and attach immediately when a slot frees up.
                await assignExistingParticipantTracks(connectionId: connectionId)
            }
        }
    }

    /// Sets the view used to render a remote screen share and attaches it to the active screen track.
    public func setScreenView(_ view: AndroidSampleCaptureView) async {
        screenView = view
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.renderRemoteScreenVideo(
            to: view,
            connectionId: connectionId,
            participantId: activeRemoteScreenShareParticipantId ?? connectionId
        )
    }

    // MARK: - View Management

    private func createPreviewView(shouldQuery: Bool = true) async {
        guard let connectionId = currentCall?.sharedCommunicationId else {
            logger.log(level: .debug, message: "createPreviewView skipped: missing currentCall")
            return
        }
        guard let localView else {
            logger.log(level: .debug, message: "createPreviewView skipped: missing localView")
            return
        }
        logger.log(level: .info, message: "AndroidVideoCallController creating preview for connection: \(connectionId)")
        await session.renderLocalVideo(to: localView, connectionId: connectionId)
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    private func createSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else {
            logger.log(level: .debug, message: "createSampleView skipped: missing currentCall")
            return
        }
        logger.log(level: .info, message: "AndroidVideoCallController creating sample view for connection: \(connectionId)")

        if isGroupCall {
            // For group calls, the participant track stream handles dynamic assignment.
            // Try to assign any already-arrived tracks to views now.
            await assignExistingParticipantTracks(connectionId: connectionId)
        } else {
            // 1:1 call: use the single-track path.
            if let remoteView {
                await session.renderRemoteVideo(to: remoteView, connectionId: connectionId)
            } else if !remoteViews.isEmpty {
                await session.renderRemoteVideo(to: remoteViews[0], connectionId: connectionId)
            } else {
                logger.log(level: .debug, message: "Missing remote views for rendering sample")
            }
        }
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }

    /// Assigns views to participants whose tracks arrived before the UI was ready.
    private func assignExistingParticipantTracks(connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await session.connectionManager.findConnection(with: normalizedId) else { return }

        for (participantId, _) in connection.remoteVideoTracksByParticipantId {
            guard participantViewAssignments[participantId] == nil else { continue }
            guard !unassignedViews.isEmpty else { break }
            let view = unassignedViews.removeFirst()
            participantViewAssignments[participantId] = view
            await session.renderRemoteVideoForParticipant(to: view, connectionId: connectionId, participantId: participantId)
            logger.log(level: .info, message: "Late-assigned view to participant=\(participantId)")
        }
    }

    private func tearDownPreviewView() async {
        guard let connectionId = currentCall?.sharedCommunicationId, let localView else { return }
        await session.removeLocal(view: localView, connectionId: connectionId)
    }
    
    private func tearDownSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }

        if isGroupCall {
            for (participantId, view) in participantViewAssignments {
                await session.removeRemoteForParticipant(view: view, connectionId: connectionId, participantId: participantId)
            }
            participantViewAssignments.removeAll()
            unassignedViews.removeAll()
        } else {
            if let remoteView {
                await session.removeRemote(view: remoteView, connectionId: connectionId)
            } else if !remoteViews.isEmpty {
                await session.removeRemote(view: remoteViews[0], connectionId: connectionId)
            }
        }
    }

    // MARK: - Teardown

    private func markCallEndedLocally() {
        guard isRunning else { return }
        isRunning = false
        stopRemoteScreenTrackObservation()
        stopParticipantTrackObservation()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        screenView = nil
        activeRemoteScreenShareParticipantId = nil
        hasActiveRemoteScreenShare = false
        currentCall = nil
    }

    private func tearDownCall() async {
        guard isRunning else { return }
        isRunning = false

        await tearDownPreviewView()
        await tearDownSampleView()
        stopRemoteScreenTrackObservation()
        stopParticipantTrackObservation()
        if let view = screenView, let connectionId = currentCall?.sharedCommunicationId {
            await session.removeRemoteScreenVideoRenderer(
                view,
                connectionId: connectionId,
                participantId: activeRemoteScreenShareParticipantId ?? connectionId
            )
        }
        screenView = nil
        activeRemoteScreenShareParticipantId = nil
        hasActiveRemoteScreenShare = false
        stateStreamTask?.cancel()
        stateStreamTask = nil
        currentCall = nil
    }
}
#endif
