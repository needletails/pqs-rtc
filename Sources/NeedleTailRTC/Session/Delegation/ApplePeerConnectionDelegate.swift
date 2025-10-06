//
//  ApplePeerConnectionDelegate.swift
//  needle-tail-rtc
//
//  Created by Cole M on 10/4/25.
//
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
import Foundation
import NeedleTailLogger

#if canImport(WebRTC)
public final class ApplePeerConnectionDelegate: NSObject, WebRTC.RTCPeerConnectionDelegate, @unchecked Sendable {
    
    private let lock = NSLock()
    public var connectionId: String = ""
    private let logger: NeedleTailLogger
    private let continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    internal var notifications: (@Sendable (PeerConnectionNotifications?) -> Void)?
    
    init(
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        self.logger = logger
        self.continuation = continuation
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChange newState: WebRTC.RTCIceGatheringState) {
        lock.lock()
        defer { lock.unlock() }
        let state = SPTIceGatheringState(state: newState)
        logger.log(level: .info, message: "ICE gathering state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(.iceGatheringDidChange(connectionId, state))
        continuation.yield(.iceGatheringDidChange(connectionId, state))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didOpen dataChannel: WebRTC.RTCDataChannel) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Data channel opened: \(dataChannel.label)")
        guard !connectionId.isEmpty else { return }
        notifications?(.dataChannel(connectionId, dataChannel.label))
        continuation.yield(.dataChannel(connectionId, dataChannel.label))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChange stateChanged: WebRTC.RTCSignalingState) {
        lock.lock()
        defer { lock.unlock() }
        let state = SPTSignalingState(state: stateChanged)
        logger.log(level: .info, message: "Signaling state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(.signalingStateDidChange(connectionId, state))
        continuation.yield(.signalingStateDidChange(connectionId, state))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didAdd stream: WebRTC.RTCMediaStream) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Stream added: \(stream.streamId)")
        guard !connectionId.isEmpty else { return }
        notifications?(.addedStream(connectionId, stream.streamId))
        continuation.yield(.addedStream(connectionId, stream.streamId))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didRemove stream: WebRTC.RTCMediaStream) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Stream removed: \(stream.streamId)")
        guard !connectionId.isEmpty else { return }
        notifications?(.removedStream(connectionId, stream.streamId))
        continuation.yield(.removedStream(connectionId, stream.streamId))
    }
    
    public func peerConnectionShouldNegotiate(_ peerConnection: WebRTC.RTCPeerConnection) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Peer connection should negotiate")
        guard !connectionId.isEmpty else { return }
        notifications?(.shouldNegotiate(connectionId))
        continuation.yield(.shouldNegotiate(connectionId))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChange newState: WebRTC.RTCIceConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        let state = SPTIceConnectionState(state: newState)
        logger.log(level: .info, message: "ICE connection state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(.iceConnectionStateDidChange(connectionId, state))
        continuation.yield(.iceConnectionStateDidChange(connectionId, state))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didGenerate candidate: WebRTC.RTCIceCandidate) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .debug, message: "ICE candidate generated: \(candidate.sdp)")
        guard !connectionId.isEmpty else { return }
        notifications?(.generatedIceCandidate(connectionId, candidate.sdp, candidate.sdpMLineIndex, candidate.sdpMid))
        continuation.yield(.generatedIceCandidate(connectionId, candidate.sdp, candidate.sdpMLineIndex, candidate.sdpMid))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChangeStandardizedIceConnectionState newState: WebRTC.RTCIceConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        let state = SPTIceConnectionState(state: newState)
        logger.log(level: .info, message: "Standardized ICE connection state changed to: \(state.description)")
        guard !connectionId.isEmpty else { return }
        notifications?(.standardizedIceConnectionState(connectionId, state))
        continuation.yield(.standardizedIceConnectionState(connectionId, state))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didRemove candidates: [WebRTC.RTCIceCandidate]) {
        lock.lock()
        defer { lock.unlock() }
        logger.log(level: .info, message: "Removed \(candidates.count) ICE candidates")
        guard !connectionId.isEmpty else { return }
        notifications?(.removedIceCandidates(connectionId, candidates.count))
        continuation.yield(.removedIceCandidates(connectionId, candidates.count))
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didStartReceivingOn transceiver: WebRTC.RTCRtpTransceiver) {
        lock.lock()
        defer { lock.unlock() }
        let trackKind = transceiver.receiver.track?.kind ?? "unknown"
        logger.log(level: .info, message: "Started receiving on transceiver: \(trackKind)")
        guard !connectionId.isEmpty else { return }
        notifications?(.startedReceiving(connectionId, trackKind))
        continuation.yield(.startedReceiving(connectionId, trackKind))
    }
}
#endif
