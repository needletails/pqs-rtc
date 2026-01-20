//
//  RTCSession+PeerNotificationsHandler.swift
//  pqs-rtc
//
//  Created by Cole M on 12/3/25.
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

#if canImport(WebRTC)
import WebRTC
#endif
import BinaryCodable

extension RTCSession {
    
    private func sendEncryptedSfuCandidateIfPossible(
        _ candidate: IceCandidate,
        call: Call,
        sfuRecipientId: String
    ) async throws {
        // Encode candidate into the call metadata, then ratchet-encrypt the call bytes.
        var callForWire = call
        callForWire.metadata = try BinaryEncoder().encode(candidate)
        let plaintext = try BinaryEncoder().encode(callForWire)
        
        // Ensure sender initialization occurred before ratchet encrypting (idempotent).
        let recipientIdentity = try await ensureSfuSenderInitialization(call: call, sfuRecipientId: sfuRecipientId)
        
        let message = try await pcRatchetManager.ratchetEncrypt(
            plainText: plaintext,
            sessionId: recipientIdentity.sessionIdentity.id
        )
        let packet = RatchetMessagePacket(
            sfuIdentity: sfuRecipientId,
            header: message.header,
            ratchetMessage: message,
            flag: .candidate)
        
        try await requireTransport().sendSfuMessage(packet, call: call)
    }
    
    func handlePeerConnectionNotifications(generation: UInt64) async {
        notificationsConsumerIsRunning = true
        logger.log(level: .info, message: "Peer-notifications consumer is now listening (generation=\(generation))")
        defer {
            notificationsConsumerIsRunning = false
            let activeConnectionIdDescription = activeConnectionId ?? "nil"
            logger.log(
                level: .info,
                message: "Peer-notifications consumer exited (generation=\(generation), cancelled=\(Task.isCancelled), currentGeneration=\(notificationsTaskGeneration), activeConnectionId=\(activeConnectionIdDescription))"
            )
        }

        var didLogFirstNotification = false
        for await notification in peerConnectionNotificationsStream {
            if Task.isCancelled { break }
            if generation != notificationsTaskGeneration { break }
            guard let notification else { continue }

            if !didLogFirstNotification {
                didLogFirstNotification = true
                logger.log(level: .info, message: "Peer-notifications consumer received first notification")
            }
            
            // Extract connection ID from notification
            let connectionId: String
            switch notification {
            case .iceGatheringDidChange(let id, _),
                    .signalingStateDidChange(let id, _),
                    .addedStream(let id, _),
                    .removedStream(let id, _),
                    .didAddReceiver(let id, _, _, _),
                    .iceConnectionStateDidChange(let id, _),
                    .generatedIceCandidate(let id, _, _, _),
                    .standardizedIceConnectionState(let id, _),
                    .removedIceCandidates(let id, _),
                    .startedReceiving(let id, _),
                    .dataChannel(let id, _),
                    .dataChannelMessage(let id, _, _),
                    .shouldNegotiate(let id):
                connectionId = id
            }
            
            // Find the matching connection
            guard let connection = await connectionManager.findConnection(with: connectionId) else {
                self.logger.log(level: .warning, message: "No connection found for id: \(connectionId)")
                continue
            }
            
            // Process notification for the specific connection
            switch notification {
            case .iceGatheringDidChange(_, let newState):
                self.logger.log(level: .info, message: "peerConnection new gathering state: \(newState.description)")
            case .signalingStateDidChange(_, let stateChanged):
                self.logger.log(level: .info, message: "peerConnection new signaling state: \(stateChanged.description)")
                if stateChanged.description == "stable" {}
            case .addedStream(_, _):
                self.logger.log(level: .info, message: "peerConnection did add stream")
#if canImport(WebRTC)
                
                for sender in connection.peerConnection.senders {
                    let params = sender.parameters
                    for encoding in params.encodings {
                        encoding.isActive = true
                        self.logger.log(level: .info, message: "Setting Network Priority")
                        encoding.networkPriority = .high
                        self.logger.log(level: .info, message: "Set Network Priority to high")
                    }
                    sender.parameters = params
                }
                
                do {
                    // Create video sender FrameCryptor if not already created
                    if let videoSender = connection.peerConnection.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }),
                       connection.videoSenderCryptor == nil {
                        try await self.createEncryptedFrame(connection: connection, kind: .videoSender(videoSender))
                    }
                    // Create audio sender FrameCryptor if not already created
                    if let audioSender = connection.peerConnection.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindAudio }),
                       connection.audioSenderCryptor == nil {
                        try await self.createEncryptedFrame(connection: connection, kind: .audioSender(audioSender))
                    }
                } catch {
                    logger.log(level: .error, message: "Failed to create sender FrameCryptors in addedStream: \(error)")
                }
                
#endif
            case .removedStream(_, _):
                self.logger.log(level: .info, message: "peerConnection did remove stream")
            case .didAddReceiver(_, let trackKind, let streamIds, let trackId):
                self.logger.log(level: .info, message: "peerConnection did add receiver kind=\(trackKind) trackId=\(trackId) streamIds=\(streamIds)")
                // Convention for SFU-style calls: streamId identifies the remote participant.
                // If your SFU uses a different mapping, configure `setRemoteParticipantIdResolver`.
                let participantId = remoteParticipantIdResolver?(streamIds, trackId, trackKind) ?? (streamIds.first ?? "")
#if os(Android)
                // On Android, remote tracks are delivered via the AndroidRTCClient bridge.
                // We still model this as a Unified Plan receiver event so group-call demux
                // and per-participant cryptors work consistently.
                    if trackKind == "video" {
                        // Get the remote video track from the peer connection
                        let videoTrack = rtcClient.getRemoteVideoTrack(peerConnection: connection.peerConnection)
                        if let videoTrack {
                            var updated = connection
                            if !participantId.isEmpty {
                                // Note: Android doesn't have remoteVideoTracksByParticipantId yet,
                                // but we store the track for consistency
                            }
                            updated.remoteVideoTrack = videoTrack
                            await connectionManager.updateConnection(id: updated.id, with: updated)
                            
                            // Attach any pending renderer that was buffered before the track arrived
                            if let pendingRenderer = pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: updated.id) as? AndroidSampleCaptureView {
                                logger.log(level: .info, message: "Attaching buffered remote renderer now that remote video track is available (trackId=\(trackId))")
                                pendingRenderer.attach(videoTrack)
                            }
                        }
                    }
                    
                    if let mediaDelegate, !participantId.isEmpty {
                        await mediaDelegate.didAddRemoteTrack(connectionId: connection.id, participantId: participantId, kind: trackKind, trackId: trackId)
                    }

                    // Determine the correct participant ID for the receiver cryptor:
                    // - For group calls: use participantId from streamIds (identifies the track owner)
                    // - For 1:1 calls in perParticipant mode: use connection.remoteParticipantId (matches the key that was set)
                    let receiverParticipantId: String
                    if self.groupCalls[connection.id] != nil {
                        // Group call: use the participantId from streamIds
                        receiverParticipantId = participantId.isEmpty ? connection.remoteParticipantId : participantId
                    } else if self.frameEncryptionKeyMode == .perParticipant {
                        // 1:1 call in perParticipant mode: use remoteParticipantId to match the key
                        receiverParticipantId = connection.remoteParticipantId
                    } else {
                        // 1:1 call in shared mode: use remoteParticipantId for consistency
                        receiverParticipantId = connection.remoteParticipantId
                    }

                    if !receiverParticipantId.isEmpty {
                        rtcClient.createReceiverEncryptedFrame(
                            participant: receiverParticipantId,
                            connectionId: connection.id,
                            trackKind: trackKind,
                            trackId: trackId
                        )
                    }
#elseif canImport(WebRTC)
                do {
                    if trackKind == kRTCMediaStreamTrackKindVideo,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let videoTrack = receiver.track as? WebRTC.RTCVideoTrack {
                        var updated = connection
                        if !participantId.isEmpty {
                            updated.remoteVideoTracksByParticipantId[participantId] = videoTrack
                        }
                        updated.remoteVideoTrack = videoTrack
                        await connectionManager.updateConnection(id: updated.id, with: updated)

                        if let pendingRenderer = pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: updated.id) {
                            logger.log(level: .info, message: "Attaching buffered remote renderer now that remote video track is available (trackId=\(trackId))")
                            videoTrack.add(pendingRenderer)
                        }

                        if let mediaDelegate, !participantId.isEmpty {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: participantId, kind: "video", trackId: trackId)
                        }

                        // Determine the correct participant ID for the receiver cryptor:
                        // - For group calls: use participantId from streamIds (identifies the track owner)
                        // - For 1:1 calls in perParticipant mode: use connection.remoteParticipantId (matches the key that was set)
                        let receiverParticipantId: String?
                        if self.groupCalls[connection.id] != nil {
                            // Group call: use the participantId from streamIds
                            receiverParticipantId = participantId.isEmpty ? nil : participantId
                        } else if self.frameEncryptionKeyMode == .perParticipant {
                            // 1:1 call in perParticipant mode: use remoteParticipantId to match the key
                            receiverParticipantId = connection.remoteParticipantId
                        } else {
                            // 1:1 call in shared mode: participantId doesn't matter, but use remoteParticipantId for consistency
                            receiverParticipantId = nil
                        }

                        try await self.createEncryptedFrame(
                            connection: updated,
                            kind: .videoReceiver(receiver),
                            participantIdOverride: receiverParticipantId
                        )
                    }

                    if trackKind == kRTCMediaStreamTrackKindAudio,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let audioTrack = receiver.track as? WebRTC.RTCAudioTrack {
                        var updated = connection
                        if !participantId.isEmpty {
                            updated.remoteAudioTracksByParticipantId[participantId] = audioTrack
                        }
                        await connectionManager.updateConnection(id: updated.id, with: updated)

                        if let mediaDelegate, !participantId.isEmpty {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: participantId, kind: "audio", trackId: trackId)
                        }

                        // Determine the correct participant ID for the receiver cryptor:
                        // - For group calls: use participantId from streamIds (identifies the track owner)
                        // - For 1:1 calls in perParticipant mode: use connection.remoteParticipantId (matches the key that was set)
                        let receiverParticipantId: String?
                        if self.groupCalls[connection.id] != nil {
                            // Group call: use the participantId from streamIds
                            receiverParticipantId = participantId.isEmpty ? nil : participantId
                        } else if self.frameEncryptionKeyMode == .perParticipant {
                            // 1:1 call in perParticipant mode: use remoteParticipantId to match the key
                            receiverParticipantId = connection.remoteParticipantId
                        } else {
                            // 1:1 call in shared mode: participantId doesn't matter, but use remoteParticipantId for consistency
                            receiverParticipantId = nil
                        }

                        try await self.createEncryptedFrame(
                            connection: updated,
                            kind: .audioReceiver(receiver),
                            participantIdOverride: receiverParticipantId
                        )
                    }
                } catch {
                    logger.log(level: .error, message: "Failed to handle didAddReceiver (kind=\(trackKind), trackId=\(trackId)): \(error)")
                }
#endif
            case .iceConnectionStateDidChange(let connectionId, let newState):
                if let active = activeConnectionId, active != connection.id {
                    self.logger.log(level: .debug, message: "Ignoring iceConnectionStateDidChange for non-active connection (active=\(active), got=\(connection.id))")
                    continue
                }
                self.logger.log(level: .info, message: "peerConnection new connection state: \(newState.description)")
                if newState.state == .connected, let callDirection = await self.callState.callDirection {
                    let id: String? = connectionId
                    
                    await self.callState.transition(
                        to: .connected(
                            callDirection,
                            connection.call))
                }
                if newState.state == .closed {
                    await finishEndConnection(currentCall: connection.call)
                }
            case .generatedIceCandidate(_, let sdp, let mLine, let mid):
                if let active = activeConnectionId, active != connection.id {
                    self.logger.log(level: .debug, message: "Ignoring generatedIceCandidate for non-active connection (active=\(active), got=\(connection.id))")
                    continue
                }
                do {
                    iceId += 1
                    var candidate: IceCandidate?
#if os(Android)
                    let rtc = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLine, sdpMid: mid)
                    candidate = try IceCandidate(from: rtc, id: iceId)
#elseif canImport(WebRTC)
                    let rtc: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLine, sdpMid: mid)
                    candidate = try IceCandidate(from: rtc, id: iceId)
#endif
                    
                    self.logger.log(level: .info, message: "Generated Ice Candidate \(iceId)")
                    guard let candidate else {
                        self.logger.log(level: .error, message: "Generated ICE candidate could not be constructed (id=\(iceId))")
                        continue
                    }
                    
                    if readyForCandidates {
                        
                        do {
                            // For SFU group calls, encrypt ICE candidates over the SFU ratchet.
                            if self.groupCalls[connection.id] != nil {
                                try await self.sendEncryptedSfuCandidateIfPossible(
                                    candidate,
                                    call: connection.call,
                                    sfuRecipientId: connection.id
                                )
                                self.logger.log(level: .info, message: "Sent encrypted SFU candidate, \(candidate.id)")
                            } else {
                                // For 1:1 calls, encrypt candidate and send via encrypted transport
                                var call = connection.call
                                call.metadata = try BinaryEncoder().encode(candidate)
                                let plaintext = try BinaryEncoder().encode(call)
                                guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(call.sharedCommunicationId),
                                      let remoteProps = await connectionIdentity.sessionIdentity.props(symmetricKey: connectionIdentity.symmetricKey)  else {
                                    throw RTCErrors.invalidConfiguration("Remote session identity props not set for connection: \(call.sharedCommunicationId)")
                                }
                                let packet = try await self.encryptOneToOneSignaling(
                                    plaintext: plaintext,
                                    connectionId: connection.call.sharedCommunicationId,
                                    flag: .candidate,
                                    remoteProps: remoteProps)
                                guard var recipient = call.recipients.first else {
                                    throw RTCErrors.invalidConfiguration("Received a call without a recipient")
                                }

                                guard let sessionParticipant else {
                                    throw RTCErrors.invalidConfiguration("Received a call without a session participant")
                                }
                                if recipient.secretName == sessionParticipant.secretName {
                                    recipient.deviceId = sessionParticipant.deviceId
                                    
                                    let copiedSender = call.sender
                                    call.recipients = [copiedSender]
                                    call.sender = recipient
                                    recipient = copiedSender
                                }
                                try await self.requireTransport().sendOneToOneMessage(packet, recipient: recipient)
                                self.logger.log(level: .info, message: "Sent encrypted 1:1 candidate, \(candidate.id)")
                            }
                        } catch {
                            self.logger.log(level: .error, message: "Failed to send ICE candidate (id=\(candidate.id)): \(error)")
                        }
                    } else {
                        iceDeque.append(candidate)
                    }
                } catch {
                    self.logger.log(level: .error, message: "Failed to Send Ice Candidate \(error)")
                }
            case .standardizedIceConnectionState(let connectionId, let newState):
                if let active = activeConnectionId, active != connection.id {
                    self.logger.log(level: .debug, message: "Ignoring standardizedIceConnectionState for non-active connection (active=\(active), got=\(connection.id))")
                    continue
                }
                self.logger.log(level: .info, message: "peerConnection did change ice state \(newState.description)")
                
                if newState.state == .failed || newState.state == .disconnected || newState.state == .closed {
                    iceDeque.removeAll()
                    if let id = connectionId as String? {

                            if let callDirection = await self.callState.callDirection {
                                let errorMessage = newState.state == .failed ? "PeerConnection Failed" :
                                (newState.state == .disconnected ? "PeerConnection Disconnected" : "PeerConnection Closed")
                                await callState.transition(to: .failed(callDirection, connection.call, errorMessage))
                                await finishEndConnection(currentCall: connection.call)
                            }
                        
                        var errorMessage = ""
                        
                        if newState.state == .failed {
                            errorMessage = "PeerConnection Failed"
                        } else if newState.state == .disconnected {
                            errorMessage = "PeerConnection Disconnected"
                        } else if newState.state == .closed {
                            errorMessage = "PeerConnection Closed"
                        }
                        
                        // Determine call direction
                        let callDirection: CallStateMachine.CallDirection
                        if let existingDirection = await self.callState.callDirection {
                            callDirection = existingDirection
                        } else {
                            // Fallback: determine from call type
                            callDirection = .inbound(connection.call.supportsVideo ? .video : .voice)
                        }
                        
                        await callState.transition(to: .failed(callDirection, connection.call, errorMessage))
                        await finishEndConnection(currentCall: connection.call)
                    }
                }
                
            case .removedIceCandidates(_, _):
                self.logger.log(level: .info, message: "peerConnection did remove candidate(s)")
            case .startedReceiving(_, let trackKind):
                self.logger.log(level: .info, message: "peerConnection didStartReceiving \(trackKind)")
#if canImport(WebRTC)
                do {
                    // Determine the correct participant ID for receiver cryptors:
                    // - For group calls: participantIdOverride will be set in didAddReceiver
                    // - For 1:1 calls in perParticipant mode: use remoteParticipantId to match the key
                    let receiverParticipantId: String?
                    if self.groupCalls[connection.id] != nil {
                        // Group call: participantId will be set when didAddReceiver fires
                        receiverParticipantId = nil
                    } else if self.frameEncryptionKeyMode == .perParticipant {
                        // 1:1 call in perParticipant mode: use remoteParticipantId to match the key
                        receiverParticipantId = connection.remoteParticipantId
                    } else {
                        // 1:1 call in shared mode: participantId doesn't matter
                        receiverParticipantId = nil
                    }
                    
                    if trackKind == "video", let videoReceiver = connection.peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver {
                        try await self.createEncryptedFrame(connection: connection, kind: .videoReceiver(videoReceiver), participantIdOverride: receiverParticipantId)
                    }
                    if trackKind == "audio", let audioReceiver = connection.peerConnection.transceivers.first(where: { $0.mediaType == .audio })?.receiver {
                        try await self.createEncryptedFrame(connection: connection, kind: .audioReceiver(audioReceiver), participantIdOverride: receiverParticipantId)
                    }
                } catch {
                    logger.log(level: .error, message: "Failed to create encrypted frame")
                }
#endif
            case .dataChannel(let connectionId, let channelLabel):
                logger.log(level: .info, message: "Data channel '\(channelLabel)' opened for connection \(connectionId)")
#if canImport(WebRTC) && !os(Android)
                if let dataChannel = connection.delegateWrapper.delegate?.getDataChannel(for: channelLabel) {
                    var updated = connection
                    updated.dataChannels[channelLabel] = dataChannel
                    await connectionManager.updateConnection(id: updated.id, with: updated)
                }
#endif
            case .dataChannelMessage(_, let channelLabel, let data):
                
                self.logger.log(level: .info, message: "Received data channel message on channel: \(channelLabel), size: \(data.count) bytes")
                do {
                    try await processDataMessage(
                        connectionId: connectionId,
                        channelLabel: channelLabel,
                        data: data)
                } catch {
                    logger.log(level: .error, message: "Failed to process data message: \(error)")
                }
            case .shouldNegotiate(_):
                self.logger.log(level: .info, message: "peerConnection should negotiate")
            }
        }
    }
}
