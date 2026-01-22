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
    
    public func createCryptoPeerConnection(with call: Call) async throws  {
        logger.log(level: .info, message: "Starting CreateCryptoPeerConnection")
        var call = call
        
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId
        
        // Ensure RTC state streams are created so the UI can observe call state for 1-to-1 calls
        guard let recipient = call.recipients.first else {
            throw PQSRTC.CallError.invalidMetadata("Call must have a recipient")
        }
        
        // Copy remote identity props before we write over them
        guard let remoteFrameProps = call.frameIdentityProps else {
            throw RTCErrors.invalidConfiguration("Call must have a frame identity")
        }
        guard let remoteSignalingProps = call.signalingIdentityProps else {
            throw RTCErrors.invalidConfiguration("Call must have a frame identity")
        }
        
        _ = try await createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: remoteFrameProps)
        _ = try await pcKeyManager.createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: remoteSignalingProps)
        
        let frameLocalIdentity: ConnectionLocalIdentity
        if let existingIdentity = try await fetchLocalIdentity() {
            frameLocalIdentity = existingIdentity
        } else {
            frameLocalIdentity = try await generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: call.sender.secretName)
        }
        
        let signalingLocalIdentity: ConnectionLocalIdentity
        if let existingIdentity = try await pcKeyManager.fetchCallKeyBundle() {
            signalingLocalIdentity = existingIdentity
        } else {
            signalingLocalIdentity = try await pcKeyManager.generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: call.sender.secretName)
        }
        
        call.frameIdentityProps = await frameLocalIdentity.sessionIdentity.props(symmetricKey: frameLocalIdentity.symmetricKey)
        call.signalingIdentityProps = await signalingLocalIdentity.sessionIdentity.props(symmetricKey: signalingLocalIdentity.symmetricKey)
        
        guard call.frameIdentityProps != nil else {
            throw EncryptionErrors.missingProps
        }
        
        guard call.signalingIdentityProps != nil else {
            throw EncryptionErrors.missingProps
        }
        
        _ = try await createPeerConnection(
            with: call,
            sender: call.sender.secretName,
            recipient: recipient.secretName,
            localIdentity: frameLocalIdentity)
        
        logger.log(level: .info, message: "Start call created PeerConnection for sharedCommunicationId=\(call.sharedCommunicationId)")
    }
    
    /// Completes the 1:1 crypto handshake after receiving an inbound ciphertext message.
    ///
    /// This method waits for the app to decide whether to accept the call via
    /// ``RTCSession/setCanAnswer(_:)`` or ``RTCSession/setCallAnswerState(_:for:)``.
    /// If accepted, it will create and send an encrypted SDP offer via ``RTCTransportEvents/sendOneToOneOffer(_:call:)``.
    public func finishCryptoSessionCreation(
        ciphertext: Data,
        call: Call
    ) async throws -> Call {
        var call = call
        
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
        
        // Use the same deterministic session-id derivation as the key manager so this works even if
        // the app uses non-UUID connection ids (or prefixes with '#').
        let callId = KeyManager.sessionId(from: call.sharedCommunicationId)
        pendingAnswerCallId = callId
        if callAnswerStatesById[callId] == nil {
            callAnswerStatesById[callId] = .pending
        }
        
        try await receiveCiphertext(
            recipient: recipient.secretName,
            ciphertext: ciphertext,
            call: call)
        
        logger.log(level: .info, message: "We are going to offer? \(shouldOffer ? "YES" : "NO")")
        if shouldOffer {
            switch await connectionManager.findConnection(with: call.sharedCommunicationId)?.cipherNegotiationState {
            case .complete:
                var call = try await createOffer(call: call)
                
                guard let remoteProps = call.signalingIdentityProps else {
                    throw RTCErrors.invalidConfiguration("Remote Props are missing")
                }
                
                guard let keyBundle = try await pcKeyManager.fetchCallKeyBundle(),
                      let localProps = await keyBundle.sessionIdentity.props(symmetricKey: keyBundle.symmetricKey) else {
                    throw RTCErrors.invalidConfiguration("Local Props are missing")
                }
                
                //If we are Offering we need to feed our already created local signaling identity.
                call.signalingIdentityProps = localProps
                
                // Encrypt offer and send via encrypted transport
                let plaintext = try BinaryEncoder().encode(call)
                let packet = try await encryptOneToOneSignaling(
                    plaintext: plaintext,
                    connectionId: call.sharedCommunicationId,
                    flag: .offer,
                    remoteProps: remoteProps)
                
                try await requireTransport().sendOneToOneMessage(packet, recipient: recipient)
                
                // Begin ICE trickle immediately after sending the offer (do not wait for handshakeComplete).
                // This significantly reduces "long time to connect" when the host transport delays the ack.
                do {
                    try await startSendingCandidates(call: call)
                } catch {
                    logger.log(level: .warning, message: "Failed to start sending ICE candidates after offer (will continue buffering): \(error)")
                }
                return call
            default:
                await shutdown(with: call)
                throw ConnectionErrors.connectionNotFound
            }
        } else {
            return call
        }
    }
    
    public func generateSenderIdentity(
        connectionId: String,
        secretName: String
    ) async throws -> ConnectionLocalIdentity {
        try await keyManager.generateSenderIdentity(connectionId: connectionId, secretName: secretName)
    }
    
#if canImport(WebRTC)
    enum TrackKind: Sendable {
        case videoSender(RTCRtpSender), videoReceiver(RTCRtpReceiver), audioSender(RTCRtpSender), audioReceiver(RTCRtpReceiver)
    }

    // MARK: - Crypto diagnostics (safe for production)
    //
    // These helpers log only metadata needed to validate directionality (Alice→Bob vs Bob→Alice):
    // - participant IDs
    // - key IDs + key byte lengths
    //
    // They NEVER log key bytes, derived message keys, ciphertexts, or SDP.
    private func propsSummary(_ props: SessionIdentity.UnwrappedProps) -> String {
        let oneTimeId = props.oneTimePublicKey.map { String(describing: $0.id) } ?? "nil"
        let kemId = String(describing: props.mlKEMPublicKey.id)
        return "oneTimeId=\(oneTimeId) mlKEMId=\(kemId) ltpkBytes=\(props.longTermPublicKey.count) spkBytes=\(props.signingPublicKey.count)"
    }

    private func logCryptoWiring(_ message: Message) {
#if DEBUG
        logger.log(level: .debug, message: message)
#else
        // Never emit crypto wiring logs in Release builds.
        _ = message
#endif
    }
    
    //MARK: Key Derivation & Cleanup
    
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
        // Track provisioning for diagnostics (safe metadata only).
        lastFrameKeyIndexByParticipantId[participantId] = index
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
            #if DEBUG
            if frameEncryptionKeyMode == .perParticipant {
                let pid = participantIdOverride ?? connection.remoteParticipantId
                if lastFrameKeyIndexByParticipantId[pid] == nil {
                    logCryptoWiring("SFU/FRAME key missing for participantId=\(pid) at receiver-cryptor creation time (connId=\(connection.id)). Expect black video until setFrameEncryptionKey is called.")
                } else if let idx = lastFrameKeyIndexByParticipantId[pid] {
                    let keyBytes = exportFrameEncryptionKey(index: idx, for: pid).count
                    logCryptoWiring("SFU/FRAME key present for participantId=\(pid) index=\(idx) keyBytes=\(keyBytes) (connId=\(connection.id))")
                }
            }
            #endif
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
            #if DEBUG
            if frameEncryptionKeyMode == .perParticipant {
                let pid = participantIdOverride ?? connection.remoteParticipantId
                if lastFrameKeyIndexByParticipantId[pid] == nil {
                    logCryptoWiring("SFU/FRAME key missing for participantId=\(pid) at receiver-cryptor creation time (connId=\(connection.id)). Expect silent/black media until setFrameEncryptionKey is called.")
                } else if let idx = lastFrameKeyIndexByParticipantId[pid] {
                    let keyBytes = exportFrameEncryptionKey(index: idx, for: pid).count
                    logCryptoWiring("SFU/FRAME key present for participantId=\(pid) index=\(idx) keyBytes=\(keyBytes) (connId=\(connection.id))")
                }
            }
            #endif
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
            rtcClient.setSharedKey(key, with: Int32(index), ratchetSalt: ratchetSalt)
        } else {
            rtcClient.setKey(key, with: Int32(index), forParticipant: participantId, ratchetSalt: ratchetSalt)
        }
        // Track provisioning for diagnostics (safe metadata only).
        lastFrameKeyIndexByParticipantId[participantId] = index
    }
    
    public func ratchetFrameEncryptionKey(index: Int, for participantId: String) async -> Data {
        if frameEncryptionKeyMode == .shared {
            // Shared ratchet is modeled as a key update via control plane.
            return Data()
        }
        return rtcClient.ratchetKey(forParticipant: participantId, index: Int32(index))
    }
    
    public func exportFrameEncryptionKey(index: Int, for participantId: String) async -> Data {
        if frameEncryptionKeyMode == .shared {
            return Data()
        }
        return rtcClient.exportKey(forParticipant: participantId, index: Int32(index))
    }
    
    func createEncryptedFrame(connection: RTCConnection) async throws {
        // On Android, the shared key is set at derivation time (see `setMessageKey`).
        // Here we only attach sender cryptors via the AndroidRTCClient bridge.
        rtcClient.createSenderEncryptedFrame(
            participant: connection.localParticipantId,
            connectionId: connection.id
        )
    }
#endif
    
    public func setMessageKey(
        connection: RTCConnection,
        call: Call
    ) async throws {
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
            rtcClient.setSharedKey(messageKey, with: Int32(index), ratchetSalt: ratchetSalt)
        } else {
            // For 1:1, provision both local+remote IDs with the same key so send/recv match.
            rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId, ratchetSalt: ratchetSalt)
            rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.remoteParticipantId, ratchetSalt: ratchetSalt)
        }
#endif
    }
    
    func createRecipientIdentity(
        connectionId: String,
        props: SessionIdentity.UnwrappedProps
    ) async throws -> ConnectionSessionIdentity {
        try await keyManager.createRecipientIdentity(connectionId: connectionId, props: props)
    }
    
    func fetchLocalIdentity() async throws -> ConnectionLocalIdentity? {
        try await keyManager.fetchCallKeyBundle()
    }
    
    func setReceivingMessageKey(connection: RTCConnection, ciphertext: Data) async throws {
        let (messageKey, index) = try await deriveReceivedMessageKey(
            connectionId: connection.id,
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
            rtcClient.setSharedKey(messageKey, with: Int32(index), ratchetSalt: ratchetSalt)
        } else {
            // For 1:1, provision both local+remote IDs with the same key.
            rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId, ratchetSalt: ratchetSalt)
            rtcClient.setKey(messageKey, with: Int32(index), forParticipant: connection.remoteParticipantId, ratchetSalt: ratchetSalt)
        }
        
        // Attach receiver cryptors (Android needs explicit receiver attachment).
        // For inbound media, participantId must be the REMOTE track owner.
        rtcClient.createReceiverEncryptedFrame(
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
        
        guard let remoteConnectionIdentity = await keyManager.fetchConnectionIdentityByConnectionId(connection.id),
              let remoteProps = await remoteConnectionIdentity.sessionIdentity.props(symmetricKey: remoteConnectionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote peer did not provide a valid connection identity")
        }
        
        if let localProps = await connection.sessionIdentity.props(symmetricKey: connection.symmetricKey) {
            logCryptoWiring("CRYPTO senderInitialization wiring connId=\(connection.id) localParticipantId=\(connection.localParticipantId) remoteParticipantId=\(connection.remoteParticipantId) local{\(propsSummary(localProps))} remote{\(propsSummary(remoteProps))}")
        } else {
            // Still safe, but treat missing local props as noteworthy when diagnostics are enabled.
            logCryptoWiring("CRYPTO senderInitialization wiring connId=\(connection.id) local props missing; localParticipantId=\(connection.localParticipantId) remoteParticipantId=\(connection.remoteParticipantId) remote{\(propsSummary(remoteProps))}")
        }

        try await ratchetManager.senderInitialization(
            sessionIdentity: connection.sessionIdentity,
            sessionSymmetricKey: connection.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(remoteProps.longTermPublicKey),
                oneTime: remoteProps.oneTimePublicKey,
                mlKEM: remoteProps.mlKEMPublicKey),
            localKeys: connection.localKeys)
        switch connection.cipherNegotiationState {
        case .waiting, .setRecipientKey:
            // Check per-connection instead of global flag - each party needs to send their own handshake
            let ciphertext = try await ratchetManager.getCipherText(sessionId: connection.sessionIdentity.id)
            for recipient in call.recipients {
                try await requireTransport().sendCiphertext(
                    recipient: recipient.secretName,
                    connectionId: connection.id,
                    ciphertext: ciphertext,
                    call: call)
                logger.log(level: .info, message: "Sent ciphertext to recipient: \(recipient.secretName)")
            }
            if connection.cipherNegotiationState == .setRecipientKey {
                connection.transition(to: .complete)
            } else {
                connection.transition(to: .setSenderKey)
            }
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
        connectionId: String,
        participant: String,
        localKeys: LocalKeys,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity,
        ciphertext: Data
    ) async throws -> (Data, Int) {
        
        guard let localProps = await sessionIdentity.props(symmetricKey: symmetricKey) else {
            throw EncryptionErrors.missingProps
        }
        
        guard let remoteConnectionIdentity = await keyManager.fetchConnectionIdentityByConnectionId(connectionId),
              let remoteProps = await remoteConnectionIdentity.sessionIdentity.props(symmetricKey: remoteConnectionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote peer did not provide a valid connection identity")
        }
        
        logCryptoWiring("CRYPTO recipientInitialization wiring connId=\(connectionId) participant=\(participant) local{\(propsSummary(localProps))} remote{\(propsSummary(remoteProps))}")

        guard !ciphertext.isEmpty else {
            throw EncryptionErrors.missingCipherText
        }
        
        try await ratchetManager.recipientInitialization(
            sessionIdentity: sessionIdentity,
            sessionSymmetricKey: symmetricKey,
            localKeys: localKeys,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(remoteProps.longTermPublicKey),
                oneTime: remoteProps.oneTimePublicKey,
                mlKEM: remoteProps.mlKEMPublicKey),
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
        
        guard let remoteFrameProps = call.frameIdentityProps else {
            logger.log(level: .error, message: "Call will not proceed the session identity for sender is missing, Call will not proceed the frame session identity for sender is missing, Call: \(call)")
            return
        }
        
        guard let remoteSignalingProps = call.signalingIdentityProps else {
            logger.log(level: .error, message: "Call will not proceed the session identity for sender is missing, Call will not proceed the signalling session identity for sender is missing, Call: \(call)")
            return
        }
        
        _ = try await createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: remoteFrameProps)
        _ = try await pcKeyManager.createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: remoteSignalingProps)
        
        let localFrameIdentity: ConnectionLocalIdentity
        if let existing = try await fetchLocalIdentity() {
            localFrameIdentity = existing
        } else {
            localFrameIdentity = try await generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: recipient)
        }
        
        let localSignalingIdentity: ConnectionLocalIdentity
        if let existing = try await pcKeyManager.fetchCallKeyBundle() {
            localSignalingIdentity = existing
        } else {
            localSignalingIdentity = try await pcKeyManager.generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: recipient)
        }
        
        guard let frameProps = await localFrameIdentity.sessionIdentity.props(symmetricKey: localFrameIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local frame identity props are missing")
        }
        guard let signalingProps = await localSignalingIdentity.sessionIdentity.props(symmetricKey: localSignalingIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local signaling identity props are missing")
        }
        
        var call = call
        call.frameIdentityProps = frameProps
        call.signalingIdentityProps = signalingProps
        
        if await !hasConnection(id: call.sharedCommunicationId) {
            
            _ = try await createPeerConnection(
                with: call,
                sender: call.sender.secretName,
                recipient: recipient,
                localIdentity: localFrameIdentity,
                willFinishNegotiation: true)
        } else {
            if var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
                connection.sessionIdentity = localFrameIdentity.sessionIdentity
                await connectionManager.updateConnection(id: call.sharedCommunicationId, with: connection)
            }
        }
        
        guard let connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
            throw RTCErrors.connectionNotFound
        }
        
        let initialState = connection.cipherNegotiationState
        logger.log(level: .info, message: "Received ciphertext for connectionId: \(connection.id) in cipher negotiation state: \(initialState)")
        switch initialState {
        case .waiting, .setSenderKey:
            var connection = connection
            
            logger.log(level: .info, message: "\(connection.sender.uppercased()) received ciphertext for connectionId: \(connection.id)")
            
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
    }
    
    func sendEncryptedSfuCandidateFromDeque(_ candidate: IceCandidate, call: Call) async throws {
        // Encode candidate into call metadata and ratchet-encrypt for SFU.
        var callForWire = call
        callForWire.metadata = try BinaryEncoder().encode(candidate)
        let plaintext = try BinaryEncoder().encode(callForWire)
        
        let sfuRecipientId = call.sharedCommunicationId
        // Ensure sender initialization occurred before ratchet encrypting (idempotent).
        let recipientIdentity = try await ensureSfuSenderInitialization(call: call, sfuRecipientId: sfuRecipientId)
        let message = try await pcRatchetManager.ratchetEncrypt(
            plainText: plaintext,
            sessionId: recipientIdentity.sessionIdentity.id)
        
        let packet = RatchetMessagePacket(
            sfuIdentity: sfuRecipientId,
            header: message.header,
            ratchetMessage: message,
            flag: .candidate)
        try await requireTransport().sendSfuMessage(packet, call: call)
    }
}
