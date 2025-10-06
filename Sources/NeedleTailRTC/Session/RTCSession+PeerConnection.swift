//
//  RTCSession+PeerConnection.swift
//  needle-tail-rtc
//
//  Created by Cole M on 9/11/24.
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
import Foundation
import NeedleTailLogger
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif


extension RTCSession {
    
#if !os(Android)
    func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool, with connection: RTCConnection) async {
        connection.peerConnection.transceivers
            .compactMap { $0.sender.track as? T }
            .forEach { $0.isEnabled = isEnabled }
    }
#endif
    public func removePeerConnection(with id: String) async {
        await connectionManager.removeConnection(with: id)
    }
    
    public func hasConnection(id: String) async -> Bool {
        await connectionManager.findConnection(with: id) != nil
    }
    
    /// Creates a new peer connection with proper error handling and validation
    /// - Parameters:
    ///   - id: The connection ID
    ///   - hasVideo: Whether the connection supports video
    /// - Returns: The created RTCConnection
    /// - Throws: RTCErrors if creation fails
    public func createPeerConnection(with id: String, hasVideo: Bool) async throws -> RTCConnection {
        logger.log(level: .info, message: "Creating peer connection with id: \(id), hasVideo: \(hasVideo)")
        
        // Validate input parameters
        guard !id.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            logger.log(level: .error, message: "Connection ID cannot be empty")
            throw RTCErrors.invalidConfiguration("Connection ID cannot be empty")
        }
        
        // Create a dummy continuation for the delegate wrapper
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        
        var connection: RTCConnection?
#if os(Android)
        let allConnections = await connectionManager.findAllConnections()
        if let existingConnection = allConnections.first {
            logger.log(level: .info, message: "Reusing existing connection for id: \(id)")
            // Create a new connection object with the same peer connection but different ID
            let newConnection = RTCConnection(
                id: id,
                peerConnection: existingConnection.peerConnection,
                delegateWrapper: existingConnection.delegateWrapper,
                localVideoTrack: existingConnection.localVideoTrack,
                remoteVideoTrack: existingConnection.remoteVideoTrack
            )
            
            // Add the new connection to the manager
            await connectionManager.addConnection(newConnection)
            return newConnection
        }
        
        // Initialize the factory with ICE servers
        let iceServers = self.getIceServers()
        RTCSession.rtcClient.initializeFactory(iceServers: iceServers)
        
        // For NeedleTailRTC, we use the RTCClient directly as the peer connection
        connection = RTCConnection(
            id: id,
            peerConnection: RTCSession.rtcClient,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(logger: self.logger, continuation: continuation))
        
#elseif canImport(WebRTC)
        let config = WebRTC.RTCConfiguration()
        let iceServers = [
            WebRTC.RTCIceServer(
                urlStrings: self.getIceServers(),
                username: self.getUsername(),
                credential: self.getPassword())
        ]
        
        config.iceServers = iceServers
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        config.enableDscp = true
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        config.continualGatheringPolicy = .gatherContinually
        
        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = WebRTC.RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: [
                                                "DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue,
                                                "googDscp" : kRTCMediaConstraintsValueTrue]
        )
        // iOS/macOS WebRTC peer connection creation
        guard let createdPeerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            logger.log(level: .error, message: "Failed to create RTCPeerConnection")
            throw RTCErrors.mediaError("Failed to create RTCPeerConnection")
        }
        
        connection = RTCConnection(
            id: id,
            peerConnection: createdPeerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(logger: self.logger, continuation: continuation))
#endif
        
#if os(iOS)
        do {
            try self.configureAudioSession()
        } catch {
            logger.log(level: .error, message: "Failed to configure audio session: \(error)")
            throw RTCErrors.mediaError("Failed to configure audio session: \(error.localizedDescription)")
        }
#endif
        
        guard var connection else {
            fatalError("Failed to create RTCPeerConnection")
        }
        // Add audio and video tracks
        connection = try await self.addAudioToStream(with: connection)
        if hasVideo {
            connection = try await self.addVideoToStream(with: connection)
        }
        
#if !os(Android)
        connection.peerConnection.delegate = connection.delegateWrapper.delegate
#endif
        // Add connection to manager
        await connectionManager.addConnection(connection)
        
        handleNotificationsStream()
        
        logger.log(level: .info, message: "Successfully created peer connection with id: \(id)")
        return connection
    }
    
    func handlePeerConnectionNotifications() async {
        for connection in await connectionManager.findAllConnections() {
            let stream = AsyncStream<PeerConnectionNotifications?>(bufferingPolicy: AsyncStream<PeerConnectionNotifications?>.Continuation.BufferingPolicy.bufferingNewest(1)) { [weak self] continuation in
                guard let self else { return }
                connection.delegateWrapper.setConnectionId(connection.id)
                connection.delegateWrapper.setNotifications { notification in
                    continuation.yield(notification)
                }
                continuation.onTermination = { status in
#if DEBUG
                    self.logger.log(level: .debug, message: "PeerConnection Stream terminated with status: \(status)")
#endif
                }
                self.notificationStreamContinuation = continuation
            }
            
            
            for await notification in stream {
                if let notification = notification {
                    switch notification {
                    case PeerConnectionNotifications.iceGatheringDidChange(_, let newState):
                        self.logger.log(level: .info, message: "peerConnection new gathering state: \(newState.description)")
                    case PeerConnectionNotifications.signalingStateDidChange(_, let stateChanged):
                        self.logger.log(level: .info, message: "peerConnection new signaling state: \(stateChanged.description)")
                    case PeerConnectionNotifications.addedStream(_, _):
                        self.logger.log(level: .info, message: "peerConnection did add stream")
#if canImport(WebRTC)
                        for sender in connection.peerConnection.senders {
                            let params = sender.parameters
                            for encoding in params.encodings {
                                encoding.isActive = true
                                self.logger.log(level: .info, message: "Setting Network Priority")
                                // encoding.networkPriority = .high
                                self.logger.log(level: .info, message: "Set Network Priority to high")
                            }
                            sender.parameters = params
                        }
#endif
                    case PeerConnectionNotifications.removedStream(_, _):
                        self.logger.log(level: .info, message: "peerConnection did remove stream")
                    case PeerConnectionNotifications.iceConnectionStateDidChange(let connectionId, let newState):
                        self.logger.log(level: .info, message: "peerConnection new connection state: \(newState.description)")
                        if newState.state == .connected, let callDirection = await self.callState.getCallDirection() {
                            let id: String? = connectionId
                            guard let currentCall = await calls.first(where: { $0.sharedCommunicationId == id }) else { return }
                            
                            await self.callState.transition(
                                to: .connected(
                                    callDirection,
                                    currentCall))
                        }
                        if newState.state == .closed {
                            let id: String? = connectionId
                            guard let currentCall = await calls.first(where: { $0.sharedCommunicationId == id }) else { return }
                            await finishEndConnection(currentCall: currentCall)
                        }
                    case PeerConnectionNotifications.generatedIceCandidate(let connectionId, let sdp, let mLine, let mid):
                        do {
                            setIceId(getIceId() + 1)
                            
                            var candidate: IceCandidate?
#if os(Android)
                            let rtc = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLine, sdpMid: mid)
                            candidate = try IceCandidate(from: rtc, id: self.getIceId())
#elseif canImport(WebRTC)
                            let rtc: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLine, sdpMid: mid)
                            candidate = try IceCandidate(from: rtc, id: self.getIceId())
#endif
                            
                            self.logger.log(level: .info, message: "Generated Ice Candidate \(getIceId())")
                            guard let candidate else {
                                fatalError()
                            }
                            
                            if getReadyForCandidates() {
                                let id: String? = connectionId
                                logger.log(level: .info, message: "Looking up call for id \(id ?? "nil")")
                                guard let currentCall = await calls.first(where: { $0.sharedCommunicationId == id }) else {
                                    throw RTCErrors.callNotFound
                                }
                                
                                try await self.getDelegate()?.sendCandidate(
                                    candidate,
                                    call: currentCall)
                                self.logger.log(level: .info, message: "Sent Candidate, \(candidate.id)")
                            } else {
                                var deque = getIceDeque()
                                deque.append(candidate)
                                setIceDeque(deque)
                            }
                        } catch {
                            self.logger.log(level: .error, message: "Failed to Send Ice Candidate \(error)")
                        }
                    case PeerConnectionNotifications.standardizedIceConnectionState(let connectionId, let newState):
                        self.logger.log(level: .info, message: "peerConnection did change ice state \(newState.description)")
                        
                        if newState.state == .failed || newState.state == .disconnected || newState.state == .closed {
                            var deque = getIceDeque()
                            deque.removeAll()
                            setIceDeque(deque)
                            if let id = connectionId as String? {
                                do {
                                    guard let currentCall = await calls.first(where: { $0.sharedCommunicationId == id }) else { throw RTCErrors.callNotFound }
                                    var errorMessage = ""
                                    
                                    if newState.state == .failed {
                                        errorMessage = "PeerConnection Failed"
                                    } else if newState.state == .disconnected {
                                        errorMessage = "PeerConnection Disconnected"
                                    } else if newState.state == .closed {
                                        errorMessage = "PeerConnection Closed"
                                    }
                                    await callState.transition(to: .failed(.inbound(currentCall.supportsVideo ? .video : .voice), currentCall, errorMessage))
                                    await finishEndConnection(currentCall: currentCall)
                                    await shutdown()
                                } catch {
                                    self.logger.log(level: .error, message: "Failed to End Call")
                                    if let lastCall = await calls.last {
                                        await finishEndConnection(currentCall: lastCall)
                                    }
                                    await shutdown()
                                }
                            }
                        }
                        
                    case PeerConnectionNotifications.removedIceCandidates(_, _):
                        self.logger.log(level: .info, message: "peerConnection did remove candidate(s)")
                    case PeerConnectionNotifications.startedReceiving(_, let trackKind):
                        self.logger.log(level: .info, message: "peerConnection didStartReceiving \(trackKind)")
                    case PeerConnectionNotifications.dataChannel(_, _):
                        break
                    case PeerConnectionNotifications.shouldNegotiate(_):
                        self.logger.log(level: .info, message: "peerConnection should negotiate")
                    }
                }
            }
        }
    }
}
