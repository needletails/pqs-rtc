//
//  RTCSession+OneToOneCall.swift
//  pqs-rtc
//
//  Created by Cole M on 1/15/26.
//

import Foundation
import DoubleRatchetKit
import BinaryCodable

extension RTCSession {
    
    /// Decrypts 1:1 signaling data using the call's Double Ratchet keys.
    ///
    /// Uses `pcRatchetManager` to decrypt packets received via SwiftSFU.
    public func decryptOneToOneSignaling(
        header: EncryptedHeader,
        ciphertext: RatchetMessage,
        connectionId: String
    ) async throws -> Data {
        
        // Get connection identity for this 1:1 signaling channel
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(connectionId) else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        // Get local identity
        guard let callBundle = try await pcKeyManager.fetchCallKeyBundle() else {
            throw EncryptionErrors.missingSessionIdentity
        }
        
        // Initialize recipient ratchet if needed
        try await pcRatchetManager.recipientInitialization(
            sessionIdentity: connectionIdentity.sessionIdentity,
            sessionSymmetricKey: callBundle.symmetricKey,
            header: header,
            localKeys: callBundle.localKeys)
        
        // Decrypt
        let decrypted = try await pcRatchetManager.ratchetDecrypt(
            ciphertext,
            sessionId: connectionIdentity.sessionIdentity.id)
        
        return decrypted
    }
    
    /// Encrypts 1:1 signaling data using the call's Double Ratchet keys.
    ///
    /// Uses `pcRatchetManager` (same as group calls) for transport encryption.
    /// The connection's ratchet must be initialized first (via createCryptoSession/receiveCiphertext).
    public func encryptOneToOneSignaling(
        plaintext: Data,
        connectionId: String,
        flag: PacketFlag,
        remoteProps: SessionIdentity.UnwrappedProps
    ) async throws -> RatchetMessagePacket {

        // Ensure the connection exists (ratchet state is scoped to connectionId).
        guard await connectionManager.findConnection(with: connectionId) != nil else {
            throw RTCErrors.connectionNotFound
        }
        
        // Ensure we have a connection identity for this 1:1 signaling channel
        guard let connectionIdentity = await pcKeyManager.fetchConnectionIdentityByConnectionId(connectionId) else {
            throw RTCErrors.invalidConfiguration("A Local Connection Identity should have been constructed by now.")
        }
        
        guard let localIdentity = try await pcKeyManager.fetchCallKeyBundle() else {
            throw RTCErrors.invalidConfiguration("A Local Connection Identity should have been constructed by now.")
        }

        try await pcRatchetManager.senderInitialization(
            sessionIdentity: connectionIdentity.sessionIdentity,
            sessionSymmetricKey: localIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(remoteProps.longTermPublicKey),
                oneTime: remoteProps.oneTimePublicKey,
                mlKEM: remoteProps.mlKEMPublicKey
            ),
            localKeys: localIdentity.localKeys)
        
        // Encrypt the plaintext
        let message = try await pcRatchetManager.ratchetEncrypt(
            plainText: plaintext,
            sessionId: connectionIdentity.sessionIdentity.id)
        
        // For 1:1 calls, sfuIdentity is just the connectionId (not a channel format)
        // since we send to nicks, not channels. The channelIdentity is only used
        // internally for key management.
        return RatchetMessagePacket(
            sfuIdentity: connectionId,
            header: message.header,
            ratchetMessage: message,
            flag: flag)
    }
    
    public func startCall(_ call: Call) async throws {
        try await createStateStream(with: call)
        await setConnectingIfReady(call: call, callDirection: .inbound(call.supportsVideo ? .video : .voice))
        shouldOffer = true
        try await requireTransport().sendStartCall(call)
        logger.log(level: .info, message: "Sent start_call message for \(call.sharedCommunicationId)")
    }
    
    /// Initiates an outbound 1:1 call.
    /// - Parameter call: The call to initiate (must have recipient's identityProps)
    public func initiateCall(with call: Call) async throws {
        
        //Create crypto session (establishes Double Ratchet handshake)
         try await createCryptoPeerConnection(with: call)

        logger.log(level: .info, message: "Initiated 1:1 call setup for \(call.sharedCommunicationId)")
    }
    
    /// Answers an incoming 1:1 call.
    ///
    /// This method:
    /// 1. Handles the incoming SDP offer and generates an answer
    /// 2. Sends encrypted SDP answer via SwiftSFU
    /// 3. Sends call_answered notification to the caller
    /// 4. Sends call_answered_aux_device notification to other devices
    ///
    /// - Parameter call: The incoming call with SDP offer in metadata
    public func answerCall(_ call: Call) async throws {
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId
        

        guard let recipient = call.recipients.first else {
            throw RTCErrors.invalidConfiguration("Answering a call with no recipients is not supported.")
        }
        
        // We need to create our local identities first so that the offerer has out frame cryptor identity props in order to initialize a session.
            let frameLocalIdentity = try await generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: recipient.secretName)

            let signalingLocalIdentity = try await pcKeyManager.generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: recipient.secretName)
        
        var call = call
        call.frameIdentityProps = await frameLocalIdentity.sessionIdentity.props(symmetricKey: frameLocalIdentity.symmetricKey)
        call.signalingIdentityProps = await signalingLocalIdentity.sessionIdentity.props(symmetricKey: signalingLocalIdentity.symmetricKey)
        
        try await createStateStream(with: call)
        setCanAnswer(true)
        // Send call_answered notification to the caller
        try await requireTransport().sendCallAnswered(call)
        logger.log(level: .info, message: "Sent call_answered notification for \(call.sharedCommunicationId)")
        
        // Send call_answered_aux_device notification to other devices
        try await requireTransport().sendCallAnsweredAuxDevice(call)
        logger.log(level: .info, message: "Sent call_answered_aux_device notification for \(call.sharedCommunicationId)")
    }
    
    /// Handles notification that the call was answered on another device.
    ///
    /// Transitions the call state to indicate it was answered elsewhere.
    ///
    /// - Parameter call: The call that was answered elsewhere
    public func handleCallAnsweredElsewhere(_ call: Call) async throws {
        await callState.transition(to: .callAnsweredAuxDevice(call))
        logger.log(level: .info, message: "Call answered on another device: \(call.sharedCommunicationId)")
    }
    
    /// Ends a 1:1 call.
    ///
    /// Shuts down the peer connection and cleans up resources.
    ///
    /// - Parameter call: The call to end
    public func endCall(_ call: Call) async throws {
        await shutdown(with: call)
        logger.log(level: .info, message: "Ended 1:1 call: \(call.sharedCommunicationId)")
    }
}
