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

    /// Creates the room and room keys this is the entry point for group calls.
    /// Store and find by normalized ID (no "#"); transport layer reattaches "#" for IRC.
    public func groupCallNegotiation(
        sender: Call.Participant,
        participants: [Call.Participant],
        sfuRecipientId: String,
        supportsVideo: Bool = true
    ) async throws {
        isGroupCall = true
        let normalizedId = sfuRecipientId.normalizedConnectionId
        // Allow joining an SFU room even if the participant list is currently empty.
        var call = try Call(
            groupSharedCommunicationId: normalizedId,
            sender: sender,
            recipients: participants,
            supportsVideo: supportsVideo,
            isActive: true)
        
        let signalingLocalIdentity: ConnectionLocalIdentity
        if let foundSignalingLocalIdentity = try? await pcKeyManager.fetchCallKeyBundle() {
            signalingLocalIdentity = foundSignalingLocalIdentity
        } else {
            signalingLocalIdentity = try await pcKeyManager.generateSenderIdentity(
               connectionId: call.sharedCommunicationId,
               secretName: sender.secretName)
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
        
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId.normalizedConnectionId

        // Create the offer (sets local SDP, triggers ICE gathering).
        call = try await createOffer(call: call)
        
        // Encrypt and send; roomId stored normalized, "#" reattached at transport.
        let offerPlaintext = try BinaryEncoder().encode(call)
        let writeTask = WriteTask(
            data: offerPlaintext,
            roomId: call.sharedCommunicationId,
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

        guard let group = groupCall(forSfuIdentity: sfuRecipientId) else {
            throw RTCErrors.missingGroupCall
        }
        // Identity props must be sent back from the SFU Server's group identity.
        guard let props = call.signalingIdentityProps else { throw EncryptionErrors.missingProps }
        do {
            try await pcKeyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId.normalizedConnectionId)
        } catch {
            _ = try await pcKeyManager.createRecipientIdentity(
                connectionId: call.sharedCommunicationId.normalizedConnectionId,
                props: props)
        }
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
        // Without this, candidates remain buffered (readyForCandidates stays false) and ICE can stall in `checking`.
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
                roomId: call.sharedCommunicationId.normalizedConnectionId,
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
            logger.log(level: .info, message: "Handshake complete")
        }
    }
    
}
