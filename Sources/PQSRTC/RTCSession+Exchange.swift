//
//  RTCSession+Exchange.swift
//  pqs-rtc
//
//  Created by Cole M on 9/11/24.
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
import NeedleTailAsyncSequence
import NeedleTailLogger
import BinaryCodable
#if !os(Android)
@preconcurrency import WebRTC
#endif
#if SKIP
import org.webrtc.__
#endif

extension RTCSession {
    
    
    //MARK: Public
    
    public func handleHandshakeCompleted(_ call: Call) async throws {
        let copiedSender = call.sender
        let call = try resolveProperRecipient(call: call)
        let recipient = copiedSender
        
        try await startSendingCandidates(call: call)
        if !handshakeComplete {
            setHandshakeComplete(true)
            
            let connectionIdentity = try await pcKeyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId)
            guard let remoteProps = await connectionIdentity.sessionIdentity.props(symmetricKey: connectionIdentity.symmetricKey)  else {
                throw RTCErrors.invalidConfiguration("Remote session identity props not set for connection: \(call.sharedCommunicationId)")
            }
            
            let plaintext = try BinaryEncoder().encode(call)
            let writeTask = WriteTask(
                data: plaintext,
                roomId: call.sharedCommunicationId.normalizedConnectionId,
                flag: .handshakeComplete,
                call: call)
            let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
            try await taskProcessor.feedTask(task: encryptableTask)
        }
    }
    
    /// Applies an inbound SDP offer (1:1) and generates/sends an SDP answer.
    ///
    /// This calls ``RTCTransportEvents/sendOneToOneAnswer(_:call:)`` and begins ICE candidate sending.
    public func handleOffer(
        call: Call,
        sdp: SessionDescription,
        answerDeviceId: String
    ) async throws -> Call {
        let call = try resolveProperRecipient(call: call)
        
        let sdpNegotiationMetadata = try PQSRTC.SDPNegotiationMetadata(
            offerSecretName: call.sender.secretName,
            offerDeviceId: call.sender.deviceId,
            answerDeviceId: answerDeviceId)
        
        let modified = await modifySDP(
            sdp: sdp.sdp,
            hasVideo: call.supportsVideo,
            stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
        )
        
#if os(Android)
        try await rtcClient.setRemoteDescription(RTCSessionDescription(
            typeDescription: "OFFER",
            sdp: modified))
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(
                                    type: sdp.type.rtcSdpType,
                                    sdp: modified),
                            call: call)
#endif
        
        
        let processedCall = try await createAnswer(call: call)
        
        guard let remoteProps = call.signalingIdentityProps else {
            throw RTCErrors.invalidConfiguration("Remote Props are nil")
        }
        
        // Encrypt answer and send (roomId normalized; "#" reattached at transport).
        let plaintext = try BinaryEncoder().encode(processedCall)
        let writeTask = WriteTask(
            data: plaintext,
            roomId: call.sharedCommunicationId.normalizedConnectionId,
            flag: .answer,
            call: call)
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)
        
#if os(iOS) && canImport(AVKit)
        try setExternalAudioSession()
#endif
        
        if var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
            connection.call = processedCall
            await connectionManager.updateConnection(id: call.sharedCommunicationId, with: connection)
        }
        return processedCall
    }
    
    /// Applies a renegotiation offer (remote SDP) and creates an answer.
    /// Used when the SFU sends a renegotiation offer to an existing peer so they can receive a new peer's media.
    /// - Returns: Call with answer SDP in metadata, ready to be encoded and sent.
    func handleRenegotiationOffer(sdp: SessionDescription, call: Call) async throws -> Call {
        let modified = await modifySDP(
            sdp: sdp.sdp,
            hasVideo: call.supportsVideo,
            stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
        )
#if os(Android)
        try await rtcClient.setRemoteDescription(RTCSessionDescription(
            typeDescription: "OFFER",
            sdp: modified))
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(type: sdp.type.rtcSdpType, sdp: modified),
                            call: call)
#endif
        return try await createAnswer(call: call)
    }
    
    /// Applies an inbound SDP answer (1:1).
    public func handleAnswer(
        call: Call,
        sdp: SessionDescription
    ) async throws {
        let call = try resolveProperRecipient(call: call)
        let modified = await modifySDP(
            sdp: sdp.sdp,
            hasVideo: call.supportsVideo,
            stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
        )
        
#if os(Android)
        try await rtcClient.setRemoteDescription(RTCSessionDescription(
            typeDescription: "ANSWER",
            sdp: modified))
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(type: sdp.type.rtcSdpType, sdp: modified),
                            call: call)
#endif
        if var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
            connection.call = call
            await connectionManager.updateConnection(id: call.sharedCommunicationId, with: connection)
        }
        
        if !handshakeComplete {
            guard var recipient = call.recipients.first else {
                throw RTCErrors.invalidConfiguration("Received handshakeComplete without a recipient in call")
            }
            
            var call = call
            
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
            
            let connectionIdentity = try await pcKeyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId)
            guard let remoteProps = await connectionIdentity.sessionIdentity.props(symmetricKey: connectionIdentity.symmetricKey) else {
                throw RTCErrors.invalidConfiguration("Remote session identity props not set for connection: \(call.sharedCommunicationId)")
            }
            
            let plaintext = try BinaryEncoder().encode(call)
            let writeTask = WriteTask(
                data: plaintext,
                roomId: call.sharedCommunicationId.normalizedConnectionId,
                flag: .handshakeComplete,
                call: call)
            let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
            try await taskProcessor.feedTask(task: encryptableTask)
            setHandshakeComplete(true)
            
            try await startSendingCandidates(call: call)
        }
    }
    
    /// Applies an inbound ICE candidate.
    public func handleCandidate(
        call: Call,
        candidate: IceCandidate
    ) async throws {
        let call = try resolveProperRecipient(call: call)
        try await setRemote(candidate: candidate, call: call)
    }
    
    public func startSendingCandidates(call: Call) async throws {
        guard await connectionManager.findConnection(with: call.sharedCommunicationId) != nil else { return }
        if !iceDeque.isEmpty {
            for item in iceDeque {
                try await sendEncryptedSfuCandidateFromDeque(item, call: call)
            }
            iceDeque.removeAll()
        }
        readyForCandidates = true
    }
    
    //MARK: Internal
    
    /// Creates an SDP offer for a call with proper error handling and validation
    /// - Parameters:
    ///   - call: The call to create an offer for
    ///   - hasVideo: Whether the call supports video
    /// - Returns: BSON document containing the offer
    /// - Throws: SDPHandlerError or RTCErrors if creation fails
    func createOffer(call: Call) async throws -> Call {
        do {
            
            let hasVideo = call.supportsVideo
            logger.log(level: .info, message: "Creating offer for call: \(call.sharedCommunicationId), hasVideo: \(hasVideo)")
            
            // ICE gathering + negotiation callbacks are emitted via the internal peer-notifications
            // stream. If the consumer task exited during a previous teardown, restart it here so
            // we don't miss generated ICE candidates on subsequent calls.
            handleNotificationsStream()
            
            let connection: RTCConnection? = try await loop.runReturningLoop(expiresIn: 30, sleep: .seconds(1)) { [weak self] in
                guard let self else { return (false, nil) }
                // First try to find by sharedCommunicationId
                if let foundConnection = await self.connectionManager.findConnection(with: call.sharedCommunicationId) {
                    self.logger.log(level: .debug, message: "Found connection for call: \(call.sharedCommunicationId)")
                    return (false, foundConnection)
                }
                return (true, nil)
            }
            
            guard let connection else {
                throw RTCErrors.connectionNotFound
            }
            var sdp: SessionDescription
#if os(Android)
            // Generate SDP offer using the new SDPHandler
            var description: RTCSessionDescription = try await generateSDPOffer(for: connection, hasAudio: true, hasVideo: hasVideo)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android: generateSDPOffer completed")
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Offer SDP:\n" + description.sdp)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: hasVideo,
                stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
            )
            description = RTCSessionDescription(typeDescription: description.typeDescription, sdp: modified)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Modified Offer SDP:\n" + description.sdp)
            logger.log(level: .info, message: "Android Modified Offer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.sharedCommunicationId)")
            try await self.rtcClient.setLocalDescription(description)
            sdp = try SessionDescription(fromRTC: description)
#else
            // Generate SDP offer using the new SDPHandler
            var description: WebRTC.RTCSessionDescription = try await generateSDPOffer(for: connection, hasAudio: true, hasVideo: hasVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: hasVideo,
                stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
            )
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Apple Platform Modified Offer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.sharedCommunicationId)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#endif
            
            logger.log(level: .info, message: "Successfully created offer for call: \(call.sharedCommunicationId)")
            var call = call
            call.metadata = try BinaryEncoder().encode(sdp)
            return call
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "SDP offer creation failed: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error during offer creation: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error during offer creation: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Offer creation failed: \(error.localizedDescription)")
        }
    }
    
    /// Creates an SDP answer for a call with proper error handling and validation
    /// - Parameter call: The call to create an answer for
    /// - Returns: Call with SDP in metadata
    /// - Throws: SDPHandlerError or RTCErrors if creation fails
    func createAnswer(call: Call) async throws -> Call {
        
        logger.log(level: .info, message: "Creating answer for call: \(call.sharedCommunicationId)")
        
        // Ensure peer-notifications consumer is running before setting descriptions.
        handleNotificationsStream()
        
        // Wait for peer connection to be ready.
        //
        // This is on the critical inbound-call path; 1s polling introduces visible lag in UI
        // transition and can delay remote track availability. Use a tighter polling interval
        // while keeping the same overall timeout budget (~10s).
        try await loop.run(200, sleep: Duration.milliseconds(50)) { [weak self] in
            guard let self else { return false }
            var canRun = true
            let state = await self.pcStateByConnectionId[call.sharedCommunicationId] ?? .none
            if state == .setRemote {
                canRun = false
            }
            return canRun
        }
        
        do {
            // Find or create connection
            var connection: RTCConnection
            if let foundConnection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection = foundConnection
                logger.log(level: .debug, message: "Found connection for call: \(call)")
            } else {
                logger.log(level: .error, message: "No connection found for call: \(call)")
                throw RTCErrors.connectionNotFound
            }
            
            
            var sdp: SessionDescription
#if os(Android)
            // Generate SDP answer using the new SDPHandler
            var description: RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android: generateSDPAnswer completed")
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Answer SDP:\n" + description.sdp)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: call.supportsVideo,
                stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
            )
            description = RTCSessionDescription(typeDescription: description.typeDescription, sdp: modified)
            
            // SKIP INSERT: android.util.Log.d("RTCClient", "Android Modified Answer SDP:\n" + description.sdp)
            logger.log(level: .info, message: "Android Modified Answer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.sharedCommunicationId)")
            try await self.rtcClient.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#elseif canImport(WebRTC)
            var description: WebRTC.RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: call.supportsVideo,
                stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
            )
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Apple Platform Modified Answer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.sharedCommunicationId)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#endif
            
            logger.log(level: .info, message: "Successfully created answer for call: \(call.sharedCommunicationId)")
            var callWithSDP = call
            let sdpData = try BinaryEncoder().encode(sdp)
            callWithSDP.metadata = sdpData
            return callWithSDP
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "SDP answer creation failed: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error during answer creation: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error during answer creation: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Answer creation failed: \(error.localizedDescription)")
        }
    }
    
    /// Sets the remote SDP for a call with proper error handling and validation
    /// - Parameters:
    ///   - sdp: The remote SDP to set
    ///   - call: The call to set the SDP for
    /// - Throws: SDPHandlerError or RTCErrors if setting fails
#if os(Android)
    func setRemote(
        sdp: RTCSessionDescription,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Setting remote SDP for call: \(call.sharedCommunicationId)")
        
        // Remote description can trigger negotiation/ICE events; ensure consumer is alive.
        handleNotificationsStream()
        
        do {
            // Find or create connection
            var currentConnection: RTCConnection
            if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                currentConnection = connection
                logger.log(level: .info, message: "Found connection for call: \(call.sharedCommunicationId)")
            } else {
                logger.log(level: .info, message: "Creating new connection for call: \(call.sharedCommunicationId)")
                // The peer connection now requires crypto identities. Build them using the existing
                // session helper, then fetch the created connection.
                try await createCryptoPeerConnection(with: call)
                guard let created = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
                    throw RTCErrors.connectionNotFound
                }
                currentConnection = created
            }
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(
                sdp: sdp.sdp,
                hasVideo: call.supportsVideo,
                stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
            )
            modifiedSdp = RTCSessionDescription(typeDescription: sdp.typeDescription, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: currentConnection)
            
            pcState = PeerConnectionState.setRemote
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.sharedCommunicationId)")
            
            // Process any queued incoming candidates that arrived before setRemote
            do {
                let consumer = inboundCandidateConsumer(for: call.sharedCommunicationId)
                try await processAllQueuedCandidates(connection: currentConnection, consumer: consumer)
            } catch {
                logger.log(level: .warning, message: "Error processing queued candidates: \(error.localizedDescription)")
            }
            
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "Failed to set remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error setting remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error setting remote SDP: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Failed to set remote SDP: \(error.localizedDescription)")
        }
    }
#endif
    
#if !os(Android)
    func setRemote(
        sdp: WebRTC.RTCSessionDescription,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Setting remote SDP for call: \(call.sharedCommunicationId)")
        
        // Remote description can trigger negotiation/ICE events; ensure consumer is alive.
        handleNotificationsStream()
        
        do {
            
            guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
                throw RTCErrors.invalidConfiguration("Connection must be created before setting remote SDP.")
            }
            
            logger.log(level: .debug, message: "Found connection for call: \(call.sharedCommunicationId)")
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(
                sdp: sdp.sdp,
                hasVideo: call.supportsVideo,
                stripSsrcLines: call.sharedCommunicationId.hasPrefix("#")
            )
            modifiedSdp = WebRTC.RTCSessionDescription(type: sdp.type, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: connection)
            
            pcState = PeerConnectionState.setRemote
            pcStateByConnectionId[call.sharedCommunicationId] = .setRemote
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.sharedCommunicationId)")
            
            // Process any queued incoming candidates that arrived before setRemote
            do {
                let consumer = inboundCandidateConsumer(for: call.sharedCommunicationId)
                try await processAllQueuedCandidates(connection: connection, consumer: consumer)
            } catch {
                logger.log(level: .warning, message: "Error processing queued candidates: \(error.localizedDescription)")
            }
            
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "Failed to set remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error setting remote SDP: \(error.localizedDescription)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error setting remote SDP: \(error)")
            await callState.transition(to: .failed(.inbound(call.supportsVideo ? .video : .voice), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw RTCErrors.mediaError("Failed to set remote SDP: \(error.localizedDescription)")
        }
    }
#endif
    
    func setRemote(
        candidate: IceCandidate,
        call: Call
    ) async throws {
        logger.log(level: .info, message: "Received ICE candidate with id: \(candidate.id) for call: \(call.sharedCommunicationId)")
        let consumer = inboundCandidateConsumer(for: call.sharedCommunicationId)
        await consumer.feedConsumer(candidate)
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
            logger.log(level: .warning, message: "No connection found for candidate with id: \(candidate.id), call: \(call.sharedCommunicationId)")
            return
        }
        let state = pcStateByConnectionId[call.sharedCommunicationId] ?? pcState
        logger.log(level: .info, message: "Current pcState: \(state), checking if ready to process candidates")
        if state == PeerConnectionState.setRemote {
            logger.log(level: .info, message: "Processing candidates for call: \(call.sharedCommunicationId)")
            try await processAllQueuedCandidates(connection: connection, consumer: consumer)
        } else {
            logger.log(level: .warning, message: "Not processing candidate yet - pcState is \(state), waiting for setRemote state")
        }
    }
    
    func processDataMessage(connectionId: String,
                            channelLabel: String,
                            data: Data) async throws {
        let message = RTCDataChannelMessage(
            connectionId: connectionId,
            channelLabel: channelLabel,
            data: data)
        
        if let handler = dataChannelMessageHandler {
            await handler(message)
            return
        }
        
        if let text = String(data: data, encoding: .utf8) {
            logger.log(level: .info, message: "Unhandled data channel message (label=\(channelLabel)) text=\(text)")
        } else {
            logger.log(level: .info, message: "Unhandled data channel message (label=\(channelLabel)) bytes=\(data.count)")
        }
    }
    
    //MARK: Private
    
    private func processCandidates(connection: RTCConnection, consumer: NeedleTailAsyncConsumer<IceCandidate>) async throws {
        // Skip-compatible approach: process candidates directly from the consumer
        let result = await consumer.next()
        switch result {
        case NTASequenceStateMachine.NextNTAResult.ready(let candidate):
            //we need to find if last id contained in deq
            let iceCandidate = candidate.item
#if canImport(WebRTC)
            let ice: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(
                sdp: iceCandidate.sdp,
                sdpMLineIndex: iceCandidate.sdpMLineIndex,
                sdpMid: iceCandidate.sdpMid
            )
            try await connection.peerConnection.add(ice)
#elseif os(Android)
            let ice: RTCIceCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
            try self.rtcClient.addIceCandidate(ice)
#endif
            lastId = iceCandidate.id
            logger.log(level: .info, message: "Added Ice Candidate\n Id: \(iceCandidate.id)")
        case NTASequenceStateMachine.NextNTAResult.consumed:
            //If we consume all candidates before we refeed we have a weird state
            notRunning = true
            return
        }
    }
    
    /// Processes all queued incoming ICE candidates
    /// This is called after setRemote to process any candidates that arrived early
    private func processAllQueuedCandidates(connection: RTCConnection, consumer: NeedleTailAsyncConsumer<IceCandidate>) async throws {
        var processedCount = 0
        while true {
            let result = await consumer.next()
            switch result {
            case NTASequenceStateMachine.NextNTAResult.ready(let candidate):
                let iceCandidate = candidate.item
#if canImport(WebRTC)
                let ice: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(
                    sdp: iceCandidate.sdp,
                    sdpMLineIndex: iceCandidate.sdpMLineIndex,
                    sdpMid: iceCandidate.sdpMid
                )
                try await connection.peerConnection.add(ice)
#elseif os(Android)
                let ice: RTCIceCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid ?? "")
                try self.rtcClient.addIceCandidate(ice)
#endif
                lastId = iceCandidate.id
                processedCount += 1
                logger.log(level: .info, message: "Processed queued Ice Candidate Id: \(iceCandidate.id)")
            case NTASequenceStateMachine.NextNTAResult.consumed:
                if processedCount > 0 {
                    logger.log(level: .info, message: "Processed \(processedCount) queued ICE candidate(s) after setRemote")
                }
                return
            }
        }
    }
    
    func resolveProperRecipient(call: Call) throws -> Call {
        var call = call
        guard let sessionParticipant else {
            throw RTCErrors.invalidConfiguration("Session Participant not set")
        }
        if call.sender.secretName == sessionParticipant.secretName {
            call.sender.deviceId = sessionParticipant.deviceId ?? ""
        } else {
            let copiedSender = call.sender
            guard let recipient = call.recipients.first else {
                throw RTCErrors.invalidConfiguration("Received offer without a recipient in call")
            }
            call.recipients = [copiedSender]
            call.sender = recipient
        }
        return call
    }
}
