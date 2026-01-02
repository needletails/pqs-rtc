//
//  RTCSession+E2EE.swift
//  pqs-rtc
//
//  Created by Cole M on 11/8/25.
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
import DoubleRatchetKit
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

extension RTCSession {
    
#if canImport(WebRTC)
    enum TrackKind: Sendable {
        case videoSender(RTCRtpSender), videoReceiver(RTCRtpReceiver), audioSender(RTCRtpSender), audioReceiver(RTCRtpReceiver)
    }
#endif
    
    //MARK: Key Derivation & Cleanup
#if canImport(WebRTC)
    /// Applies a frame-encryption key for a participant.
    ///
    /// In `shared` mode the participantId is ignored and the key is applied to the shared key ring.
    /// In `perParticipant` mode the key is applied to the given participant.
    public func setFrameEncryptionKey(_ key: Data, index: Int, for participantId: String) {
        if frameEncryptionKeyMode == .shared {
            keyProvider.setSharedKey(key, with: Int32(index))
        } else {
            keyProvider.setKey(key, with: Int32(index), forParticipant: participantId)
        }
    }

    /// Ratchets and returns the next key for a participant/index.
    ///
    /// Note: This is optional for some designs; many deployments distribute derived
    /// keys via the control plane instead of requiring local ratcheting by receivers.
    public func ratchetFrameEncryptionKey(index: Int, for participantId: String) -> Data {
        if frameEncryptionKeyMode == .shared {
            return keyProvider.ratchetSharedKey(Int32(index))
        } else {
            return keyProvider.ratchetKey(participantId, with: Int32(index))
        }
    }

    /// Exports the current key for a participant/index.
    public func exportFrameEncryptionKey(index: Int, for participantId: String) -> Data {
        if frameEncryptionKeyMode == .shared {
            return keyProvider.exportSharedKey(Int32(index))
        } else {
            return keyProvider.exportKey(participantId, with: Int32(index))
        }
    }

    /// Creates a sender encrypted frame using keys from the connection or CallKeyBundleStore
    /// - Parameters:
    ///   - participant: The participant identifier
    ///   - connectionId: The connection ID
    func createEncryptedFrame(
        connection: RTCConnection,
        kind: TrackKind,
        participantIdOverride: String? = nil
    ) async throws {
        var connection = connection
        switch kind {
        case .videoSender(let sender):
            // For outbound media, participantId must be the LOCAL participant identity
            // so that the remote receiver can use the same id to decrypt.
            let videoFrameCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpSender: sender,
                participantId: connection.localParticipantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)
            
            guard let videoFrameCryptor else {
                logger.log(level: .error, message: "❌ Failed to create video FrameCryptor")
                return
            }
            
            // Set delegate before enabling
            videoFrameCryptor.delegate = frameCryptorDelegate
            videoFrameCryptor.enabled = true
            connection.videoSenderCryptor = videoFrameCryptor
        case .videoReceiver(let receiver):
            // For inbound media, participantId must be the REMOTE participant identity
            // (track owner) so it matches the sender's configuration.
            let videoFrameCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpReceiver: receiver,
                participantId: participantIdOverride ?? connection.remoteParticipantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)
            
            guard let videoFrameCryptor else {
                logger.log(level: .error, message: "Failed to create video FrameCryptor")
                return
            }
            
            videoFrameCryptor.delegate = frameCryptorDelegate
            videoFrameCryptor.enabled = true
            connection.videoFrameCryptor = videoFrameCryptor
            if let participantIdOverride {
                connection.videoReceiverCryptorsByParticipantId[participantIdOverride] = videoFrameCryptor
            }
            
        case .audioSender(let sender):
            // For outbound media, participantId must be the LOCAL participant identity.
            let audioCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpSender: sender,
                participantId: connection.localParticipantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)
            
            guard let audioCryptor else {
                logger.log(level: .error, message: "Failed to create audio FrameCryptor")
                return
            }
            
            audioCryptor.delegate = frameCryptorDelegate
            audioCryptor.enabled = true
            connection.audioSenderCryptor = audioCryptor
        case .audioReceiver(let receiver):
            // For inbound media, participantId must be the REMOTE participant identity.
            let audioCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpReceiver: receiver,
                participantId: participantIdOverride ?? connection.remoteParticipantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)
            
            guard let audioCryptor else {
                logger.log(level: .error, message: "Failed to create audio FrameCryptor")
                return
            }
            
            audioCryptor.delegate = frameCryptorDelegate
            audioCryptor.enabled = true
            connection.audioFrameCryptor = audioCryptor
            if let participantIdOverride {
                connection.audioReceiverCryptorsByParticipantId[participantIdOverride] = audioCryptor
            }
        }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }
#elseif os(Android)
    public func setFrameEncryptionKey(_ key: Data, index: Int, for participantId: String) async {
        if frameEncryptionKeyMode == .shared {
            await rtcClient.setSharedKey(key, with: Int32(index), ratchetSalt: ratchetSalt)
        } else {
            await rtcClient.setKey(key, with: Int32(index), forParticipant: participantId, ratchetSalt: ratchetSalt)
        }
    }

    public func ratchetFrameEncryptionKey(index: Int, for participantId: String) async -> Data {
        if frameEncryptionKeyMode == .shared {
            // Shared ratchet is modeled as a key update via control plane.
            return Data()
        }
        return await rtcClient.ratchetKey(forParticipant: participantId, index: Int32(index))
    }

    public func exportFrameEncryptionKey(index: Int, for participantId: String) async -> Data {
        if frameEncryptionKeyMode == .shared {
            return Data()
        }
        return await rtcClient.exportKey(forParticipant: participantId, index: Int32(index))
    }

    func createEncryptedFrame(connection: RTCConnection) async throws {
        // On Android, the shared key is set at derivation time (see `setMessageKey`).
        // Here we only attach sender cryptors via the AndroidRTCClient bridge.
        await rtcClient.createSenderEncryptedFrame(
            participant: connection.localParticipantId,
            connectionId: connection.id
        )
    }
#endif
    
    public func setMessageKey(connection: RTCConnection, call: Call) async throws {
        let (messageKey, index) = try await deriveMessageKey(
            connection: connection,
            call: call)
        
#if canImport(WebRTC)
        // Apply media key to the WebRTC key provider.
        // - Shared-key mode: one key ring for all participants.
        // - Per-participant mode (participant-scoped key ring): for 1:1 we set the same key for both
        //   local and remote participant IDs so sender/receiver cryptors can resolve keys.
        if frameEncryptionKeyMode == .shared {
            keyProvider.setSharedKey(messageKey, with: Int32(index))
        } else {
            keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId)
            keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.remoteParticipantId)
        }
#elseif os(Android)
        if frameEncryptionKeyMode == .shared {
            await rtcClient.setSharedKey(messageKey, with: Int32(index), ratchetSalt: ratchetSalt)
        } else {
            // For 1:1, provision both local+remote IDs with the same key so send/recv match.
            await rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId, ratchetSalt: ratchetSalt)
            await rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.remoteParticipantId, ratchetSalt: ratchetSalt)
        }
#endif
    }
    
    func setReceivingMessageKey(connection: RTCConnection, ciphertext: Data) async throws {
        let (messageKey, index) = try await deriveReceivedMessageKey(
            participant: connection.sender,
            localKeys: connection.localKeys,
            symmetricKey: connection.symmetricKey,
            sessionIdentity: connection.sessionIdentity,
            ciphertext: ciphertext)
        
#if canImport(WebRTC)
        if frameEncryptionKeyMode == .shared {
            // Shared-key mode: same media key & index is used for decrypting frames, independent of participantId.
            keyProvider.setSharedKey(messageKey, with: Int32(index))
        } else {
            // Per-participant mode: for 1:1 we provision both local+remote IDs with the same key.
            keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId)
            keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.remoteParticipantId)
        }
#elseif os(Android)
        if frameEncryptionKeyMode == .shared {
            // Match Apple as closely as possible: set the shared media key at the moment
            // we derive it for receiving.
            await rtcClient.setSharedKey(messageKey, with: Int32(index), ratchetSalt: ratchetSalt)
        } else {
            // For 1:1, provision both local+remote IDs with the same key.
            await rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId, ratchetSalt: ratchetSalt)
            await rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.remoteParticipantId, ratchetSalt: ratchetSalt)
        }
        
        // Attach receiver cryptors (Android needs explicit receiver attachment).
        // For inbound media, participantId must be the REMOTE track owner.
        await rtcClient.createReceiverEncryptedFrame(
            participant: connection.remoteParticipantId,
            connectionId: connection.id
        )
#endif
    }
    
    private func deriveMessageKey(
        connection: RTCConnection,
        call: Call
    ) async throws -> (Data, Int) {
        var connection = connection
        guard let props = await connection.sessionIdentity.props(symmetricKey: connection.symmetricKey) else {
            throw EncryptionErrors.missingProps
        }
        try await ratchetManager.senderInitialization(
            sessionIdentity: connection.sessionIdentity,
            sessionSymmetricKey: connection.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(props.longTermPublicKey),
                oneTime: props.oneTimePublicKey,
                mlKEM: props.mlKEMPublicKey),
            localKeys: connection.localKeys)
        switch connection.cipherNegotiationState {
        case .waiting:
            // Check per-connection instead of global flag - each party needs to send their own handshake
            let ciphertext = try await ratchetManager.getCipherText(sessionId: connection.sessionIdentity.id)
            try await requireTransport().sendCiphertext(
                recipient: connection.recipient,
                connectionId: connection.id,
                ciphertext: ciphertext,
                call: call)
            connection.transition(to: .setSenderKey)
        default:
            break
        }
        if connection.cipherNegotiationState == .setRecipientKey {
            connection.transition(to: .complete)
        }
        await connectionManager.updateConnection(id: connection.id, with: connection)
        if connection.cipherNegotiationState == .complete {
            logger.log(level: .info, message: "Completed cipher negotiation 🔒")
        }
        let (messageKey, index) = try await ratchetManager.deriveMessageKey(sessionId: connection.sessionIdentity.id)
        return (messageKey.bytes, index)
    }
    
    private func deriveReceivedMessageKey(
        participant: String,
        localKeys: LocalKeys,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity,
        ciphertext: Data
    ) async throws -> (Data, Int) {
        
        guard let props = await sessionIdentity.props(symmetricKey: symmetricKey) else {
            throw EncryptionErrors.missingProps
        }
        
        guard !ciphertext.isEmpty else {
            throw EncryptionErrors.missingCipherText
        }
        
        try await ratchetManager.recipientInitialization(
            sessionIdentity: sessionIdentity,
            sessionSymmetricKey: symmetricKey,
            localKeys: localKeys,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(props.longTermPublicKey),
                oneTime: props.oneTimePublicKey,
                mlKEM: props.mlKEMPublicKey),
            ciphertext: ciphertext)
        
        let (messageKey, index) = try await ratchetManager.deriveReceivedMessageKey(
            sessionId: sessionIdentity.id,
            cipherText: ciphertext)
        
        return (messageKey.bytes, index)
    }
    
    //MARK: RTCCipherTransport
    
    /// This message is called when the transport receives a ciphertext from the sender. The Call must contain the proper unwrapped session identity props.
    func receiveCiphertext(
        recipient: String,
        ciphertext: Data,
        call: Call
    ) async throws {
        guard await !hasConnection(id: call.sharedCommunicationId) else {
            logger.log(level: .info, message: "Already has connection")
            return
        }
        
        guard let identityProps = call.identityProps else {
            logger.log(level: .info, message: "Call will not proceed the session identity for sender is missing")
            return
        }
        
        let connectionIdentity = try await createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: identityProps)
        
        guard let localIdentity = try await fetchLocalIdentity() else {
            return
        }
        
        _ = try await createPeerConnection(
            with: call,
            sender: call.sender.secretName,
            recipient: recipient,
            localIdentity: localIdentity,
            sessionIdentity: connectionIdentity.sessionIdentity,
            willFinishNegotiation: true)
        
        //#if canImport(WebRTC)
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
            throw RTCErrors.connectionNotFound
        }
        
        let initialState = connection.cipherNegotiationState
        logger.log(level: .info, message: "Received ciphertext for connectionId: \(connection.id) in cipher negotiation state: \(initialState)")
        switch initialState {
        case .waiting, .setSenderKey:
            var connection = connection
            
            logger.log(level: .info, message: "\(recipient.uppercased()) received ciphertext for connectionId: \(connection.id)")
            
            // Verify identity exists before storing ciphertext
            if await keyManager.fetchConnectionIdentityByConnectionId(connection.id) == nil {
                logger.log(level: .warning, message: "Connection identity does not exist for connectionId: \(connection.id). Ciphertext may not be stored properly.")
            }
            
            // Store ciphertext in keyManager for this connection (for ratcheting purposes)
            await keyManager.storeCiphertext(connectionId: connection.id, ciphertext: ciphertext)
            
#if canImport(WebRTC)
            let hasVideoReceiver = connection.peerConnection.receivers.contains { $0.track?.kind == kRTCMediaStreamTrackKindVideo }
            let hasAudioReceiver = connection.peerConnection.receivers.contains { $0.track?.kind == kRTCMediaStreamTrackKindAudio }
            logger.log(level: .info, message: "\(hasVideoReceiver ? "Has video receiver" : "Missing video receiver") \(hasAudioReceiver ? "Has audio receiver" : "Has audio receiver")")
            
            if hasVideoReceiver || hasAudioReceiver {
                logger.log(level: .info, message: "🚀 Receivers available, setting up receiver cryptor after handshake")
                try await setReceivingMessageKey(connection: connection, ciphertext: ciphertext)
                logger.log(level: .info, message: "👌 Handshake complete")
            } else {
                logger.log(level: .info, message: "⏳ Receivers not yet available, will set up cryptor when receivers start")
            }
#else
            // Android PeerConnection APIs differ. We attempt setup here and let AndroidRTCClient
            // decide whether receivers are present when attaching FrameCryptors.
            logger.log(level: .info, message: "(Android) Attempting receiver cryptor setup after handshake")
            try await setReceivingMessageKey(connection: connection, ciphertext: ciphertext)
            logger.log(level: .info, message: "👌 Handshake complete")
#endif
            
            if initialState == .setSenderKey {
                connection.transition(to: .complete)
            } else if initialState == .waiting {
                connection.transition(to: .setRecipientKey)
            }
            await connectionManager.updateConnection(id: connection.id, with: connection)
            if connection.cipherNegotiationState == .complete {
                logger.log(level: .info, message: "Completed cipher negotiation 🔒")
            }
            // Only the pure receiver (initially in .waiting) should initiate an outbound
            // handshake & media key derivation here. If we were already in .setSenderKey,
            // we've run the sender path before and only needed to finalize the receive side.
            if connection.cipherNegotiationState == .setRecipientKey {
                try await setMessageKey(connection: connection, call: call)
            }
        default:
            break
        }
        //#endif
    }
}
