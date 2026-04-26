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
    /// True iff this call should use 1:1 SFU symmetric frame-key slots (local + peer), not
    /// per-peer group slots.
    ///
    /// Nudge's 1:1 relay sets `channelWireId` to the same IRC room as `sharedCommunicationId`
    /// (`#<uuid>` / UUID). Merges can bump `recipients.count` to 2 without introducing a second
    /// peer — we still must treat that as 1:1 relay. True multi-party UUID SFU rooms are excluded
    /// when there is more than one distinct recipient `secretName`.
    ///
    /// In this shape both endpoints can safely share the same per-message key in both the local
    /// and remote frame-key slots; for multi-party calls Double-Ratchet produces a distinct key
    /// per direction/peer and slot mirroring corrupts other peers' keys.
    internal static func isTrueOneToOneSfuRoom(call: Call) -> Bool {
        let commNorm = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if commNorm.hasPrefix("conf-") { return false }

        // Guard against plain direct 1:1 P2P calls (UUID communication id + no SFU wire route).
        // Those calls must not enter 1:1-SFU-only paths (shared frame-key ring, offerer role, etc.).
        guard isEphemeralSfuWireMatchesCommunication(call: call) else { return false }

        let distinctPeers = Set(
            call.recipients.map {
                $0.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )
        if distinctPeers.count > 1 { return false }
        return true
    }

    /// `groupCallNegotiation` sets `channelWireId` to the same room string as the RTC identity for Nudge 1:1-as-SFU relay.
    private static func isEphemeralSfuWireMatchesCommunication(call: Call) -> Bool {
        let commNorm = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard UUID(uuidString: commNorm) != nil else { return false }
        let wire = call.channelWireId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wire.isEmpty else { return false }
        return wire.normalizedConnectionId == commNorm
    }

    internal static func resolveRemoteFrameKeyParticipantIdForSetMessageKey(
        call: Call,
        connectionRemoteParticipantId: String,
        oneToOneResolvedRemoteTrackOwner: String?
    ) -> String {
        if isTrueOneToOneSfuRoom(call: call) {
            return oneToOneResolvedRemoteTrackOwner ?? connectionRemoteParticipantId
        }
        return connectionRemoteParticipantId
    }
    
    
    /// Resolves which participant owns inbound media for frame-key provisioning.
    ///
    /// In 1:1 SFU rooms, `resolveProperRecipient(call:)` can rewrite `call.sender` to the local
    /// participant on the answering side. If we then use `call.sender.secretName` as the remote
    /// track owner, we provision the receive key under the local participant id and the actual
    /// remote media stays undecryptable on subsequent calls.
    ///
    /// - Note: Group SFU PCs use the **room id** as `RTCConnection.recipient` for routing; the
    ///   remote peer still encrypts with their `localParticipantId` (secretName). Frame keys must
    ///   be provisioned under that peer id, not the room string, or receiver FrameCryptors never
    ///   resolve keys (no remote video).
    func remoteTrackOwnerParticipantId(
        connection: RTCConnection,
        call: Call
    ) -> String? {
        // Fast path: single-recipient call where `recipient` is the room id — map to the peer's
        // secretName even if `groupCall(forSfuIdentity:)` is not registered yet (startup races).
        if call.recipients.count == 1 {
            let peer = call.recipients[0].secretName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !peer.isEmpty {
                let roomNorm = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
                let remoteNorm = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
                if !roomNorm.isEmpty,
                   remoteNorm.caseInsensitiveCompare(roomNorm) == .orderedSame {
                    return peer
                }
            }
        }

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

    /// Second participant id for ``setMessageKey`` in per-participant mode.
    ///
    /// For **1:1 SFU** calls, `RTCConnection.recipient` is the room id; we map to the peer's
    /// `secretName` so keys match sender/receiver FrameCryptors. For **multi-party** channel/group
    /// SFU calls, `remoteTrackOwnerParticipantId` can resolve to `call.sender` (same as local) —
    /// keep the **room id** as the routing key like pre-1:1 fix behavior.
    private func remoteFrameKeyParticipantIdForSetMessageKey(
        connection: RTCConnection,
        call: Call
    ) -> String {
        return Self.resolveRemoteFrameKeyParticipantIdForSetMessageKey(
            call: call,
            connectionRemoteParticipantId: connection.remoteParticipantId,
            oneToOneResolvedRemoteTrackOwner: remoteTrackOwnerParticipantId(connection: connection, call: call)
        )
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
        
        // Preserve UUID room ids as-is, and derive a stable UUID for shorter production room codes.
        let callId = resolvedCall.sharedCommunicationId.stableUUIDConnectionId
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
                // SFU group / 1:1-as-SFU: the first encrypted offer is already emitted from
                // `beginGroupCallMediaAfterSfuRegistrationIfNeeded` → `sendGroupCallOffer`.
                // Running `createOffer` again after `call_cipher` completes leaves the PC in
                // `have-local-offer` and the next inbound SFU SDP (`offer`) fails with
                // "CALLED IN WRONG STATE: HAVE-LOCAL-OFFER".
                let normId = teardownConnectionIdKey(resolvedCall.sharedCommunicationId)
                let initialOfferSent = initialSfuGroupMediaOfferSentConnectionIds.contains(normId)
                let initialOfferBootstrapInFlight = pendingInitialSfuGroupOfferConnectionIds.contains(normId)
                // Guard both states:
                // 1) initial offer already sent
                // 2) initial offer still bootstrapping (post-cipher can race this marker)
                // In both cases a post-cipher `createOffer` can leave the PC in `have-local-offer`
                // and crash on the next inbound SFU offer with SDPHandlerError 3.
                if initialOfferSent || initialOfferBootstrapInFlight {
                    // Do **not** call `createOffer` again (breaks signaling). Still send refreshed
                    // `Call` (same SDP in metadata + updated ratchet props), but use
                    // `.handshakeComplete` — not `.offer`. A second `.offer` makes the SFU run
                    // `setRemoteDescription(offer)` while a leg can still be `have-local-offer`
                    // (glare with the answerer's post-cipher offer), which matches server
                    // `SETREMOTEDESCRIPTION(OFFER) FAILED: HAVE-LOCAL-OFFER` and loses media.
                    logger.log(
                        level: .info,
                        message: "Skipping post-cipher WebRTC createOffer (initialOfferSent=\(initialOfferSent) bootstrapInFlight=\(initialOfferBootstrapInFlight)); sending refreshed SFU identity payload (.handshakeComplete) for \(resolvedCall.sharedCommunicationId)"
                    )
                    do {
                        var refreshed = try await buildPostCipherSfuGroupOfferPayloadPreservingLocalSdp(call: resolvedCall)
                        let payload = try BinaryEncoder().encode(refreshed)
                        let writeTask = WriteTask(
                            data: payload,
                            roomId: refreshed.sharedCommunicationId.normalizedConnectionId,
                            flag: .handshakeComplete,
                            call: refreshed)
                        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
                        try await taskProcessor.feedTask(task: encryptableTask)
                        return refreshed
                    } catch {
                        // During very early bootstrap, local SDP can still be unavailable. Avoid
                        // re-entering `createOffer` here; preserving current signaling state is safer.
                        logger.log(
                            level: .warning,
                            message: "Skipping post-cipher identity refresh payload because local SDP is not ready yet for \(resolvedCall.sharedCommunicationId): \(error.localizedDescription)"
                        )
                        return resolvedCall
                    }
                }
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
            let useSharedFrameKeyRingForOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: call)
            if frameEncryptionKeyMode == .shared || useSharedFrameKeyRingForOneToOneSfu {
                keyProvider.setSharedKey(messageKey, with: Int32(index))
                let modeLabel = useSharedFrameKeyRingForOneToOneSfu ? "1:1 SFU forced-shared" : "shared"
                logger.log(level: .info, message: "🔑 Derived+provisioned \(modeLabel) frame key (setMessageKey) index=\(index) connId=\(connection.id)")
            } else {
                // Always provision the local sender slot — that's what our sender FrameCryptor
                // (bound with participantId == connection.localParticipantId) reads to encrypt.
                keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId)
                lastFrameKeyIndexByParticipantId[connection.localParticipantId] = index

                // True 1:1 SFU room: optionally mirror into the remote slot as a bootstrap aid.
                // IMPORTANT: only do this if the remote slot is empty. If receive-side derivation
                // already provisioned that slot, clobbering it with our send key breaks decrypt.
                if Self.isTrueOneToOneSfuRoom(call: call) {
                    let remoteForFrameKeys = remoteFrameKeyParticipantIdForSetMessageKey(connection: connection, call: call)
                    if lastFrameKeyIndexByParticipantId[remoteForFrameKeys] == nil {
                        keyProvider.setKey(messageKey, with: Int32(index), forParticipant: remoteForFrameKeys)
                        lastFrameKeyIndexByParticipantId[remoteForFrameKeys] = index
                        logger.log(
                            level: .debug,
                            message: "🔑 Derived+provisioned per-participant frame key (setMessageKey, 1:1 SFU bootstrap mirror) index=\(index) connId=\(connection.id) local='\(connection.localParticipantId)' remoteFrameKeyTarget='\(remoteForFrameKeys)'"
                        )
                    } else {
                        logger.log(
                            level: .debug,
                            message: "🔑 Skipped setMessageKey mirror for existing remote slot (1:1 SFU) participantId='\(remoteForFrameKeys)' connId=\(connection.id)"
                        )
                    }
                } else {
                    logger.log(
                        level: .debug,
                        message: "🔑 Derived+provisioned per-participant frame key (setMessageKey, group/conf) index=\(index) connId=\(connection.id) local='\(connection.localParticipantId)' (per-peer remote slots populated on receive)"
                    )
                }
            }
        }
#elseif os(Android)
        // Only provision frame keys on Android when frame encryption is enabled.
        // JNI keyProvider calls must run on main thread; MainActor ensures that.
        if enableEncryption {
            let useSharedFrameKeyRingForOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: call)
            if frameEncryptionKeyMode == .shared || useSharedFrameKeyRingForOneToOneSfu {
                rtcClient.setSharedKey(
                    messageKey,
                    with: Int32(index),
                    ratchetSalt: ratchetSalt)
            } else {
                rtcClient.setKey(
                    messageKey,
                    with: Int32(index),
                    forParticipant: connection.localParticipantId,
                    ratchetSalt: ratchetSalt)
                lastFrameKeyIndexByParticipantId[connection.localParticipantId] = index

                // True 1:1 SFU only: bootstrap mirror into remote slot (Android parity with Apple).
                // Skip if the slot is already populated to avoid clobbering receive keys.
                if Self.isTrueOneToOneSfuRoom(call: call) {
                    let remoteForFrameKeys = remoteFrameKeyParticipantIdForSetMessageKey(connection: connection, call: call)
                    if lastFrameKeyIndexByParticipantId[remoteForFrameKeys] == nil {
                        rtcClient.setKey(
                            messageKey,
                            with: Int32(index),
                            forParticipant: remoteForFrameKeys,
                            ratchetSalt: ratchetSalt)
                        lastFrameKeyIndexByParticipantId[remoteForFrameKeys] = index
                    }
                }
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
        if !Self.isTrueOneToOneSfuRoom(call: connection.call),
           remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
           ) == .orderedSame {
            logger.log(
                level: .warning,
                message: "setReceivingMessageKey resolved remoteTrackOwner to local participant ('\(remoteParticipantId)') for non-1:1 connection=\(connection.id). Awaiting stable remote participant id before receiver cryptor binding."
            )
        }
        
#if canImport(WebRTC)
        // Only apply frame keys when frame encryption is enabled.
        if enableEncryption {
            ensureFrameKeyProviderIfNeeded()
            guard let keyProvider else {
                throw RTCErrors.invalidConfiguration("FrameCryptorKeyProvider is nil (enableEncryption=true)")
            }
            let useSharedFrameKeyRingForOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: connection.call)
            if frameEncryptionKeyMode == .shared || useSharedFrameKeyRingForOneToOneSfu {
                // Shared-key mode: same media key & index is used for decrypting frames, independent of participantId.
                keyProvider.setSharedKey(messageKey, with: Int32(index))
            } else {
                // Per-participant mode: this key is the receive key for the *specific* remote
                // track owner (cipher sender). Provision ONLY that slot. Mirroring it to other
                // peers' slots — or to the local slot in multi-party calls — would clobber per-peer
                // receive keys and our own send key, since Double-Ratchet derives a distinct key
                // per direction/peer.
                keyProvider.setKey(messageKey, with: Int32(index), forParticipant: remoteParticipantId)
                lastFrameKeyIndexByParticipantId[remoteParticipantId] = index

                // True 1:1 SFU room only: optional bootstrap mirror into local sender slot.
                // If local already has a sender key, do not overwrite it with receive material.
                if Self.isTrueOneToOneSfuRoom(call: connection.call) {
                    if lastFrameKeyIndexByParticipantId[connection.localParticipantId] == nil {
                        keyProvider.setKey(messageKey, with: Int32(index), forParticipant: connection.localParticipantId)
                        lastFrameKeyIndexByParticipantId[connection.localParticipantId] = index
                    } else {
                        logger.log(
                            level: .debug,
                            message: "🔑 Skipped setReceivingMessageKey local mirror for existing sender slot (1:1 SFU) participantId='\(connection.localParticipantId)' connId=\(connection.id)"
                        )
                    }
                }
            }
            
            // Diagnostics: show which ids got provisioned for receiving.
            if frameEncryptionKeyMode == .shared || useSharedFrameKeyRingForOneToOneSfu {
                let modeLabel = useSharedFrameKeyRingForOneToOneSfu ? "1:1 SFU forced-shared" : "shared"
                logger.log(level: .info, message: "🔑 Derived+provisioned \(modeLabel) frame key (setReceivingMessageKey) index=\(index) connId=\(connection.id)")
            } else {
                logger.log(level: .debug, message: "🔑 Derived+provisioned per-participant frame key (setReceivingMessageKey) index=\(index) connId=\(connection.id) local='\(connection.localParticipantId)' remoteTrackOwner='\(remoteParticipantId)'")
            }

            // Android mirrors this with `createReceiverEncryptedFrame` in the branch below. On Apple we
            // only inject into `RTCFrameCryptorKeyProvider` here; if RTP receivers were bound before
            // the receive key existed, receiver cryptors may never decrypt. Reattach for 1:1 SFU and
            // direct (non-SFU-group) calls only — multi-party group PCs share `videoFrameCryptor`
            // slots across peers and need a narrower fix than blind rebind.
            try await appleReattachReceiverFrameCryptorsAfterReceiveKey(
                connection: connection,
                provisionedRemoteTrackOwnerId: remoteParticipantId)
        }
#elseif os(Android)
        if enableEncryption {
            // JNI keyProvider calls must run on main thread; MainActor ensures that.
            let useSharedFrameKeyRingForOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: connection.call)
            if frameEncryptionKeyMode == .shared || useSharedFrameKeyRingForOneToOneSfu {
                rtcClient.setSharedKey(
                    messageKey,
                    with: Int32(index),
                    ratchetSalt: ratchetSalt)
            } else {
                // Provision ONLY the cipher sender's slot. See Apple branch for rationale.
                rtcClient.setKey(
                    messageKey,
                    with: Int32(index),
                    forParticipant: remoteParticipantId,
                    ratchetSalt: ratchetSalt)
                lastFrameKeyIndexByParticipantId[remoteParticipantId] = index

                if Self.isTrueOneToOneSfuRoom(call: connection.call) {
                    if lastFrameKeyIndexByParticipantId[connection.localParticipantId] == nil {
                        rtcClient.setKey(
                            messageKey,
                            with: Int32(index),
                            forParticipant: connection.localParticipantId,
                            ratchetSalt: ratchetSalt)
                        lastFrameKeyIndexByParticipantId[connection.localParticipantId] = index
                    }
                }
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
            
            // Default `willFinishNegotiation: false` so `setMessageKey` runs at PC creation,
            // matching the b368e83-era timing for SFU receiver-bootstrap PCs.
            _ = try await createPeerConnection(
                with: call,
                sender: call.sender.secretName,
                recipient: recipient,
                localIdentity: localFrameIdentity)
            
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
        let wireRoomId = call.resolvedChannelWireId ?? call.sharedCommunicationId
        
        // Ensure sender initialization occurred before ratchet encrypting (idempotent). roomId normalized; "#" reattached at transport.
        let writeTask = WriteTask(
            data: plaintext,
            roomId: wireRoomId.normalizedConnectionId,
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
