//
//  AndroidPeerConnectionDelegate.swift
//  needle-tail-rtc
//
//  Created by Cole M on 10/4/25.
//
import Foundation
import NeedleTailLogger

#if os(Android)

public final class AndroidPeerConnectionDelegate: @unchecked Sendable {
    
    private let lock: NSLock = NSLock()
    public var connectionId: String = ""
    private let logger: NeedleTailLogger
    private let continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    internal var notifications: (@Sendable (PeerConnectionNotifications?) -> Void)?
    
    // NeedleTailRTC integration
    private var observationTask: Task<Void, Never>?
    private var lastIceCandidate: RTCIceCandidate?
    private var lastRemoteVideoTrack: RTCVideoTrack?
    private var lastRemoteAudioTrack: RTCAudioTrack?
    
    public init(
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        self.logger = logger
        self.continuation = continuation
        startObservingNeedleTailRTCEvents()
    }
    
    deinit {
        observationTask?.cancel()
    }
    
    // MARK: - NeedleTailRTC Event Observation
    
    private func startObservingNeedleTailRTCEvents() {
        observationTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled {
                await self.checkForNeedleTailRTCEvents()
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms polling
            }
        }
    }
    
    @MainActor
    private func checkForNeedleTailRTCEvents() {
        let observable = RTCSession.rtcClient.observable
        
        // Check for new ICE candidate
        if let newCandidate = observable.lastIceCandidate, newCandidate != lastIceCandidate {
            lastIceCandidate = newCandidate
            handleIceCandidate(newCandidate)
        }
        
        // Check for new remote video track
        if let newVideoTrack = observable.remoteVideoTrack, newVideoTrack != lastRemoteVideoTrack {
            lastRemoteVideoTrack = newVideoTrack
            handleRemoteVideoTrack(newVideoTrack)
        }
        
        // Check for new remote audio track
        if let newAudioTrack = observable.remoteAudioTrack, newAudioTrack !== lastRemoteAudioTrack {
            lastRemoteAudioTrack = newAudioTrack
            handleRemoteAudioTrack(newAudioTrack)
        }
    }
    
    // MARK: - Event Handlers
    
    private func handleIceCandidate(_ candidate: RTCIceCandidate) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "ICE candidate received from NeedleTailRTC")
        do {
            guard !connectionId.isEmpty else { return }
            
            let iceCandidate = try IceCandidate(from: candidate, id: 0)
            
            notifications?(PeerConnectionNotifications.generatedIceCandidate(
                connectionId, 
                iceCandidate.sdp,
                iceCandidate.sdpMLineIndex,
                iceCandidate.sdpMid
            ))
            continuation.yield(PeerConnectionNotifications.generatedIceCandidate(
                connectionId, 
                iceCandidate.sdp,
                iceCandidate.sdpMLineIndex,
                iceCandidate.sdpMid
            ))
        } catch {}
    }
    
    private func handleRemoteVideoTrack(_ track: RTCVideoTrack) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Remote video track received from NeedleTailRTC")
        guard !connectionId.isEmpty else { return }
        
        // Notify about remote video track availability
        notifications?(PeerConnectionNotifications.addedStream(connectionId, "video"))
        continuation.yield(PeerConnectionNotifications.addedStream(connectionId, "video"))
    }
    
    private func handleRemoteAudioTrack(_ track: RTCAudioTrack) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Remote audio track received from NeedleTailRTC")
        guard !connectionId.isEmpty else { return }
        
        // Notify about remote audio track availability
        notifications?(PeerConnectionNotifications.addedStream(connectionId, "audio"))
        continuation.yield(PeerConnectionNotifications.addedStream(connectionId, "audio"))
    }
    
    // MARK: - Manual Event Triggers (for testing/debugging)
    
    func triggerSignalingStateChange(_ state: SPTSignalingState) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Signaling state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(PeerConnectionNotifications.signalingStateDidChange(connectionId, state))
        continuation.yield(PeerConnectionNotifications.signalingStateDidChange(connectionId, state))
    }
    
    func triggerIceConnectionStateChange(_ state: SPTIceConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "ICE connection state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(PeerConnectionNotifications.iceConnectionStateDidChange(connectionId, state))
        continuation.yield(PeerConnectionNotifications.iceConnectionStateDidChange(connectionId, state))
    }
    
    func triggerIceGatheringStateChange(_ state: SPTIceGatheringState) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "ICE gathering state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(PeerConnectionNotifications.iceGatheringDidChange(connectionId, state))
        continuation.yield(PeerConnectionNotifications.iceGatheringDidChange(connectionId, state))
    }
    
    func triggerDataChannel(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Data channel: \(label)")
        guard !connectionId.isEmpty else { return }
        notifications?(PeerConnectionNotifications.dataChannel(connectionId, label))
        continuation.yield(PeerConnectionNotifications.dataChannel(connectionId, label))
    }
    
    func triggerShouldNegotiate() {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Should negotiate for connection: \(connectionId)")
        guard !connectionId.isEmpty else { return }
        notifications?(PeerConnectionNotifications.shouldNegotiate(connectionId))
        continuation.yield(PeerConnectionNotifications.shouldNegotiate(connectionId))
    }
}
#endif
