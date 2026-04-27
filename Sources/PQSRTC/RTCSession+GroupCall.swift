//
//  RTCSession+GroupCall.swift
//  pqs-rtc
//
//  Created by Cole M on 1/5/26.
//

import Foundation
import DoubleRatchetKit
import BinaryCodable



extension RTCSession {

    /// Resolves the group call for an SFU identity. Group calls are stored by normalized ID (no "#").
    /// Pass any form (channel "#uuid" or UUID); lookup uses normalized key.
    func groupCall(forSfuIdentity sfuIdentity: String) -> RTCGroupCall? {
        groupCalls[sfuIdentity.normalizedConnectionId]
    }

    /// Public accessor for the ``RTCGroupCall`` associated with a conference/group room.
    public func groupCallForRoom(_ roomId: String) -> RTCGroupCall? {
        groupCall(forSfuIdentity: roomId)
    }

    /// Creates the room and room keys this is the entry point for group calls.
    /// Store and find by normalized ID (no "#"); transport layer reattaches "#" for IRC.
    public func groupCallNegotiation(
        sender: Call.Participant,
        participants: [Call.Participant],
        sfuRecipientId: String,
        supportsVideo: Bool = true
    ) async throws {
        let normalizedId = sfuRecipientId.normalizedConnectionId
        // Allow joining an SFU room even if the participant list is currently empty.
        let call = try Call(
            groupSharedCommunicationId: normalizedId,
            sender: sender,
            recipients: participants,
            supportsVideo: supportsVideo,
            isActive: true)
        try await groupCallNegotiation(call: call, sfuRecipientId: sfuRecipientId)
    }

    /// Starts SFU group-call registration while preserving the caller-supplied call identity.
    ///
    /// Use this when the app has a stable internal call UUID (`sharedCommunicationId`) that is
    /// distinct from the SFU wire route (`sfuRecipientId`, often a channel name). This keeps the
    /// ratchet/session identity on the UUID while routing SFU packets through the channel.
    public func groupCallNegotiation(
        call originalCall: Call,
        sfuRecipientId: String
    ) async throws {
        isGroupCall = true
        let normalizedId = sfuRecipientId.normalizedConnectionId
        let normalizedConnectionId = originalCall.sharedCommunicationId.normalizedConnectionId
        resetAttemptFlagsForNewCall(connectionId: normalizedConnectionId)
        var call = originalCall
        if call.channelWireId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            call.channelWireId = sfuRecipientId.ensureIRCChannel
        }
        
        let signalingLocalIdentity: ConnectionLocalIdentity
        if let foundSignalingLocalIdentity = try? await pcKeyManager.fetchCallKeyBundle() {
            signalingLocalIdentity = foundSignalingLocalIdentity
        } else {
            signalingLocalIdentity = try await pcKeyManager.generateSenderIdentity(
               connectionId: call.sharedCommunicationId,
               secretName: call.sender.secretName)
        }
        
        // For group calls, these props are used for SFU signaling ratchet remoteKeys.
        call.signalingIdentityProps = await signalingLocalIdentity.sessionIdentity.props(symmetricKey: signalingLocalIdentity.symmetricKey)
        guard call.signalingIdentityProps != nil else {
            throw EncryptionErrors.missingProps
        }

        // Create Group call with needed metadata (key by normalized ID).
        let group = createGroupCall(
            call: call,
            sfuRecipientId: normalizedId,
            localIdentity: signalingLocalIdentity)
        
        groupCalls[normalizedId] = group
        
        setMediaDelegate(group)
        try await group.join()
        
        // Transport uses IRC channel format (with "#").
        try await delegate?.negotiateGroupIdentity(
            call: call,
            sfuRecipientId: sfuRecipientId.ensureIRCChannel)
    }
    
    public func leave(sfuRecipientId: String, call: Call) async throws {
        let normalizedId = sfuRecipientId.normalizedConnectionId
        guard let group = groupCalls[normalizedId] else {
            throw RTCErrors.missingGroupCall
        }
        await group.leave()
        groupCalls.removeValue(forKey: normalizedId)
        await shutdown(with: call)
    }
    
    public func sendGroupCallOffer(_ call: Call) async throws -> Call {
        var call = call
        let offerKey = call.sharedCommunicationId.normalizedConnectionId
        guard !offerInFlightConnectionIds.contains(offerKey) else {
            logger.log(
                level: .warning,
                message: "SFU offer already in flight for \(offerKey); skipping duplicate renegotiation offer"
            )
            return call
        }
        offerInFlightConnectionIds.insert(offerKey)
        defer { offerInFlightConnectionIds.remove(offerKey) }

        let wireRoomId = call.resolvedChannelWireId ?? call.sharedCommunicationId
        
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId.normalizedConnectionId

        // Create the offer (sets local SDP, triggers ICE gathering).
        call = try await createOffer(call: call)
        
        // Encrypt and send; roomId stored normalized, "#" reattached at transport.
        let offerPlaintext = try BinaryEncoder().encode(call)
        let writeTask = WriteTask(
            data: offerPlaintext,
            roomId: wireRoomId,
            flag: .offer,
            call: call)
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)

        do {
            try await startSendingCandidates(call: call)
        } catch {
            logger.log(level: .warning, message: "Failed to start sending SFU ICE candidates after offer (will continue buffering): \(error)")
        }
        
        return call
    }
    
    public func createSFUIdentity(
        sfuRecipientId: String,
        call: Call
    ) async throws {
        // Identity props must be sent back from the SFU Server's group identity.
        guard let props = call.signalingIdentityProps else { throw EncryptionErrors.missingProps }
        let connId = call.sharedCommunicationId.normalizedConnectionId

        // Signaling ratchet (SDP/ICE over SFU): `pcKeyManager` + `TaskProcessor`.
        do {
            _ = try await pcKeyManager.fetchConnectionIdentity(connection: connId)
        } catch {
            _ = try await pcKeyManager.createRecipientIdentity(
                connectionId: connId,
                props: props)
        }

        // Media / FrameCryptor ratchet: `keyManager` + `ratchetManager`.
        //
        // Swift SFU's registration reply intentionally carries **signaling** props only
        // (`PQSGroupCallAdapter` sets `frameIdentityProps = nil`). There is no separate
        // SFU payload for frame identities at registration time, but `beginGroupCallMediaAfterSfuRegistrationIfNeeded`
        // still runs `createPeerConnection` → `setMessageKey` → `deriveMessageKey`, which requires a
        // **recipient** `ConnectionSessionIdentity` in `keyManager` keyed by the room id.
        //
        // The server-negotiated `UnwrappedProps` are the SFU/room peer keys; we install them into
        // **both** stores so each Double Ratchet (separate `KeyManager` actors, separate DR state)
        // can initialize. Per-peer frame refinements continue to flow through `receiveCiphertext` /
        // `call_cipher` as before.
        do {
            _ = try await keyManager.fetchConnectionIdentity(connection: connId)
        } catch {
            _ = try await keyManager.createRecipientIdentity(
                connectionId: connId,
                props: props)
        }
    }

    /// After SFU `.registration` completes (``createSFUIdentity``), creates the SFU peer connection
    /// and sends the initial encrypted offer when a local ``RTCGroupCall`` exists.
    ///
    /// No-op if there is no registered group for `sfuRecipientId`, or if a connection already exists
    /// (idempotent for duplicate registrations).
    public func beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId: String) async throws {
        let normalizedLookup = sfuRecipientId.normalizedConnectionId
        guard let group = groupCall(forSfuIdentity: normalizedLookup) else {
            logger.log(
                level: .warning,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: no RTCGroupCall for sfuRecipientId=\(sfuRecipientId) normalized=\(normalizedLookup) (registration reply may not have arrived, or room id does not match groupCallNegotiation)")
            return
        }

        var mediaCall = await group.currentCall
        let connId = mediaCall.sharedCommunicationId.normalizedConnectionId

        // Registration + identity provisioning can race app-layer answer flow.
        // Do not fail the call action when identities are still settling; callers
        // will invoke this entrypoint again on registration/call_answered retries.
        do {
            _ = try await keyManager.fetchConnectionIdentity(connection: connId)
            _ = try await pcKeyManager.fetchConnectionIdentity(connection: connId)
        } catch let error as RTCErrors {
            if case .invalidConfiguration(let message) = error {
                let lower = message.lowercased()
                if lower.contains("missing connection identity") || lower.contains("missing local connection identity") {
                    logger.log(
                        level: .warning,
                        message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: identities not ready yet for room=\(normalizedLookup), delaying media bootstrap (\(message))")
                    return
                }
            }
            throw error
        }

        guard await !hasConnection(id: mediaCall.sharedCommunicationId) else {
            logger.log(
                level: .debug,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: connection already exists for \(mediaCall.sharedCommunicationId)")
            return
        }

        logger.log(
            level: .info,
            message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: creating SFU PeerConnection and offer for room=\(normalizedLookup)")

        let frameLocalIdentity: ConnectionLocalIdentity
        if let existingIdentity = try? await keyManager.fetchCallKeyBundle() {
            frameLocalIdentity = existingIdentity
        } else {
            frameLocalIdentity = try await keyManager.generateSenderIdentity(
                connectionId: mediaCall.sharedCommunicationId,
                secretName: mediaCall.sender.secretName)
        }

        if mediaCall.frameIdentityProps == nil {
            guard let frameProps = await frameLocalIdentity.sessionIdentity.props(symmetricKey: frameLocalIdentity.symmetricKey) else {
                throw EncryptionErrors.missingProps
            }
            mediaCall.frameIdentityProps = frameProps
        }

        let recipientRoute = normalizedLookup
        // Match ``RTCConnectionManager`` / ``teardownConnectionIdKey`` (strip `#` + lowercase) so
        // post-cipher bookkeeping survives UUID hex casing differences across call objects.
        let bootstrapKey = teardownConnectionIdKey(mediaCall.sharedCommunicationId)
        pendingInitialSfuGroupOfferConnectionIds.insert(bootstrapKey)
        defer { pendingInitialSfuGroupOfferConnectionIds.remove(bootstrapKey) }

#if os(iOS)
        // No CallKit `didActivate:` for channel/conference SFU — align WebRTC with `AVAudioSession`
        // before `createPeerConnection` (see `prepareNonCallKitGroupCallAudio`).
        do {
            try await self.prepareNonCallKitGroupCallAudio(supportsVideo: mediaCall.supportsVideo)
        } catch {
            self.logger.log(
                level: .error,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: non-CallKit audio prep failed before SFU PeerConnection: \(error)")
            throw error
        }
#endif

        // Default `willFinishNegotiation: false` so `setMessageKey` runs at PC creation, matching
        // the b368e83-era behavior. The per-pair Double Ratchet then derives FrameCryptor keys
        // for every entry in `call.recipients`, mirroring how 1:1 direct works today.
        do {
            _ = try await createPeerConnection(
                with: mediaCall,
                sender: mediaCall.sender.secretName,
                recipient: recipientRoute,
                localIdentity: frameLocalIdentity)
        } catch let error as RTCErrors {
            if case .invalidConfiguration(let message) = error {
                let lower = message.lowercased()
                if lower.contains("missing connection identity") || lower.contains("missing local connection identity") {
                    logger.log(
                        level: .warning,
                        message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: createPeerConnection deferred for room=\(normalizedLookup) (\(message))")
                    return
                }
            }
            throw error
        }

        let updatedCall = try await sendGroupCallOffer(mediaCall)
        initialSfuGroupMediaOfferSentConnectionIds.insert(bootstrapKey)
        await group.applyUpdatedCallForNegotiation(updatedCall)
    }
    
    /// Starts a group call by creating a single PeerConnection intended to connect to an SFU.
    ///
    /// Prefer using ``RTCGroupCall/join()`` unless you are building your own group facade.
    ///
    /// Frame-level E2EE for SFU group calls is driven by the same per-pair Double Ratchet path
    /// used for 1:1 direct: `setMessageKey` runs at PC creation, ciphertext fans out to every
    /// participant in `call.recipients`, and each peer's `setReceivingMessageKey` provisions the
    /// per-participant frame key on its side. Conference rooms (which carry an empty recipients
    /// list) opt out of this path and use the conference frame-key exchange instead.
    func startGroupCall(call: Call, sfuRecipientId: String) async throws -> Call {
        var call = call
        
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId.normalizedConnectionId

        // Create the offer (sets local SDP, triggers ICE gathering).
        call = try await createOffer(call: call)
        
        // Encrypt and send; roomId normalized, "#" reattached at transport.
        let offerPlaintext = try BinaryEncoder().encode(call)
        let writeTask = WriteTask(
            data: offerPlaintext,
            roomId: sfuRecipientId.normalizedConnectionId,
            flag: .offer,
            call: call)
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)
        
        // Enable ICE trickle for SFU calls.
        // Without this, candidates remain buffered and ICE can stall in `checking`.
        do {
            try await startSendingCandidates(call: call)
        } catch {
            logger.log(level: .warning, message: "Failed to start sending SFU ICE candidates after offer (will continue buffering): \(error)")
        }
        
        return call
    }
    
    
    /// Single entrypoint to apply decoded control-plane messages.
    ///
    /// This is the intended transport-agnostic surface: your app owns the networking and
    /// calls into this API as messages arrive.
    ///
    /// Your networking layer should decode inbound SFU signaling, roster updates, and key
    /// distribution messages into ``ControlMessage`` and call this method.
    public func handleControlMessage(_ message: RTCGroupCall.ControlMessage) async throws {
        switch message {
        case .sfuAnswer(let packet):
            try await handleSfuAnswer(packet)
        case .sfuCandidate(let packet):
            try await handleSfuCandidate(packet)
        case .sfuOffer(let packet):
            try await handleSfuOffer(packet)
        case .participants(let packet):
            try await handleParticpants(packet)
        case .participantDemuxId(let packet):
            try await handleParticpant(packet)
        }
    }
    
    // MARK: - Signaling ingress (SFU)
    
    /// Applies an inbound SFU SDP answer to the underlying PeerConnection.
    func handleSfuAnswer(_ packet: RatchetMessagePacket) async throws {
        
        // Get call from groupCalls or connectionManager
        var call: Call
        if let group = groupCall(forSfuIdentity: packet.sfuIdentity) {
            call = await group.currentCall
        } else if let connection = await connectionManager.findConnection(with: packet.sfuIdentity.normalizedConnectionId) {
            call = connection.call
        } else {
            // Create placeholder (store by normalized ID).
            call = try Call(
                sharedCommunicationId: packet.sfuIdentity.normalizedConnectionId,
                sender: Call.Participant(secretName: "", nickname: "", deviceId: UUID().uuidString),
                recipients: [Call.Participant(secretName: "placeholder", nickname: "", deviceId: UUID().uuidString)],
                supportsVideo: true,
                isActive: true)
        }
        
        // TaskProcessor will handle recipient initialization
        let streamTask = StreamTask(
            senderSecretName: "",
            senderDeviceId: nil,
            packet: packet,
            call: call)
        let encryptableTask = EncryptableTask(task: .streamMessage(streamTask))
        try await taskProcessor.feedTask(task: encryptableTask)
    }
    
    /// Applies an inbound SFU renegotiation offer (e.g. when a new peer joins) and feeds to TaskProcessor for decrypt then handle.
    func handleSfuOffer(_ packet: RatchetMessagePacket) async throws {
        var call: Call
        if let group = groupCall(forSfuIdentity: packet.sfuIdentity) {
            call = await group.currentCall
        } else if let connection = await connectionManager.findConnection(with: packet.sfuIdentity.normalizedConnectionId) {
            call = connection.call
        } else {
            call = try Call(
                groupSharedCommunicationId: packet.sfuIdentity.normalizedConnectionId,
                sender: Call.Participant(secretName: "", nickname: "", deviceId: UUID().uuidString),
                recipients: [],
                supportsVideo: true,
                isActive: true)
        }
        let streamTask = StreamTask(
            senderSecretName: "",
            senderDeviceId: nil,
            packet: packet,
            call: call)
        let encryptableTask = EncryptableTask(task: .streamMessage(streamTask))
        try await taskProcessor.feedTask(task: encryptableTask)
    }
    
    /// Applies an inbound SFU ICE candidate to the underlying PeerConnection.
    func handleSfuCandidate(_ packet: RatchetMessagePacket) async throws {
        
        // Get call from groupCalls or connectionManager
        var call: Call
        if let group = groupCall(forSfuIdentity: packet.sfuIdentity) {
            call = await group.currentCall
        } else if let connection = await connectionManager.findConnection(with: packet.sfuIdentity.normalizedConnectionId) {
            call = connection.call
        } else {
            call = try Call(
                groupSharedCommunicationId: packet.sfuIdentity.normalizedConnectionId,
                sender: Call.Participant(secretName: "", nickname: "", deviceId: UUID().uuidString),
                recipients: [],
                supportsVideo: true,
                isActive: true)
        }
        
        // TaskProcessor will handle recipient initialization
        let streamTask = StreamTask(
            senderSecretName: "",
            senderDeviceId: nil,
            packet: packet,
            call: call)
        let encryptableTask = EncryptableTask(task: .streamMessage(streamTask))
        try await taskProcessor.feedTask(task: encryptableTask)
    }
    
    // MARK: Roster
    func handleParticpants(_ packet: RatchetMessagePacket) async throws {
        // Get call from groupCalls
        guard let group = groupCall(forSfuIdentity: packet.sfuIdentity) else {
            throw RTCErrors.missingGroupCall
        }
        let call = await group.currentCall
        
        // TaskProcessor will handle recipient initialization
        let streamTask = StreamTask(
            senderSecretName: "",
            senderDeviceId: nil,
            packet: packet,
            call: call)
        let encryptableTask = EncryptableTask(task: .streamMessage(streamTask))
        try await taskProcessor.feedTask(task: encryptableTask)
    }
    
    func handleParticpant(_ packet: RatchetMessagePacket) async throws {
        // Get call from groupCalls
        guard let group = groupCall(forSfuIdentity: packet.sfuIdentity) else {
            throw RTCErrors.missingGroupCall
        }
        let call = await group.currentCall
        
        // TaskProcessor will handle recipient initialization
        let streamTask = StreamTask(
            senderSecretName: "",
            senderDeviceId: nil,
            packet: packet,
            call: call)
        let encryptableTask = EncryptableTask(task: .streamMessage(streamTask))
        try await taskProcessor.feedTask(task: encryptableTask)
    }
    
    // MARK: - TaskProcessor Helpers
    
    /// Sends an encrypted packet via transport (used by TaskProcessor).
    func sendEncryptedPacket(packet: RatchetMessagePacket, call: Call) async throws {
        if isGroupCall {
            try await requireTransport().sendSfuMessage(packet, call: call)
        } else {
            guard let recipient = call.recipients.first else {
                throw RTCErrors.invalidConfiguration("Recipient not set for one-on-one call")
            }
            try await requireTransport().sendOneToOneMessage(packet, recipient: recipient)
        }
    }
    
    /// Handles a decrypted packet (used by TaskProcessor).
    func handleDecryptedPacket(plaintext: Data, packet: RatchetMessagePacket, call: Call) async throws {
        switch packet.flag {
        case .answer:
            let call = try BinaryDecoder().decode(Call.self, from: plaintext)
            guard let metadata = call.metadata else {
                throw EncryptionErrors.missingMetadata
            }
            let sdp = try BinaryDecoder().decode(SessionDescription.self, from: metadata)
            try await handleAnswer(call: call, sdp: sdp)
        case .candidate:
            let call = try BinaryDecoder().decode(Call.self, from: plaintext)
            guard let metadata = call.metadata else {
                throw EncryptionErrors.missingMetadata
            }
            let candidate = try BinaryDecoder().decode(IceCandidate.self, from: metadata)
            try await handleCandidate(call: call, candidate: candidate)
        case .offer:
            // Renegotiation offer from SFU: set remote offer, create answer, send it back.
            let decodedCall = try BinaryDecoder().decode(Call.self, from: plaintext)
            guard let metadata = decodedCall.metadata else {
                throw EncryptionErrors.missingMetadata
            }
            let sdp = try BinaryDecoder().decode(SessionDescription.self, from: metadata)
            guard let group = groupCall(forSfuIdentity: packet.sfuIdentity) else {
                throw RTCErrors.missingGroupCall
            }
            let call = await group.currentCall
            let processedCall = try await handleRenegotiationOffer(sdp: sdp, call: call)
            let answerPlaintext = try BinaryEncoder().encode(processedCall)
            let writeTask = WriteTask(
                data: answerPlaintext,
                roomId: (call.resolvedChannelWireId ?? call.sharedCommunicationId).normalizedConnectionId,
                flag: .answer,
                call: processedCall)
            try await taskProcessor.feedTask(task: EncryptableTask(task: .writeMessage(writeTask)))
            logger.log(level: .info, message: "Handled SFU renegotiation offer for group call: \(packet.sfuIdentity)")
        case .participants:
            let participants: [RTCGroupCall.Participant] = try BinaryDecoder().decode([RTCGroupCall.Participant].self, from: plaintext)
            guard let group = groupCall(forSfuIdentity: packet.sfuIdentity) else {
                throw RTCErrors.missingGroupCall
            }
            await group.updateParticipants(participants)
        case .participantDemuxId:
            let participant: RTCGroupCall.Participant = try BinaryDecoder().decode(RTCGroupCall.Participant.self, from: plaintext)
            guard let group = groupCall(forSfuIdentity: packet.sfuIdentity) else {
                throw RTCErrors.missingGroupCall
            }
            await group.setDemuxId(participant.demuxId, for: participant.id)
        case .handshakeComplete:
            // Post-cipher SFU identity refresh (see ``finishCryptoSessionCreation``): same SDP
            // bytes + updated `signalingIdentityProps` / `frameIdentityProps`. Not an SDP
            // negotiation — merge into the stored call + key material without
            // `setRemoteDescription` / `createAnswer`.
            let decoded = try BinaryDecoder().decode(Call.self, from: plaintext)
            let resolved = try resolveProperRecipient(call: decoded)
            try await applyInboundSfuPostCipherHandshakeMerge(resolved: resolved, sfuIdentity: packet.sfuIdentity)
            logger.log(
                level: .info,
                message: "Applied inbound SFU post-cipher identity handshake for room=\(packet.sfuIdentity)"
            )
        }
    }

}
