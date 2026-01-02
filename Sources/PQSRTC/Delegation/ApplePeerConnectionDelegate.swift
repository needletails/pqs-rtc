//
//  ApplePeerConnectionDelegate.swift
//  pqs-rtc
//
//  Created by Cole M on 10/4/25.
//
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
import Foundation
import NeedleTailLogger

#if canImport(WebRTC)
/// A WebRTC delegate bridge for Apple platforms.
///
/// `ApplePeerConnectionDelegate` adapts WebRTC delegate callbacks into
/// `PeerConnectionNotifications` events, which are yielded into the session's notification stream.
///
/// The delegate also tracks opened data channels by label so call logic can retrieve and reuse
/// them.
public final class ApplePeerConnectionDelegate: NSObject, WebRTC.RTCPeerConnectionDelegate, WebRTC.RTCDataChannelDelegate, @unchecked Sendable {
    
    private let connectionId: String
    private let lock = NSLock()
    private let logger: NeedleTailLogger
    private let continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    private var openedDataChannels: [String: RTCDataChannel] = [:]
    
    init(
        connectionId: String,
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        self.connectionId = connectionId
        self.logger = logger
        self.continuation = continuation
    }
    
    /// Returns a previously opened data channel for `label`, if one exists.
    ///
    /// - Parameter label: The data channel label.
    /// - Returns: The matching `RTCDataChannel` if it has been opened and stored.
    func getDataChannel(for label: String) -> RTCDataChannel? {
        lock.withLock {
            openedDataChannels[label]
        }
    }
    
    /// Stops the notification stream for this delegate.
    ///
    /// This should be invoked during connection/session teardown.
    public func shutdown() async {
        continuation.finish()
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChange newState: WebRTC.RTCIceGatheringState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            let state = SPTIceGatheringState(state: newState)
            self.logger.log(level: .info, message: "ICE gathering state changed to: \(state.description)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.iceGatheringDidChange(self.connectionId, state))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didOpen dataChannel: WebRTC.RTCDataChannel) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .info, message: "Data channel opened: \(dataChannel.label)")
            // Store the channel for later retrieval
            self.openedDataChannels[dataChannel.label] = dataChannel
            // Set delegate to receive state changes and messages
            dataChannel.delegate = self
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.dataChannel(self.connectionId, dataChannel.label))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChange stateChanged: WebRTC.RTCSignalingState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            let state = SPTSignalingState(state: stateChanged)
            self.logger.log(level: .info, message: "Signaling state changed to: \(state.description)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.signalingStateDidChange(self.connectionId, state))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didAdd stream: WebRTC.RTCMediaStream) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .info, message: "Stream added: \(stream.streamId)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.addedStream(self.connectionId, stream.streamId))
        }
    }

    // Unified Plan: invoked when a new remote receiver/track is added.
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didAdd rtpReceiver: WebRTC.RTCRtpReceiver, streams: [WebRTC.RTCMediaStream]) {
        lock.withLock { [weak self] in
            guard let self else { return }
            let kind = rtpReceiver.track?.kind ?? "unknown"
            let trackId = rtpReceiver.track?.trackId ?? ""
            let streamIds = streams.map { $0.streamId }
            self.logger.log(level: .info, message: "Receiver added kind=\(kind) trackId=\(trackId) streams=\(streamIds)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.didAddReceiver(self.connectionId, kind, streamIds, trackId))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didRemove stream: WebRTC.RTCMediaStream) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .info, message: "Stream removed: \(stream.streamId)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.removedStream(self.connectionId, stream.streamId))
        }
    }
    
    public func peerConnectionShouldNegotiate(_ peerConnection: WebRTC.RTCPeerConnection) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .info, message: "PeerConnection should negotiate")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.shouldNegotiate(self.connectionId))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChange newState: WebRTC.RTCIceConnectionState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            let state = SPTIceConnectionState(state: newState)
            self.logger.log(level: .info, message: "ICE connection state changed to: \(state.description)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.iceConnectionStateDidChange(self.connectionId, state))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didGenerate candidate: WebRTC.RTCIceCandidate) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .debug, message: "ICE candidate generated: \(candidate.sdp)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.generatedIceCandidate(self.connectionId, candidate.sdp, candidate.sdpMLineIndex, candidate.sdpMid))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didChangeStandardizedIceConnectionState newState: WebRTC.RTCIceConnectionState) {
        lock.withLock { [weak self] in
            guard let self else { return }
            let state = SPTIceConnectionState(state: newState)
            self.logger.log(level: .info, message: "Standardized ICE connection state changed to: \(state.description)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.standardizedIceConnectionState(self.connectionId, state))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didRemove candidates: [WebRTC.RTCIceCandidate]) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .info, message: "Removed \(candidates.count) ICE candidates")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.removedIceCandidates(self.connectionId, candidates.count))
        }
    }
    
    public func peerConnection(_ peerConnection: WebRTC.RTCPeerConnection, didStartReceivingOn transceiver: WebRTC.RTCRtpTransceiver) {
        lock.withLock { [weak self] in
            guard let self else { return }
            let trackKind = transceiver.receiver.track?.kind ?? "unknown"
            self.logger.log(level: .info, message: "Started receiving on transceiver: \(trackKind)")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.startedReceiving(self.connectionId, trackKind))
        }
    }
    
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let stateDescription: String
        switch dataChannel.readyState {
        case .connecting:
            stateDescription = "connecting"
        case .open:
            stateDescription = "open"
        case .closing:
            stateDescription = "closing"
        case .closed:
            stateDescription = "closed"
        @unknown default:
            stateDescription = "unknown(\(dataChannel.readyState.rawValue))"
        }
        self.logger.log(level: .info, message: "Data channel '\(dataChannel.label)' state changed to: \(stateDescription)")
        
        // Ensure channel is stored when it opens
        if dataChannel.readyState == .open {
            lock.withLock { [weak self] in
                guard let self else { return }
                self.openedDataChannels[dataChannel.label] = dataChannel
            }
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        lock.withLock { [weak self] in
            guard let self else { return }
            self.logger.log(level: .info, message: "Data channel message received on channel: \(dataChannel.label), size: \(buffer.data.count) bytes")
            guard !self.connectionId.isEmpty else { return }
            self.continuation.yield(.dataChannelMessage(self.connectionId, dataChannel.label, buffer.data))
        }
    }
}
#endif
