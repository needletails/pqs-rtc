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
    private func requireSfuSignalingProps(from call: Call) throws -> SessionIdentity.UnwrappedProps {
        guard let props = call.signalingIdentityProps else { throw EncryptionErrors.missingProps }
        return props
    }
    
    /// Ensures the SFU (group-call) sender ratchet is initialized before any `ratchetEncrypt`.
    ///
    /// This is safe to call multiple times; the underlying Double Ratchet manager will reuse
    /// existing state for the same session id.
    func ensureSfuSenderInitialization(call: Call, sfuRecipientId: String) async throws -> ConnectionSessionIdentity {
        guard let group = groupCalls[sfuRecipientId] else {
            throw RTCErrors.missingGroupCall
        }
        let props = try requireSfuSignalingProps(from: call)
        guard let recipientIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(sfuRecipientId) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        try await pcRatchetManager.senderInitialization(
            sessionIdentity: recipientIdentity.sessionIdentity,
            sessionSymmetricKey: group.localIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(props.longTermPublicKey),
                oneTime: props.oneTimePublicKey,
                mlKEM: props.mlKEMPublicKey
            ),
            localKeys: group.localIdentity.localKeys
        )
        return recipientIdentity
    }
    
    /// Creates the room and room keys this is the entry point for group calls
    public func join(
        sender: Call.Participant,
        participants: [Call.Participant],
        sfuRecipientId: String,
        supportsVideo: Bool = true
    ) async throws {
        
        // Allow joining an SFU room even if the participant list is currently empty.
        var call = try Call(
            groupSharedCommunicationId: sfuRecipientId,
            sender: sender,
            recipients: participants,
            supportsVideo: supportsVideo,
            isActive: true
        )
        
        let localIdentity: ConnectionLocalIdentity
        if let existingIdentity = try await pcKeyManager.fetchCallKeyBundle() {
            localIdentity = existingIdentity
        } else {
            // Group calls use the SFU/control-plane key store (`pcKeyManager`) consistently.
            // This prevents symmetric-key mismatches when the Double Ratchet state manager
            // unwraps/stores session identity props.
            localIdentity = try await pcKeyManager.generateSenderIdentity(
                connectionId: sfuRecipientId,
                secretName: sender.secretName
            )
        }
        
        // For group calls, these props are used for SFU signaling ratchet remoteKeys.
        call.signalingIdentityProps = await localIdentity.sessionIdentity.props(symmetricKey: localIdentity.symmetricKey)
        guard call.signalingIdentityProps != nil else {
            throw EncryptionErrors.missingProps
        }
        
        // Create Group call with needed metadata
        let group = createGroupCall(
            call: call,
            sfuRecipientId: sfuRecipientId,
            localIdentity: localIdentity)
        
        groupCalls[sfuRecipientId] = group
        
        setMediaDelegate(group)
        try await group.join()
        
        try await delegate?.negotiateGroupIdentity(
            call: call,
            sfuRecipientId: sfuRecipientId)
    }
    
    public func leave(sfuRecipientId: String, call: Call) async throws {
        guard let group = groupCalls[sfuRecipientId] else {
            throw RTCErrors.missingGroupCall
        }
        await group.leave()
        groupCalls.removeValue(forKey: sfuRecipientId)
        await shutdown(with: call)
    }
    
    
    public func createSFUIdentity(
        sfuRecipientId: String,
        call: Call
    ) async throws {
        
        guard groupCalls[sfuRecipientId] != nil else {
            throw RTCErrors.missingGroupCall
        }
        
        // Identity props must be sent back from the SFU Server's group identity.
        let props = try requireSfuSignalingProps(from: call)
        _ = try await pcKeyManager.createRecipientIdentity(connectionId: sfuRecipientId, props: props)
        _ = try await startGroupCall(call: call, sfuRecipientId: sfuRecipientId)
    }
    
    /// Starts a group call by creating a single PeerConnection intended to connect to an SFU.
    ///
    /// Prefer using ``RTCGroupCall/join()`` unless you are building your own group facade.
    ///
    /// - Important: This intentionally skips the 1:1 Double Ratchet handshake.
    ///   For group calls, frame keys must be distributed via the control plane and applied using
    ///   `setFrameEncryptionKey(_:index:for:)` (control-plane injected keys) or via sender-key
    ///   distribution inside ``RTCGroupCall``.
    func startGroupCall(call: Call, sfuRecipientId: String) async throws -> Call {
        var call = call
        
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId
        
        // Ensure state streams are created so the UI can observe call state.
        try await createStateStream(with: call)
        
        let localIdentity: ConnectionLocalIdentity
        if let existingIdentity = try await pcKeyManager.fetchCallKeyBundle() {
            localIdentity = existingIdentity
        } else {
            localIdentity = try await pcKeyManager.generateSenderIdentity(
                connectionId: sfuRecipientId,
                secretName: call.sender.secretName
            )
        }
        
        // Use a placeholder session identity: group calls do not use this for key agreement.
        _ = try await createPeerConnection(
            with: call,
            sender: call.sender.secretName,
            recipient: sfuRecipientId,
            localIdentity: localIdentity,
            willFinishNegotiation: true
        )
        
        // Initialize ratchet state BEFORE setting the local SDP (createOffer) so early ICE candidates
        // can be encrypted immediately during gathering.
        let recipientIdentity = try await ensureSfuSenderInitialization(call: call, sfuRecipientId: sfuRecipientId)
        
        // Create the offer (sets local SDP, triggers ICE gathering).
        call = try await createOffer(call: call)
        
        // Encrypt the offer call payload for the SFU and emit via transport.
        let offerPlaintext = try BinaryEncoder().encode(call)
        let offerMessage = try await pcRatchetManager.ratchetEncrypt(
            plainText: offerPlaintext,
            sessionId: recipientIdentity.sessionIdentity.id
        )
        let offerPacket = RatchetMessagePacket(
            sfuIdentity: sfuRecipientId,
            header: offerMessage.header,
            ratchetMessage: offerMessage,
            flag: .offer)
        
        await setConnectingIfReady(call: call, callDirection: .outbound(call.supportsVideo ? .video : .voice))
        try await requireTransport().sendSfuMessage(offerPacket, call: call)
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
        case .participants(let packet):
            try await handleParticpants(packet)
        case .participantDemuxId(let packet):
            try await handleParticpant(packet)
        }
    }
    
    // MARK: - Signaling ingress (SFU)
    
    private func ensureSfuRecipientInitializationIfNeeded(sfuIdentity: String, header: EncryptedHeader) async throws {
        if sfuRecipientInitializationCompleteBySfuId.contains(sfuIdentity) { return }
        
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(sfuIdentity) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        guard let callBundle = try await pcKeyManager.fetchCallKeyBundle() else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        try await pcRatchetManager.recipientInitialization(
            sessionIdentity: connectionIdentity.sessionIdentity,
            sessionSymmetricKey: callBundle.symmetricKey,
            header: header,
            localKeys: callBundle.localKeys
        )
        sfuRecipientInitializationCompleteBySfuId.insert(sfuIdentity)
    }
    
    /// Applies an inbound SFU SDP answer to the underlying PeerConnection.
    func handleSfuAnswer(_ packet: RatchetMessagePacket) async throws {
        
        //1. decrypt
        try await ensureSfuRecipientInitializationIfNeeded(sfuIdentity: packet.sfuIdentity, header: packet.header)
        
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(packet.sfuIdentity) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        let decrypted = try await pcRatchetManager.ratchetDecrypt(packet.ratchetMessage, sessionId: connectionIdentity.sessionIdentity.id)
        
        //2. decode
        let call = try BinaryDecoder().decode(Call.self, from: decrypted)
        
        guard let metadata = call.metadata else {
            throw EncryptionErrors.missingMetadata
        }
        let sdp = try BinaryDecoder().decode(SessionDescription.self, from: metadata)
        // handle
        try await handleAnswer(call: call, sdp: sdp)
    }
    
    /// Applies an inbound SFU ICE candidate to the underlying PeerConnection.
    func handleSfuCandidate(_ packet: RatchetMessagePacket) async throws {
        
        //1. decrypt
        try await ensureSfuRecipientInitializationIfNeeded(sfuIdentity: packet.sfuIdentity, header: packet.header)
        
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(packet.sfuIdentity) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        let decrypted = try await pcRatchetManager.ratchetDecrypt(packet.ratchetMessage, sessionId: connectionIdentity.sessionIdentity.id)
        
        //2. decode
        let call = try BinaryDecoder().decode(Call.self, from: decrypted)
        
        guard let metadata = call.metadata else {
            throw EncryptionErrors.missingMetadata
        }
        let candidate = try BinaryDecoder().decode(IceCandidate.self, from: metadata)
        try await handleCandidate(call: call, candidate: candidate)
    }
    
    // MARK: Roster
    func handleParticpants(_ packet: RatchetMessagePacket) async throws {
        //1. decrypt
        try await ensureSfuRecipientInitializationIfNeeded(sfuIdentity: packet.sfuIdentity, header: packet.header)
        
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(packet.sfuIdentity) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        let decrypted = try await pcRatchetManager.ratchetDecrypt(packet.ratchetMessage, sessionId: connectionIdentity.sessionIdentity.id)
        
        //2. decode
        let participants: [RTCGroupCall.Participant] = try BinaryDecoder().decode([RTCGroupCall.Participant].self, from: decrypted)
        
        guard let group = groupCalls[packet.sfuIdentity] else {
            throw RTCErrors.missingGroupCall
        }
        await group.updateParticipants(participants)
    }
    
    func handleParticpant(_ packet: RatchetMessagePacket) async throws {
        //1. decrypt
        try await ensureSfuRecipientInitializationIfNeeded(sfuIdentity: packet.sfuIdentity, header: packet.header)
        
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(packet.sfuIdentity) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        let decrypted = try await pcRatchetManager.ratchetDecrypt(packet.ratchetMessage, sessionId: connectionIdentity.sessionIdentity.id)
        
        //2. decode
        let participant: RTCGroupCall.Participant = try BinaryDecoder().decode(RTCGroupCall.Participant.self, from: decrypted)
        
        guard let group = groupCalls[packet.sfuIdentity] else {
            throw RTCErrors.missingGroupCall
        }
        await group.setDemuxId(participant.demuxId, for: participant.id)
    }
    
}
