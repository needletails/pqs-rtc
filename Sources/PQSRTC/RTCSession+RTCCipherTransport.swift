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
    
    /// Resolves which participant owns inbound media for frame-key provisioning.
    ///
    /// In 1:1 SFU rooms, `resolveProperRecipient(call:)` can rewrite `call.sender` to the local
    /// participant on the answering side. If we then use `call.sender.secretName` as the remote
    /// track owner, we provision the receive key under the local participant id and the actual
    /// remote media stays undecryptable on subsequent calls.
    private func remoteTrackOwnerParticipantId(
        connection: RTCConnection,
        call: Call
    ) -> String? {
        let isSfuRoom =
            groupCall(forSfuIdentity: connection.id) != nil ||
            groupCall(forSfuIdentity: call.sharedCommunicationId) != nil
        guard isSfuRoom else { return nil }

        let localSessionParticipantId = sessionParticipant?.secretName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let senderId = call.sender.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientIds = call.recipients
            .map(\.secretName)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if call.recipients.count <= 1 {
            let remoteParticipantId = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
            let localParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
            let roomNorm = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
            let remoteNorm = remoteParticipantId.normalizedConnectionId
            let isRoomRoutedRemoteId = !roomNorm.isEmpty && remoteNorm.caseInsensitiveCompare(roomNorm) == .orderedSame

            // Group / conference SFU PCs use the **room id** as `recipient` (see `beginGroupCallMediaAfterSfuRegistrationIfNeeded`).
            // That string is signaling routing, not the owner of inbound RTP `msid`/stream labels — using it here
            // provisions frame keys under `conf-…` while FrameCryptors resolve `nudge`/`echo`/UUID stream ids → missingKey / no video.
            if !remoteParticipantId.isEmpty,
               remoteParticipantId != localParticipantId,
               !isRoomRoutedRemoteId {
                return remoteParticipantId
            }

            if !localSessionParticipantId.isEmpty, senderId == localSessionParticipantId {
                return recipientIds.first
            }
        }

        return senderId.isEmpty ? recipientIds.first : senderId
    }
    
    public func createCryptoPeerConnection(with call: Call) async throws {
        logger.log(level: .info, message: "Starting CreateCryptoPeerConnection")
        var call = call
        call.sharedCommunicationId = call.sharedCommunicationId.normalizedConnectionId
        
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId.normalizedConnectionId
        
        // Ensure RTC state streams are created so the UI can observe call state for 1-to-1 calls
        guard let recipient = call.recipients.first else {
            throw PQSRTC.CallError.invalidMetadata("Call must have a recipient")
        }
        
        // Copy remote identity props before we write over them
        guard let remoteFrameProps = call.frameIdentityProps else {
            throw RTCErrors.invalidConfiguration("Call must have a frame identity")
        }
        guard let remoteSignalingProps = call.signalingIdentityProps else {
            throw RTCErrors.invalidConfiguration("Call must have a signaling identity")
        }
        
        do {
            _ = try await keyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId)
        } catch {
            _ = try await keyManager.createRecipientIdentity(
                connectionId: call.sharedCommunicationId,
                props: remoteFrameProps)
        }
        
        do {
            _ = try await pcKeyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId)
        } catch {
            _ = try await pcKeyManager.createRecipientIdentity(
                connectionId: call.sharedCommunicationId,
                props: remoteSignalingProps)
        }
        
        let frameLocalIdentity: ConnectionLocalIdentity
        if let existingIdentity = try? await keyManager.fetchCallKeyBundle() {
            frameLocalIdentity = existingIdentity
        } else {
            frameLocalIdentity = try await keyManager.generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: call.sender.secretName)
        }
        
        let signalingLocalIdentity: ConnectionLocalIdentity
        if let existingIdentity = try? await pcKeyManager.fetchCallKeyBundle() {
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
        let resolvedCall: Call
        if sessionParticipant == nil {
            // Some inbound 1:1 flows can receive `call_cipher` before the app has restored the
            // local session participant into RTCSession. Avoid aborting the entire handshake:
            // infer direction from `shouldOffer` and normalize the call shape just for this step.
            logger.log(
                level: .warning,
                message: "Session participant missing while finishing crypto session for \(call.sharedCommunicationId); inferring local/remote participants from current call direction"
            )
            if shouldOffer {
                resolvedCall = call
            } else {
                guard let recipient = call.recipients.first else {
                    throw RTCErrors.invalidConfiguration("Received ciphertext without a recipient in call")
                }
                var normalizedCall = call
                let remoteSender = normalizedCall.sender
                normalizedCall.sender = recipient
                normalizedCall.recipients = [remoteSender]
                resolvedCall = normalizedCall
            }
        } else {
            resolvedCall = try resolveProperRecipient(call: call)
        }
        // 1:1 fix: use normalized remote recipient after call-shape resolution.
        // For multi-recipient/group payloads, preserve previous behavior to avoid
        // changing established routing semantics.
        let recipient: Call.Participant
        if resolvedCall.recipients.count <= 1 {
            guard let resolvedRecipient = resolvedCall.recipients.first else {
                throw RTCErrors.invalidConfiguration("Received ciphertext without a resolved recipient in call")
            }
            recipient = resolvedRecipient
        } else {
            recipient = call.sender
        }
        
        // Treat `sharedCommunicationId` as a UUID; accepted wrappers:
        // `#uuid`, `conf-uuid`, and `#conf-uuid`.
        let uuidString = resolvedCall.sharedCommunicationId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedUUIDConnectionId
        guard let callId = UUID(uuidString: uuidString) else {
            throw RTCErrors.invalidConfiguration("Call has an invalid UUID as sharedCommunicationId (expected UUID/#UUID/conf-UUID/#conf-UUID)")
        }
        pendingAnswerCallId = callId
        if callAnswerStatesById[callId] == nil {
            callAnswerStatesById[callId] = .pending
        }
        
        try await receiveCiphertext(
            recipient: recipient.secretName,
            ciphertext: ciphertext,
            call: resolvedCall)
        
        logger.log(level: .info, message: "We are going to offer? \(shouldOffer ? "YES" : "NO")")
        if shouldOffer {
            let connId = resolvedCall.sharedCommunicationId
            guard !offerInFlightConnectionIds.contains(connId) else {
                logger.log(
                    level: .warning,
                    message: "Offer already in flight for \(connId); skipping duplicate to avoid m-line mismatch"
                )
                return resolvedCall
            }
            offerInFlightConnectionIds.insert(connId)
            defer { offerInFlightConnectionIds.remove(connId) }
            switch await connectionManager.findConnection(with: connId)?.cipherNegotiationState {
            case .complete:
                var resolvedCall = try await createOffer(call: resolvedCall)
                
                let keyBundle = try await pcKeyManager.fetchCallKeyBundle()
                guard let localProps = await keyBundle.sessionIdentity.props(symmetricKey: keyBundle.symmetricKey) else {
                    throw RTCErrors.invalidConfiguration("Local Props are missing")
                }
                
                //If we are Offering we need to feed our already created local signaling identity.
                resolvedCall.signalingIdentityProps = localProps
                
                // Encrypt and send (roomId normalized; "#" reattached at transport).
                let offerPlaintext = try BinaryEncoder().encode(resolvedCall)
                let writeTask = WriteTask(
                    data: offerPlaintext,
                    roomId: resolvedCall.sharedCommunicationId.normalizedConnectionId,
                    flag: .offer,
                    call: resolvedCall)
                let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
                try await taskProcessor.feedTask(task: encryptableTask)
                return resolvedCall
            default:
                // Transient race: peer connection may exist but cipher negotiation can still be
                // catching up (or recovering from key reconciliation). Tearing down the whole call
                // here causes "capture started then stopped" and drops otherwise recoverable calls.
                // Keep the call alive and let the next signaling/cipher tick retry offer creation.
                logger.log(
                    level: .warning,
                    message: "Skipping offer creation because cipherNegotiationState is not complete yet for call \(resolvedCall.sharedCommunicationId); preserving active call for retry"
                )
                return resolvedCall
            }
        } else {
            return resolvedCall
        }
    }
    
#if canImport(WebRTC)
    enum TrackKind: Sendable {
        case videoSender(RTCRtpSender), videoReceiver(RTCRtpReceiver), audioSender(RTCRtpSender), audioReceiver(RTCRtpReceiver)
        case screenSender(RTCRtpSender), screenReceiver(RTCRtpReceiver)
    }

#endif
    
    //MARK: Key Derivation & Cleanup
    
    /// Applies a frame-encryption key for a participant.
    ///
    /// In `shared` mode the participantId is ignored and the key is applied to the shared key ring.
    /// In `perParticipant` mode the key is applied to the given participant.
    public func setFrameEncryptionKey(_ key: Data, index: Int, for participantId: String) async {
#if canImport(WebRTC)
        guard enableEncryption else { return }
        ensureFrameKeyProviderIfNeeded()
        guard let keyProvider else {
            logger.log(level: .error, message: "❌ FrameCryptorKeyProvider is nil; cannot set frame key (enableEncryption=true)")
            return
        }
        if frameEncryptionKeyMode == .shared {
            keyProvider.setSharedKey(key, with: Int32(index))
        } else {
            keyProvider.setKey(key, with: Int32(index), forParticipant: participantId)
        }
#elseif os(Android)
        guard enableEncryption else { return }
        if frameEncryptionKeyMode == .shared {
            rtcClient.setSharedKey(
                key,
                with: Int32(index),
                ratchetSalt: ratchetSalt)
        } else {
            rtcClient.setKey(
                key,
                with: Int32(index),
                forParticipant: participantId,
                ratchetSalt: ratchetSalt)
        }
#endif
        // Track provisioning for diagnostics (safe metadata only).
        lastFrameKeyIndexByParticipantId[participantId] = index
        
        // Diagnostics: prove which participantId/index we provisioned (without logging key bytes).
        // Keep at debug to avoid log noise in production.
        let mode = frameEncryptionKeyMode
        if mode == .shared {
            logger.log(level: .debug, message: "🔑 Provisioned shared frame key index=\(index) (participantId ignored)")
        } else {
            logger.log(level: .debug, message: "🔑 Provisioned per-participant frame key index=\(index) for participantId='\(participantId)'")
        }
    }
    
#if canImport(WebRTC)
    /// Ratchets and returns the next key for a participant/index.
    ///
    /// Note: This is optional for some designs; many deployments distribute derived
    /// keys via the control plane instead of requiring local ratcheting by receivers.
    public func ratchetFrameEncryptionKey(index: Int, for participantId: String) -> Data {
        guard enableEncryption else { return Data() }
        ensureFrameKeyProviderIfNeeded()
        guard let keyProvider else {
            logger.log(level: .error, message: "❌ FrameCryptorKeyProvider is nil; cannot ratchet frame key (enableEncryption=true)")
            return Data()
        }
        if frameEncryptionKeyMode == .shared {
            return keyProvider.ratchetSharedKey(Int32(index))
        } else {
            return keyProvider.ratchetKey(participantId, with: Int32(index))
        }
    }
    
    /// Exports the current key for a participant/index.
    public func exportFrameEncryptionKey(index: Int, for participantId: String) -> Data {
        guard enableEncryption else { return Data() }
        ensureFrameKeyProviderIfNeeded()
        guard let keyProvider else {
            logger.log(level: .error, message: "❌ FrameCryptorKeyProvider is nil; cannot export frame key (enableEncryption=true)")
            return Data()
        }
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
        guard enableEncryption else { return }
        ensureFrameKeyProviderIfNeeded()
        guard let keyProvider else {
            logger.log(level: .error, message: "❌ FrameCryptorKeyProvider is nil; cannot create FrameCryptor (enableEncryption=true)")
            return
        }
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
            
            videoFrameCryptor.delegate = frameCryptorDelegate
            videoFrameCryptor.enabled = true
            connection.videoSenderCryptor = videoFrameCryptor
        case .videoReceiver(let receiver):
            
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
        case .screenSender(let sender):
            let screenCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpSender: sender,
                participantId: connection.localParticipantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)

            guard let screenCryptor else {
                logger.log(level: .error, message: "Failed to create screen sender FrameCryptor")
                return
            }

            screenCryptor.delegate = frameCryptorDelegate
            screenCryptor.enabled = true
            connection.screenSenderCryptor = screenCryptor
        case .screenReceiver(let receiver):
            let screenCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpReceiver: receiver,
                participantId: participantIdOverride ?? connection.remoteParticipantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)

            guard let screenCryptor else {
                logger.log(level: .error, message: "Failed to create screen receiver FrameCryptor")
                return
            }

            screenCryptor.delegate = frameCryptorDelegate
            screenCryptor.enabled = true
            let screenReceiverKey = participantIdOverride ?? connection.remoteParticipantId
            connection.screenReceiverCryptorsByParticipantId[screenReceiverKey] = screenCryptor
        }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }
    
#elseif os(Android)
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
        // Only apply media key to the WebRTC FrameCryptorKeyProvider when frame encryption is enabled.
        if enableEncryption {
            ensureFrameKeyProviderIfNeeded()
            guard let keyProvider else {
                throw RTCErrors.invalidConfiguration("FrameCryptorKeyProvider is nil (enableEncryption=true)")
            }
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
            
            // Diagnostics: show which participant ids got provisioned from the 1:1 ratchet-derived key.
            if frameEncryptionKeyMode == .shared {
                logger.log(level: .debug, message: "🔑 Derived+provisioned shared frame key (setMessageKey) index=\(index) connId=\(connection.id)")
            } else {
                logger.log(level: .debug, message: "🔑 Derived+provisioned per-participant frame key (setMessageKey) index=\(index) connId=\(connection.id) local='\(connection.localParticipantId)' remote='\(connection.remoteParticipantId)'")
            }
        }
#elseif os(Android)
        // Only provision frame keys on Android when frame encryption is enabled.
        // JNI keyProvider calls must run on main thread; MainActor ensures that.
        if enableEncryption {
            if frameEncryptionKeyMode == .shared {
                rtcClient.setSharedKey(
                    messageKey,
                    with: Int32(index),
                    ratchetSalt: ratchetSalt)
            } else {
                // For 1:1, provision both local+remote IDs with the same key so send/recv match.
                rtcClient.setKey(
                    messageKey,
                    with: Int32(index),
                    forParticipant: connection.localParticipantId,
                    ratchetSalt: ratchetSalt)
                rtcClient.setKey(
                    messageKey,
                    with: Int32(index),
                    forParticipant: connection.remoteParticipantId,
                    ratchetSalt: ratchetSalt)
            }
            // Mirror Apple: attach sender FrameCryptors once the key is set (in case tracks were added before key derivation).
            try await createEncryptedFrame(connection: connection)
        }
#endif
    }
    
    /// Applies the derived receive key to the frame cryptor key provider.
    /// - Parameters:
    ///   - connection: The connection for which the cipher was received.
    ///   - ciphertext: The received ciphertext used to derive the key.
    ///   - remoteTrackOwnerParticipantId: When non-nil, use this as the remote participant id for the frame key.
    ///     Use this for one-to-one group calls (SFU room): the connection has `remoteParticipantId == roomId`,
    ///     but the actual track owner is the cipher sender (e.g. call.sender.secretName). Pass that here so
    ///     the receiver FrameCryptor can decrypt tracks from that participant.
    func setReceivingMessageKey(
        connection: RTCConnection,
        ciphertext: Data,
        remoteTrackOwnerParticipantId: String? = nil
    ) async throws {
        let (messageKey, index) = try await deriveReceivedMessageKey(
            connectionId: connection.id,
            participant: connection.sender,
            localKeys: connection.localKeys,
            symmetricKey: connection.symmetricKey,
            sessionIdentity: connection.sessionIdentity,
            ciphertext: ciphertext)
        
        let remoteParticipantId = remoteTrackOwnerParticipantId ?? connection.remoteParticipantId
        
#if canImport(WebRTC)
        // Only apply frame keys when frame encryption is enabled.
        if enableEncryption {
            ensureFrameKeyProviderIfNeeded()
            guard let keyProvider else {
                throw RTCErrors.invalidConfiguration("FrameCryptorKeyProvider is nil (enableEncryption=true)")
            }
            if frameEncryptionKeyMode == .shared {
                // Shared-key mode: same media key & index is used for decrypting frames, independent of participantId.
                keyProvider.setSharedKey(messageKey, with: Int32(index))
            } else {
                // Per-participant mode: provision local + remote track owner with the same key.
                // For 1:1-group (room connection), remoteTrackOwnerParticipantId is the cipher sender (track owner).
                keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId)
                keyProvider.setKey(messageKey, with: Int32(index), forParticipant: remoteParticipantId)
            }
            
            // Diagnostics: show which ids got provisioned for receiving.
            if frameEncryptionKeyMode == .shared {
                logger.log(level: .debug, message: "🔑 Derived+provisioned shared frame key (setReceivingMessageKey) index=\(index) connId=\(connection.id)")
            } else {
                logger.log(level: .debug, message: "🔑 Derived+provisioned per-participant frame key (setReceivingMessageKey) index=\(index) connId=\(connection.id) local='\(connection.localParticipantId)' remoteTrackOwner='\(remoteParticipantId)'")
            }
        }
#elseif os(Android)
        if enableEncryption {
            // JNI keyProvider calls must run on main thread; MainActor ensures that.
            if frameEncryptionKeyMode == .shared {
                // Match Apple as closely as possible: set the shared media key at the moment
                // we derive it for receiving.
                rtcClient.setSharedKey(
                    messageKey,
                    with: Int32(index),
                    ratchetSalt: ratchetSalt)
            } else {
                // For 1:1 / 1:1-group, provision both local+remote IDs with the same key.
                rtcClient.setKey(
                    messageKey,
                    with: Int32(index),
                    forParticipant: connection.localParticipantId,
                    ratchetSalt: ratchetSalt)
                rtcClient.setKey(
                    messageKey,
                    with: Int32(index),
                    forParticipant:remoteParticipantId,
                    ratchetSalt: ratchetSalt)
            }
            
            // Attach receiver cryptors (Android needs explicit receiver attachment).
            // For inbound media, participantId must be the REMOTE track owner.
            rtcClient.createReceiverEncryptedFrame(
                participant: remoteParticipantId,
                connectionId: connection.id)
        }
#endif
    }
    
    private func deriveMessageKey(
        connection: RTCConnection,
        call: Call
    ) async throws -> (Data, Int) {
        var connection = connection
        
        let remoteConnectionIdentity = try await keyManager.fetchConnectionIdentity(connection: connection.id)
        guard let remoteProps = await remoteConnectionIdentity.sessionIdentity.props(symmetricKey: remoteConnectionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote peer did not provide a valid connection identity")
        }
        
        //        let lltk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: connection.localKeys.longTerm.rawRepresentation).publicKey.rawRepresentation.base64EncodedString().prefix(10)
        //        logger.log(level: .info, message: "WILL DO SENDER INITIALIZATION:\n Local LTK: \(lltk)\n Local OTK: \(connection.localKeys.oneTime?.id)\n Local MLK: \(connection.localKeys.mlKEM.id)\n Remote LTK: \(remoteProps.longTermPublicKey.base64EncodedString().prefix(10))\n Remote OTK: \(remoteProps.oneTimePublicKey?.id)\n Remote MLK: \(remoteProps.mlKEMPublicKey.id)")
        
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
        
        //        guard let localProps = await sessionIdentity.props(symmetricKey: symmetricKey) else {
        //            throw EncryptionErrors.missingProps
        //        }
        //        
        let remoteConnectionIdentity = try await keyManager.fetchConnectionIdentity(connection: connectionId)
        guard let remoteProps = await remoteConnectionIdentity.sessionIdentity.props(symmetricKey: remoteConnectionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote peer did not provide a valid connection identity")
        }
        
        guard !ciphertext.isEmpty else {
            throw EncryptionErrors.missingCipherText
        }
        
        //        let lltk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localKeys.longTerm.rawRepresentation).publicKey.rawRepresentation.base64EncodedString().prefix(10)
        //        logger.log(level: .info, message: "WILL DO RECIPIENT INITIALIZATION:\n Local LTK: \(lltk)\n Local OTK: \(localKeys.oneTime?.id)\n Local MLK: \(localKeys.mlKEM.id)\n Remote LTK: \(remoteProps.longTermPublicKey.base64EncodedString().prefix(10))\n Remote OTK: \(remoteProps.oneTimePublicKey?.id)\n Remote MLK: \(remoteProps.mlKEMPublicKey.id)")
        
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
        
        do {
            _ = try await keyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId)
        } catch {
            _ = try await keyManager.createRecipientIdentity(
                connectionId: call.sharedCommunicationId,
                props: remoteFrameProps)
        }
        
        do {
            _ = try await pcKeyManager.fetchConnectionIdentity(connection: call.sharedCommunicationId)
        } catch {
            _ = try await pcKeyManager.createRecipientIdentity(
                connectionId: call.sharedCommunicationId,
                props: remoteSignalingProps)
        }
        
        let localFrameIdentity: ConnectionLocalIdentity
        if let existing = try? await keyManager.fetchCallKeyBundle() {
            localFrameIdentity = existing
        } else {
            localFrameIdentity = try await keyManager.generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: recipient)
        }
        
        let localSignalingIdentity: ConnectionLocalIdentity
        if let existing = try? await pcKeyManager.fetchCallKeyBundle() {
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
            _ = try await keyManager.fetchConnectionIdentity(connection: connection.id)
            
            // Store ciphertext in keyManager for this connection (for ratcheting purposes)
            await keyManager.storeCiphertext(connectionId: connection.id, ciphertext: ciphertext)
            
            let remoteTrackOwner = remoteTrackOwnerParticipantId(connection: connection, call: call)
            
#if canImport(WebRTC)
            let hasVideoReceiver = connection.peerConnection.receivers.contains { $0.track?.kind == kRTCMediaStreamTrackKindVideo }
            let hasAudioReceiver = connection.peerConnection.receivers.contains { $0.track?.kind == kRTCMediaStreamTrackKindAudio }
            logger.log(level: .info, message: "\(hasVideoReceiver ? "Has video receiver" : "Missing video receiver") \(hasAudioReceiver ? "Has audio receiver" : "Missing audio receiver")")
            
            if hasVideoReceiver || hasAudioReceiver {
                let norm = connection.id.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
                pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId.removeValue(forKey: norm)
                logger.log(level: .info, message: "🚀 Receivers available, completing ciphertext handshake")
                try await setReceivingMessageKey(connection: connection, ciphertext: ciphertext, remoteTrackOwnerParticipantId: remoteTrackOwner)
                logger.log(level: .info, message: "👌 Handshake complete")
            } else {
                let norm = connection.id.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
                pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId[norm] = PendingAppleDeferredReceiveFrameKeyContext(
                    remoteTrackOwnerParticipantId: remoteTrackOwner)
                logger.log(level: .info, message: "⏳ Receivers not yet available, will set up cryptor when receivers start")
            }
#else
            // Android PeerConnection APIs differ. We attempt setup here and let AndroidRTCClient
            // decide whether receivers are present when attaching FrameCryptors.
            logger.log(level: .info, message: "(Android) Attempting receiver cryptor setup after handshake")
            try await setReceivingMessageKey(connection: connection, ciphertext: ciphertext, remoteTrackOwnerParticipantId: remoteTrackOwner)
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
                // Always respond with our ciphertext so signaling can proceed.
                // FrameCryptor (media frame encryption) is independently gated by `enableEncryption`.
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
        
        // Ensure sender initialization occurred before ratchet encrypting (idempotent). roomId normalized; "#" reattached at transport.
        let writeTask = WriteTask(
            data: plaintext,
            roomId: call.sharedCommunicationId.normalizedConnectionId,
            flag: .candidate,
            call: call)
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)
    }
}

#if canImport(WebRTC)
extension RTCSession {
    /// Completes receive-side frame key provisioning when ciphertext arrived before any RTP receiver (Apple).
    func tryCompleteAppleDeferredReceivingMessageKey(connectionId: String) async {
        guard enableEncryption else { return }
        let norm = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !norm.isEmpty else { return }
        guard pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId[norm] != nil else { return }
        guard let connection = await connectionManager.findConnection(with: connectionId) else { return }
        let hasVideoReceiver = connection.peerConnection.receivers.contains { $0.track?.kind == kRTCMediaStreamTrackKindVideo }
        let hasAudioReceiver = connection.peerConnection.receivers.contains { $0.track?.kind == kRTCMediaStreamTrackKindAudio }
        guard hasVideoReceiver || hasAudioReceiver else { return }
        guard let ciphertext = await keyManager.fetchCiphertext(connectionId: connection.id), !ciphertext.isEmpty else { return }
        guard let ctx = pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId[norm] else { return }
        do {
            try await setReceivingMessageKey(
                connection: connection,
                ciphertext: ciphertext,
                remoteTrackOwnerParticipantId: ctx.remoteTrackOwnerParticipantId)
            pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId.removeValue(forKey: norm)
            logger.log(level: .info, message: "Completed deferred receiving message key after receivers appeared (connId=\(connection.id))")
        } catch {
            logger.log(level: .error, message: "Deferred setReceivingMessageKey failed (will retry on next receiver event): \(error)")
        }
    }

    // MARK: - Test hooks (package-internal; used by `PQSRTCCompiledSwiftTests`)

    internal func testing_seedPendingAppleDeferredReceiveFrameKeyForTests(
        normalizedConnectionId: String,
        remoteTrackOwnerParticipantId: String? = nil
    ) {
        let key = normalizedConnectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !key.isEmpty else { return }
        pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId[key] = PendingAppleDeferredReceiveFrameKeyContext(
            remoteTrackOwnerParticipantId: remoteTrackOwnerParticipantId)
    }

    internal func testing_pendingAppleDeferredReceiveFrameKeyEntryCount() -> Int {
        pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId.count
    }
}
#endif
