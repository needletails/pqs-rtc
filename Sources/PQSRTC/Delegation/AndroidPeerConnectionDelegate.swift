//
//  AndroidPeerConnectionDelegate.swift
//  pqs-rtc
//
//  Created by Cole M on 10/4/25.
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

import Foundation
import NeedleTailLogger

#if os(Android)

/* SKIP @bridge */
public final class AndroidPeerConnectionDelegate: @unchecked Sendable {
    
    private let lock: NSLock = NSLock()
    private let logger: NeedleTailLogger
    private let continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    private let connectionId: String
    private weak var rtcClient: AndroidRTCClient?
    private var isShutdown = false
    
    public init(
        connectionId: String,
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        self.connectionId = connectionId
        self.logger = logger
        self.continuation = continuation
    }
    
    public func setRTCClient(_ client: AndroidRTCClient) {
        self.rtcClient = client
    }
    
    func shutdown() async {
        lock.withLock { [weak self] in
            guard let self else { return }
            isShutdown = true
            rtcClient = nil
        }
    }
    
    /* SKIP @bridge */
    public func handleRTCEvent(_ event: ClientPCEvent) {
        logger.log(level: .debug, message: "Received Event \(event)")
        switch event {
        case .candidate(let candidate):
            handleIceCandidate(candidate)
        case .videoTrack(let videoTrack):
            handleRemoteVideoTrack(videoTrack)
        case .audioTrack(let audioTrack):
            handleRemoteAudioTrack(audioTrack)
        case .signalingStateChange(let stateDesc):
            handleSignalingStateChange(stateDesc)
        case .iceConnectionStateChange(let stateDesc):
            handleIceConnectionStateChange(stateDesc)
        case .standardizedIceConnectionStateChange(let stateDesc):
            handleStandardizedIceConnectionStateChange(stateDesc)
        case .peerConnectionStateChange(let stateDesc):
            handlePeerConnectionStateChange(stateDesc)
        case .iceConnectionReceivingChange(let receiving):
            handleIceConnectionReceivingChange(receiving)
        case .iceGatheringStateChange(let stateDesc):
            handleIceGatheringStateChange(stateDesc)
        case .iceCandidatesRemoved(let count):
            handleIceCandidatesRemoved(count)
        case .addStream(let streamId):
            handleAddStream(streamId)
        case .removeStream(let streamId):
            handleRemoveStream(streamId)
        case .dataChannel(let label):
            handleDataChannel(label)
        case .shouldNegotiate:
            handleShouldNegotiate()
        case .addTrack(let trackKind):
            handleAddTrack(trackKind)
        case .removeTrack(let trackKind):
            handleRemoveTrack(trackKind)
        }
    }
    
    // MARK: - Event Handlers
    
    private func handleIceCandidate(_ candidate: RTCIceCandidate) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            guard !connectionId.isEmpty else {
                logger.log(level: .warning, message: "Dropping ICE candidate event because connectionId is empty")
                return
            }
            continuation.yield(PeerConnectionNotifications.generatedIceCandidate(
                connectionId, 
                candidate.sdp,
                candidate.sdpMLineIndex,
                candidate.sdpMid
            ))
        }
    }
    
    private func handleRemoteVideoTrack(_ track: RTCVideoTrack) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Remote video track received from NeedleTailRTC")
            logger.log(level: .info, message: "Video track ID: \(track.trackId)")
            guard !connectionId.isEmpty else { return }
            // Mirror the Apple Unified Plan callback (`didAddReceiver`) so the session can
            // map this track to a participant and attach receiver cryptors.
            continuation.yield(PeerConnectionNotifications.didAddReceiver(connectionId, "video", [], track.trackId))
        }
    }
    
    private func handleRemoteAudioTrack(_ track: RTCAudioTrack) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Remote audio track received from NeedleTailRTC")
            guard !connectionId.isEmpty else { return }
            // Mirror the Apple Unified Plan callback (`didAddReceiver`) so the session can
            // map this track to a participant and attach receiver cryptors.
            continuation.yield(PeerConnectionNotifications.didAddReceiver(connectionId, "audio", [], track.trackId))
        }
    }
    
    private func handleSignalingStateChange(_ stateDesc: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            let state = SPTSignalingState(description: stateDesc)
            logger.log(level: .info, message: "Signaling state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.signalingStateDidChange(connectionId, state))
        }
    }
    
    private func handleIceConnectionStateChange(_ stateDesc: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            let state = SPTIceConnectionState(description: stateDesc)
            logger.log(level: .info, message: "ICE connection state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.iceConnectionStateDidChange(connectionId, state))
        }
    }
    
    private func handleStandardizedIceConnectionStateChange(_ stateDesc: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            let state = SPTIceConnectionState(description: stateDesc)
            logger.log(level: .info, message: "Standardized ICE connection state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.standardizedIceConnectionState(connectionId, state))
        }
    }
    
    private func handlePeerConnectionStateChange(_ stateDesc: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            let state = SPTPeerConnectionState(description: stateDesc)
            logger.log(level: .info, message: "Peer connection state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            // No dedicated notification for peer connection state on Apple side; log only
        }
    }
    
    private func handleIceConnectionReceivingChange(_ receiving: Bool) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "ICE connection receiving changed to: \(receiving)")
            guard !connectionId.isEmpty else { return }
            // Note: There's no direct mapping for ICE connection receiving in PeerConnectionNotifications
            // This could be logged or mapped to another appropriate notification
        }
    }
    
    private func handleIceGatheringStateChange(_ stateDesc: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            let state = SPTIceGatheringState(description: stateDesc)
            logger.log(level: .info, message: "ICE gathering state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.iceGatheringDidChange(connectionId, state))
        }
    }
    
    private func handleIceCandidatesRemoved(_ count: Int) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Removed \(count) ICE candidates")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.removedIceCandidates(connectionId, count))
        }
    }
    
    private func handleAddStream(_ streamId: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Stream added: \(streamId)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.addedStream(connectionId, streamId))
        }
    }
    
    private func handleRemoveStream(_ streamId: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Stream removed: \(streamId)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.removedStream(connectionId, streamId))
        }
    }
    
    private func handleDataChannel(_ label: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Data channel opened: \(label)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.dataChannel(connectionId, label))
        }
    }
    
    private func handleShouldNegotiate() {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "PeerConnection renegotiation needed")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.shouldNegotiate(connectionId))
        }
    }
    
    private func handleAddTrack(_ trackKind: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Track added: \(trackKind)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.startedReceiving(connectionId, trackKind))
        }
    }
    
    private func handleRemoveTrack(_ trackKind: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Track removed: \(trackKind)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.startedReceiving(connectionId, "removed_\(trackKind)"))
        }
    }
    
    // MARK: - Manual Event Triggers (for testing/debugging)
    
    func triggerSignalingStateChange(_ state: SPTSignalingState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Signaling state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.signalingStateDidChange(connectionId, state))
        }
    }
    
    func triggerIceConnectionStateChange(_ state: SPTIceConnectionState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "ICE connection state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.iceConnectionStateDidChange(connectionId, state))
        }
    }
    
    func triggerIceGatheringStateChange(_ state: SPTIceGatheringState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "ICE gathering state changed to: \(state.description)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.iceGatheringDidChange(connectionId, state))
        }
    }
    
    func triggerDataChannel(_ label: String) {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Data channel: \(label)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.dataChannel(connectionId, label))
        }
    }
    
    func triggerShouldNegotiate() {
        lock.withLock { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else { return }
            logger.log(level: .info, message: "Should negotiate for connection: \(connectionId)")
            guard !connectionId.isEmpty else { return }
            continuation.yield(PeerConnectionNotifications.shouldNegotiate(connectionId))
        }
    }
}

#endif
