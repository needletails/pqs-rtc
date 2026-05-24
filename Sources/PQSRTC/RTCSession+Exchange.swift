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
    /// Refreshes identity props on an outbound signaling payload so locally generated
    /// offers/answers never leak stale remote frame/signaling identities from a merged call.
    ///
    /// This is especially important for 1:1-over-SFU renegotiation, where the answering side can
    /// reuse a call object that still carries the remote peer's `frameIdentityProps`. Sending that
    /// stale payload causes the other client to provision the wrong media ratchet identity and
    /// results in "remote track attached but zero frames rendered" failures.
    private func refreshLocalIdentityPropsForOutboundSignaling(_ call: Call) async throws -> Call {
        var call = call
        let frameBundle = try await keyManager.fetchCallKeyBundle()
        let signalingBundle = try await pcKeyManager.fetchCallKeyBundle()
        call.frameIdentityProps = await frameBundle.sessionIdentity.props(symmetricKey: frameBundle.symmetricKey)
        call.signalingIdentityProps = await signalingBundle.sessionIdentity.props(symmetricKey: signalingBundle.symmetricKey)
        return call
    }

    /// Builds the outbound encrypted `.offer` payload after cipher negotiation **without** calling
    /// ``createOffer``.
    ///
    /// SFU group media already sent an offer via ``sendGroupCallOffer``; duplicating
    /// ``createOffer`` after `call_cipher` breaks WebRTC signaling. Peers still need a follow-up
    /// ratchet frame carrying refreshed ``Call/frameIdentityProps`` / ``Call/signalingIdentityProps``
    /// (see ``refreshLocalIdentityPropsForOutboundSignaling``) or remote media stays undecryptable.
    ///
    /// This copies SDP bytes from the peer connection’s current local description (or the last group
    /// `Call.metadata` on Android when needed) and applies the same signaling-identity merge as the
    /// post-cipher offer path.
    internal func buildPostCipherSfuGroupOfferPayloadPreservingLocalSdp(call: Call) async throws -> Call {
        var updated = try await refreshLocalIdentityPropsForOutboundSignaling(call)

#if !os(Android)
        if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId),
           let local = connection.peerConnection.localDescription {
            let sdp = try SessionDescription(fromRTC: local)
            updated.metadata = try BinaryEncoder().encode(sdp)
        }
#endif
        if updated.metadata?.isEmpty != false {
            let norm = call.sharedCommunicationId.normalizedConnectionId
            if let group = groupCall(forSfuIdentity: norm) {
                let stored = await group.currentCall
                if let m = stored.metadata, !m.isEmpty {
                    updated.metadata = m
                }
            }
        }

        guard let meta = updated.metadata, !meta.isEmpty else {
            throw RTCErrors.invalidConfiguration("Missing SDP metadata for SFU post-cipher offer refresh")
        }

        let keyBundle = try await pcKeyManager.fetchCallKeyBundle()
        guard let localProps = await keyBundle.sessionIdentity.props(symmetricKey: keyBundle.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local Props are missing")
        }
        updated.signalingIdentityProps = localProps
        return updated
    }

    /// Merges a decrypted post-cipher ``Call`` from ``PacketFlag.handshakeComplete`` (see
    /// ``finishCryptoSessionCreation``) into the active SFU group/connection without touching SDP.
    func applyInboundSfuPostCipherHandshakeMerge(resolved: Call, sfuIdentity: String) async throws {
        let normRoom = sfuIdentity.normalizedConnectionId
        guard let group = groupCall(forSfuIdentity: normRoom) else {
            throw RTCErrors.missingGroupCall
        }
        await group.applyUpdatedCallForNegotiation(resolved)
        updateFallbackLatestCall(resolved)
        if var connection = await connectionManager.findConnection(with: resolved.sharedCommunicationId) {
            connection.call = resolved
            await connectionManager.updateConnection(id: connection.id, with: connection)
        }
    }

    //MARK: Public

    public func handleHandshakeCompleted(_ call: Call) async throws {
        let call = try resolveProperRecipient(call: call)
        try await startSendingCandidates(call: call)
        if !handshakeComplete {
            setHandshakeComplete(true)
            
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
        let modified = await modifySDP(
            sdp: sdp.sdp,
            hasVideo: call.supportsVideo,
            stripSsrcLines: false)
        
#if os(Android)
        try await setRemote(
            sdp: RTCSessionDescription(
                typeDescription: "OFFER",
                sdp: modified),
            call: call)
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(
                                    type: sdp.type.rtcSdpType,
                                    sdp: modified),
                            call: call)
#endif
        
        
        let processedCall = try await createAnswer(call: call)
        
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
        // Inbound answerer path can run after CallKit activation already configured manual audio.
        // Re-applying external-audio wiring during SDP handling can race AURemoteIO startup and
        // leave outbound audio at zero while video continues to flow.
        if !audioSession.useManualAudio {
            try setExternalAudioSession()
        } else {
            logger.log(level: .debug, message: "Skipping redundant setExternalAudioSession in handleOffer; manual audio already enabled")
        }
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
            stripSsrcLines: false)
#if os(Android)
        try await setRemote(
            sdp: RTCSessionDescription(
                typeDescription: "OFFER",
                sdp: modified),
            call: call)
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(type: sdp.type.rtcSdpType, sdp: modified),
                            call: call)
#endif
        let answered = try await createAnswer(call: call)
#if canImport(WebRTC) && !os(Android)
        await rebindInboundRemoteVideoAfterSfuRenegotiationIfNeeded(call: answered)
#endif
        return answered
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
            stripSsrcLines: false)
        
#if os(Android)
        try await setRemote(
            sdp: RTCSessionDescription(
                typeDescription: "ANSWER",
                sdp: modified),
            call: call)
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(type: sdp.type.rtcSdpType, sdp: modified),
                            call: call)
#endif
        if var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
            connection.call = call
            await connectionManager.updateConnection(id: call.sharedCommunicationId, with: connection)
        }
        updateFallbackLatestCall(call)
        armRelayFallbackTimerIfNeeded(for: call)
        
        if !handshakeComplete {
            // Restored from b368e83: drive the .handshakeComplete WriteTask for every addressable
            // room (1:1 direct, 1:1 over SFU, and SFU group). For 1:1 media this also completes
            // the pairwise media-ratchet flow. For channel/conference group media, frame keys are
            // app-injected per sender; this packet remains signaling/readiness state, not group
            // media-key derivation.
            //
            // SFU conference rooms can legitimately carry an empty recipients list at this point
            // (their media keys arrive via the app-level group sender-key exchange),
            // so for them we just set handshake complete and start sending ICE candidates instead
            // of throwing.
            let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: call)
            let normId = teardownConnectionIdKey(call.sharedCommunicationId)
            if Self.shouldDeferOneToOneSfuHandshakeComplete(
                isOneToOneSfuRoom: isOneToOneSfuRoom,
                frameEncryptionEnabled: enableEncryption,
                receiveKeyReady: oneToOneSfuReceiveKeyReadyConnectionIds.contains(normId)
            ) {
                logger.log(
                    level: .info,
                    message: "Deferring 1:1 SFU handshakeComplete until call_cipher receive key is installed connId=\(call.sharedCommunicationId)")
            } else if let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
                call: call,
                sessionParticipant: sessionParticipant
            ) {
                if isOneToOneSfuRoom {
                    if !oneToOneSfuPostCipherHandshakeSentConnectionIds.contains(normId) {
                        let plaintext = try BinaryEncoder().encode(prepared)
                        let writeTask = WriteTask(
                            data: plaintext,
                            roomId: prepared.sharedCommunicationId.normalizedConnectionId,
                            flag: .handshakeComplete,
                            call: prepared)
                        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
                        try await taskProcessor.feedTask(task: encryptableTask)
                        oneToOneSfuPostCipherHandshakeSentConnectionIds.insert(normId)
                    }
                } else {
                    let plaintext = try BinaryEncoder().encode(prepared)
                    let writeTask = WriteTask(
                        data: plaintext,
                        roomId: prepared.sharedCommunicationId.normalizedConnectionId,
                        flag: .handshakeComplete,
                        call: prepared)
                    let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
                    try await taskProcessor.feedTask(task: encryptableTask)
                }
            } else {
                logger.log(
                    level: .info,
                    message: "handleAnswer: empty recipients (likely SFU conference); skipping .handshakeComplete WriteTask")
            }
            if !isOneToOneSfuRoom || !enableEncryption || oneToOneSfuReceiveKeyReadyConnectionIds.contains(normId) {
                setHandshakeComplete(true)
            }
        }
        try await startSendingCandidates(call: call)
    }

    static func shouldDeferOneToOneSfuHandshakeComplete(
        isOneToOneSfuRoom: Bool,
        frameEncryptionEnabled: Bool,
        receiveKeyReady: Bool
    ) -> Bool {
        isOneToOneSfuRoom && frameEncryptionEnabled && !receiveKeyReady
    }

    /// Pure helper used by ``handleAnswer`` (and exercised in tests) to decide whether the
    /// `.handshakeComplete` `WriteTask` should be fanned out for a given inbound answer, and to
    /// produce the swapped `Call` that goes into the task.
    ///
    /// Returns `nil` when the call has no addressable recipient or no resolved session
    /// participant (e.g. SFU conference rooms whose key distribution runs out-of-band). Returns
    /// the prepared `Call` otherwise — for 1:1 direct, 1:1-over-SFU, and SFU group rooms.
    ///
    /// - Important: This must not be limited to non-SFU rooms. Restricting it (as the
    ///   `isSfuGroupRoom` short-circuit in commit `57b97ff` did) breaks the per-pair Double
    ///   Ratchet handshake for SFU calls and surfaces as `FrameCryptor missingKey`.
    static func prepareHandshakeCompleteCallForFanout(
        call: Call,
        sessionParticipant: Call.Participant?
    ) -> Call? {
        guard let firstRecipient = call.recipients.first,
              let sessionParticipant
        else { return nil }
        var prepared = call
        var recipient = firstRecipient
        if recipient.secretName == sessionParticipant.secretName {
            recipient.deviceId = sessionParticipant.deviceId
            let copiedSender = prepared.sender
            prepared.recipients = [copiedSender]
            prepared.sender = recipient
        }
        return prepared
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
        let connKey = call.sharedCommunicationId.normalizedConnectionId
        guard await connectionManager.findConnection(with: call.sharedCommunicationId) != nil else { return }
        if let buffered = iceDequeByConnectionId[connKey], !buffered.isEmpty {
            for item in buffered {
                try await sendEncryptedSfuCandidateFromDeque(item, call: call)
            }
            iceDequeByConnectionId[connKey] = nil
        }
        readyForCandidatesByConnectionId[connKey] = true
        updateFallbackLatestCall(call)
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
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: hasVideo,
                // Keep local sender SSRC lines in locally-applied SDP.
                // Stripping them here can prevent RTP sender streams from activating
                // on some WebRTC/SFU combinations (symptom: ICE+DTLS connected, but
                // outbound audio/video packets remain flat at zero).
                stripSsrcLines: false,
                vp8OnlyVideo: connection.id.isGroupCall)
            
            description = RTCSessionDescription(typeDescription: description.typeDescription, sdp: modified)
            
            logger.log(level: .info, message: "Android Modified Offer SDP summary connection=\(connection.id): \(RTCSdpDiagnostics.summary(description.sdp))")

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
                // Keep local sender SSRC lines in locally-applied SDP.
                // Stripping them here can prevent RTP sender streams from activating
                // on some WebRTC/SFU combinations (symptom: ICE+DTLS connected, but
                // outbound audio/video packets remain flat at zero).
                stripSsrcLines: false,
                vp8OnlyVideo: connection.id.isGroupCall)
            
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Apple Platform Modified Offer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP offer for call: \(call.sharedCommunicationId)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#endif
            
            logger.log(level: .info, message: "Successfully created offer for call: \(call.sharedCommunicationId)")
            var call = try await refreshLocalIdentityPropsForOutboundSignaling(call)
            call.metadata = try BinaryEncoder().encode(sdp)
            return call
            
        } catch is CancellationError {
            // Do not treat cooperative cancellation as a call failure — it commonly occurs during
            // ICE relay fallback (recreate PC) or task hierarchy teardown; finishing here leaves
            // users with `CallState.failed` + `CancellationError` spuriously.
            throw CancellationError()
        } catch let error as SDPHandlerError {
            logger.log(level: .error, message: "SDP offer creation failed: \(error.localizedDescription)")
            await callState.transition(to: .failed(inferredCallDirection(for: call), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "RTC error during offer creation: \(error.localizedDescription)")
            await callState.transition(to: .failed(inferredCallDirection(for: call), call, error.localizedDescription))
            await finishEndConnection(currentCall: call)
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error during offer creation: \(error)")
            await callState.transition(to: .failed(inferredCallDirection(for: call), call, error.localizedDescription))
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
            let stateKey = call.sharedCommunicationId.normalizedConnectionId
            let state = await self.pcStateByConnectionId[stateKey] ?? .none
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
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: call.supportsVideo,
                // Keep local sender SSRC lines in locally-applied SDP.
                // Stripping them here can prevent RTP sender streams from activating
                // on some WebRTC/SFU combinations (symptom: ICE+DTLS connected, but
                // outbound audio/video packets remain flat at zero).
                stripSsrcLines: false,
                vp8OnlyVideo: connection.id.isGroupCall)
            description = RTCSessionDescription(typeDescription: description.typeDescription, sdp: modified)
            
            logger.log(level: .info, message: "Android Modified Answer SDP summary connection=\(connection.id): \(RTCSdpDiagnostics.summary(description.sdp))")

            logger.log(level: .info, message: "Generated SDP answer for call: \(call.sharedCommunicationId)")
            try await self.rtcClient.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#elseif canImport(WebRTC)
            var description: WebRTC.RTCSessionDescription = try await generateSDPAnswer(for: connection, hasAudio: true, hasVideo: call.supportsVideo)
            
            // Modify SDP for specific requirements
            let modified = await modifySDP(
                sdp: description.sdp,
                hasVideo: call.supportsVideo,
                // Keep local sender SSRC lines in locally-applied SDP.
                // Stripping them here can prevent RTP sender streams from activating
                // on some WebRTC/SFU combinations (symptom: ICE+DTLS connected, but
                // outbound audio/video packets remain flat at zero).
                stripSsrcLines: false,
                vp8OnlyVideo: connection.id.isGroupCall)
            
            description = WebRTC.RTCSessionDescription(type: description.type, sdp: modified)
            
            logger.log(level: .info, message: "Apple Platform Modified Answer SDP:\n\(description.sdp)")
            
            logger.log(level: .info, message: "Generated SDP answer for call: \(call.sharedCommunicationId)")
            // Set local description
            try await connection.peerConnection.setLocalDescription(description)
            
            sdp = try SessionDescription(fromRTC: description)
#endif
            
            logger.log(level: .info, message: "Successfully created answer for call: \(call.sharedCommunicationId)")
            var callWithSDP = try await refreshLocalIdentityPropsForOutboundSignaling(call)
            let sdpData = try BinaryEncoder().encode(sdp)
            callWithSDP.metadata = sdpData
            return callWithSDP
            
        } catch is CancellationError {
            throw CancellationError()
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
            
            guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
                throw RTCErrors.invalidConfiguration("Connection must be created before setting remote SDP.")
            }
            
            logger.log(level: .debug, message: "Found connection for call: \(call.sharedCommunicationId)")
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(
                sdp: sdp.sdp,
                hasVideo: call.supportsVideo,
                stripSsrcLines: false)
            modifiedSdp = RTCSessionDescription(typeDescription: sdp.typeDescription, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: connection)
            
            let stateKey = call.sharedCommunicationId.normalizedConnectionId
            pcState = PeerConnectionState.setRemote
            pcStateByConnectionId[stateKey] = .setRemote
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.sharedCommunicationId)")
            
            // Process any queued incoming candidates that arrived before setRemote
            do {
                let consumer = inboundCandidateConsumer(for: stateKey)
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
            
            // Guard against stale answers from duplicate offer/answer cycles.
            // When audio and video tracks are added in quick succession,
            // peerConnectionShouldNegotiate can fire twice, producing two offers.
            // The first answer moves signaling back to stable; the second answer
            // would crash WebRTC if we tried to apply it.
            if sdp.type == .answer && connection.peerConnection.signalingState == .stable {
                logger.log(level: .warning, message: "Dropping stale SDP answer for \(call.sharedCommunicationId): signaling state is already stable")
                return
            }
            
            logger.log(level: .debug, message: "Found connection for call: \(call.sharedCommunicationId)")
            
            // Modify SDP for specific requirements
            var modifiedSdp = sdp
            let modified = await modifySDP(
                sdp: sdp.sdp,
                hasVideo: call.supportsVideo,
                stripSsrcLines: false)
            modifiedSdp = WebRTC.RTCSessionDescription(type: sdp.type, sdp: modified)
            
            // Set remote SDP using the new SDPHandler
            try await setRemoteSDP(modifiedSdp, for: connection)
            
            let stateKey = call.sharedCommunicationId.normalizedConnectionId
            pcState = PeerConnectionState.setRemote
            pcStateByConnectionId[stateKey] = .setRemote
            logger.log(level: .info, message: "Successfully set remote SDP for call: \(call.sharedCommunicationId)")
            
            // Process any queued incoming candidates that arrived before setRemote
            do {
                let consumer = inboundCandidateConsumer(for: stateKey)
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
        let stateKey = call.sharedCommunicationId.normalizedConnectionId
        let consumer = inboundCandidateConsumer(for: stateKey)
        await consumer.feedConsumer(candidate)
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
            logger.log(level: .warning, message: "No connection found for candidate with id: \(candidate.id), call: \(call.sharedCommunicationId)")
            return
        }
        let state = pcStateByConnectionId[stateKey] ?? pcState
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
            call.sender.deviceId = sessionParticipant.deviceId
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
