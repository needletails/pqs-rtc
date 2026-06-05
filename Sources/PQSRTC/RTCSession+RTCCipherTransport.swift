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
    // MARK: - 1:1 SFU frame E2EE contract
    //
    // The `call_cipher` path below is the source of truth for pairwise media-frame keys in
    // encrypted 1:1-over-SFU calls. The SFU room id is only a routing/PeerConnection identity;
    // FrameCryptor participant ids are peer identities:
    //
    // - Sender keys are installed under `connection.localParticipantId`.
    // - Receive keys are installed under the remote track owner's participant id.
    // - The `Call` sent alongside `call_cipher` must carry the sender's local
    //   `frameIdentityProps` and `signalingIdentityProps`.
    // - Each new `call_cipher` ciphertext is a fresh media-ratchet bootstrap. Do not process
    //   refreshed ciphertext as "just another frame key index" on an old receive session.
    //
    // See the DocC articles "1:1 SFU frame E2EE and call_cipher" and
    // "Group SFU frame E2EE and sender keys" before changing this flow.

    /// Sends the post-cipher media-readiness signal for true 1:1 SFU rooms exactly once.
    ///
    /// For encrypted calls, the receiver key must already be installed before this fanout. Sending
    /// `.handshakeComplete` earlier lets SFU media start while receiver FrameCryptors have no key,
    /// which presents as remote tracks attached but no rendered media.
    func sendOneToOneSfuPostCipherHandshakeCompleteIfNeeded(
        connection: RTCConnection,
        call: Call
    ) async throws {
        guard Self.isTrueOneToOneSfuRoom(call: call) else { return }
        let normId = teardownConnectionIdKey(connection.id)
        guard !oneToOneSfuPostCipherHandshakeSentConnectionIds.contains(normId) else { return }
        guard !enableEncryption || oneToOneSfuReceiveKeyReadyConnectionIds.contains(normId) else { return }
        guard let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
            call: call,
            sessionParticipant: sessionParticipant
        ) else {
            logger.log(
                level: .warning,
                message: "1:1 SFU post-cipher media readiness skipped: missing handshakeComplete fanout target for \(connection.id)"
            )
            return
        }

        let plaintext = try BinaryEncoder().encode(prepared)
        let writeTask = WriteTask(
            data: plaintext,
            roomId: prepared.sharedCommunicationId.normalizedConnectionId,
            flag: .handshakeComplete,
            call: prepared)
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)
        oneToOneSfuPostCipherHandshakeSentConnectionIds.insert(normId)
        setHandshakeComplete(true)
        logger.log(
            level: .info,
            message: "Sent 1:1 SFU media readiness after \(enableEncryption ? "receive key installed" : "FrameCryptor-disabled answer") connId=\(connection.id)"
        )
    }

    /// True iff this call uses Nudge's 1:1-over-SFU relay shape, not direct P2P or
    /// multi-party/conference SFU.
    ///
    /// Nudge's 1:1 relay sets `channelWireId` to the same IRC room as `sharedCommunicationId`
    /// (`#<uuid>` / UUID). Merges can bump `recipients.count` to 2 without introducing a second
    /// peer — we still must treat that as 1:1 relay. True multi-party UUID SFU rooms are excluded
    /// when there is more than one distinct recipient `secretName`.
    ///
    /// This helper only classifies the room shape. In per-participant E2EE, outbound media keys
    /// are still provisioned under the local sender participant id; inbound media keys are
    /// provisioned separately under the resolved remote track owner.
    internal static func isTrueOneToOneSfuRoom(call: Call) -> Bool {
        let commNorm = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if commNorm.hasPrefix("conf-") { return false }

        // Guard against plain direct 1:1 P2P calls (UUID communication id + no SFU wire route).
        // Those calls must not enter 1:1-SFU-only paths (offerer role, UUID receiver remaps, etc.).
        guard isEphemeralSfuWireMatchesCommunication(call: call) else { return false }

        let distinctPeers = Set(
            call.recipients.map {
                $0.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )
        if distinctPeers.count > 1 { return false }
        return true
    }

    /// True when media frame identity resolution still represents one remote peer.
    ///
    /// A relay payload can contain multiple devices for the same person; those entries must not
    /// force the group-key or sender-as-remote branches used for genuine multi-party rooms.
    internal static func usesPairwiseFrameIdentityResolution(call: Call) -> Bool {
        call.recipients.count <= 1 || isTrueOneToOneSfuRoom(call: call)
    }

    /// True iff an inbound 1:1-SFU `call_cipher` belongs to the active media peer device.
    ///
    /// Nudge can fan out `call_cipher` packets from sibling devices that share the same
    /// `secretName`. For true 1:1-SFU media, accepting a sibling device's frame identity can make
    /// this client refresh its sender media ratchet against the wrong device, while the active
    /// media peer keeps decrypting with the old slot. Group/conference rooms do not use this
    /// pairwise `call_cipher` media-key path, so this guard only applies to true 1:1-SFU calls.
    internal static func shouldProcessOneToOneSfuCallCipher(
        connectionCall: Call,
        inboundCall: Call
    ) -> Bool {
        guard isTrueOneToOneSfuRoom(call: connectionCall),
              isTrueOneToOneSfuRoom(call: inboundCall) else {
            return true
        }

        let inboundSecret = inboundCall.sender.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        let inboundDevice = inboundCall.sender.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inboundSecret.isEmpty, !inboundDevice.isEmpty else { return true }

        let activeDevices = ([connectionCall.sender] + connectionCall.recipients)
            .filter {
                $0.secretName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(inboundSecret) == .orderedSame
            }
            .map { $0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !activeDevices.isEmpty else { return true }
        return activeDevices.contains {
            $0.caseInsensitiveCompare(inboundDevice) == .orderedSame
        }
    }

    /// `groupCallNegotiation` sets `channelWireId` to the same room string as the RTC identity for Nudge 1:1-as-SFU relay.
    private static func isEphemeralSfuWireMatchesCommunication(call: Call) -> Bool {
        let commNorm = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard UUID(uuidString: commNorm) != nil else { return false }
        let wire = call.channelWireId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !wire.isEmpty else { return false }
        return wire.normalizedConnectionId == commNorm
    }

    /// Participant id used by ``setMessageKey`` for outbound media in per-participant mode.
    ///
    /// Sender FrameCryptors are bound to `RTCConnection.localParticipantId`, including 1:1 SFU
    /// calls where `remoteParticipantId` is the room id. Receive slots are populated by
    /// ``setReceivingMessageKey`` under the resolved remote track owner.
    internal static func senderFrameKeyParticipantIdForSetMessageKey(
        connectionLocalParticipantId: String
    ) -> String {
        connectionLocalParticipantId
    }

    /// True when media frame keys are supplied by the group sender-key/control-plane exchange.
    ///
    /// Channel-backed SFU groups and `conf-` conference rooms can contain more than one receiver
    /// for the same outbound RTP stream. A pairwise `call_cipher` bootstrap is the wrong primitive
    /// for that shape: it derives material for one remote identity, while a sender FrameCryptor can
    /// encrypt only one outbound stream under the local participant id. These rooms therefore use
    /// application-injected per-sender frame keys instead. True 1:1-over-SFU rooms intentionally
    /// stay on the `call_cipher` path.
    internal static func usesApplicationInjectedGroupFrameKeys(call: Call) -> Bool {
        guard !isTrueOneToOneSfuRoom(call: call) else { return false }

        let sharedId = call.sharedCommunicationId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedConnectionId
        if sharedId.hasPrefix("conf-") || call.conferencePassword != nil {
            return true
        }

        return call.resolvedChannelWireId != nil
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
        if Self.usesPairwiseFrameIdentityResolution(call: call),
           let peerParticipant = call.recipients.first {
            let peer = peerParticipant.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if Self.usesPairwiseFrameIdentityResolution(call: call) {
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
        if Self.usesApplicationInjectedGroupFrameKeys(call: call) {
            logger.log(
                level: .info,
                message: "Ignoring pairwise call_cipher for group/conference media; frame keys are application-injected for connection=\(call.sharedCommunicationId)"
            )
            return call
        }

        let resolvedCall: Call
        if sessionParticipant == nil {
            // Some inbound 1:1 flows can receive `call_cipher` before the app has restored the
            // local session participant into RTCSession. Avoid aborting the entire handshake:
            // infer direction from `shouldOffer` and normalize the call shape just for this step.
            logger.log(
                level: .warning,
                message: "Session participant missing while finishing crypto session for \(call.sharedCommunicationId); inferring local/remote participants from current call direction")

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
        if Self.usesPairwiseFrameIdentityResolution(call: resolvedCall) {
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
                    if Self.isTrueOneToOneSfuRoom(call: resolvedCall) {
                        if let connection = await connectionManager.findConnection(with: resolvedCall.sharedCommunicationId) {
                            try await sendOneToOneSfuPostCipherHandshakeCompleteIfNeeded(
                                connection: connection,
                                call: resolvedCall)
                        } else {
                            logger.log(
                                level: .warning,
                                message: "Skipping 1:1 SFU post-cipher media readiness because connection was not found for \(resolvedCall.sharedCommunicationId)"
                            )
                        }
                        return resolvedCall
                    }

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
                        let refreshed = try await buildPostCipherSfuGroupOfferPayloadPreservingLocalSdp(call: resolvedCall)
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

    private func frameCryptorKeyRingIndex(_ ratchetIndex: Int) -> Int {
        let keyRingSize = 16
        let remainder = ratchetIndex % keyRingSize
        return remainder >= 0 ? remainder : remainder + keyRingSize
    }

    private func frameEncryptionKeyFingerprint(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func frameIdentityPropsFingerprint(_ props: SessionIdentity.UnwrappedProps) -> String {
        var data = Data()
        data.append(props.longTermPublicKey)
        data.append(props.signingPublicKey)
        if let oneTimePublicKey = props.oneTimePublicKey {
            data.append(oneTimePublicKey.rawRepresentation)
        }
        data.append(props.mlKEMPublicKey.rawRepresentation)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func ratchetCiphertextFingerprint(_ ciphertext: Data) -> String {
        let digest = SHA256.hash(data: ciphertext)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func framePropsBelongToRemotePeer(
        _ props: SessionIdentity.UnwrappedProps,
        localParticipantId: String
    ) -> Bool {
        let propsSecret = props.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        let localSecret = localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !propsSecret.isEmpty, !localSecret.isEmpty else { return false }
        return propsSecret.caseInsensitiveCompare(localSecret) != .orderedSame
    }

    /// Returns the frame identity props to use for outbound sender media-ratchet initialization.
    ///
    /// `keyManager` can contain a provisional SFU/room identity from early media bootstrap. When
    /// the current `Call` carries concrete remote ``Call/frameIdentityProps`` for the peer, prefer
    /// those props and overwrite the stored recipient identity before sender initialization. This
    /// keeps the sender's PQXDH bootstrap aligned with the receiver's concrete peer identity.
    private func senderRemoteFrameProps(
        connection: RTCConnection,
        call: Call,
        storedRemoteProps: SessionIdentity.UnwrappedProps
    ) -> SessionIdentity.UnwrappedProps {
        guard Self.usesPairwiseFrameIdentityResolution(call: call) else {
            return storedRemoteProps
        }
        guard let callFrameProps = call.frameIdentityProps,
              framePropsBelongToRemotePeer(
                callFrameProps,
                localParticipantId: connection.localParticipantId)
        else {
            return storedRemoteProps
        }
        return callFrameProps
    }

    /// Builds the `Call` object that must accompany outbound `call_cipher`.
    ///
    /// The input `call` may have been merged from an inbound payload and may still contain the
    /// remote peer's identity props. Outbound `call_cipher` is an identity exchange from *this*
    /// device, so the payload must refresh both frame and signaling props from local key bundles
    /// immediately before transport delivery.
    private func callCipherPayloadWithLocalIdentityProps(_ call: Call) async throws -> Call {
        var outboundCall = call
        let frameBundle = try await keyManager.fetchCallKeyBundle()
        let signalingBundle = try await pcKeyManager.fetchCallKeyBundle()
        guard let frameProps = await frameBundle.sessionIdentity.props(symmetricKey: frameBundle.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local frame identity props are missing")
        }
        guard let signalingProps = await signalingBundle.sessionIdentity.props(symmetricKey: signalingBundle.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local signaling identity props are missing")
        }
        outboundCall.frameIdentityProps = frameProps
        outboundCall.signalingIdentityProps = signalingProps
        return outboundCall
    }

#if canImport(WebRTC)
    enum TrackKind: Sendable {
        case videoSender(RTCRtpSender), videoReceiver(RTCRtpReceiver), audioSender(RTCRtpSender), audioReceiver(RTCRtpReceiver)
        case screenSender(RTCRtpSender), screenReceiver(RTCRtpReceiver)
    }

    private func provisionedFrameKeyParticipantId(matching participantId: String) -> String? {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if lastFrameKeyIndexByParticipantId[trimmed] != nil {
            return trimmed
        }
        return lastFrameKeyIndexByParticipantId.keys.first {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private func appleFrameCryptorKeyIndex(for participantId: String) -> Int32 {
        if frameEncryptionKeyMode == .shared {
            return Int32(frameCryptorKeyRingIndex(lastSharedFrameKeyIndex))
        }

        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let exact = lastFrameKeyIndexByParticipantId[trimmed]
        let caseFolded = lastFrameKeyIndexByParticipantId.first {
            $0.key.caseInsensitiveCompare(trimmed) == .orderedSame
        }?.value
        return Int32(frameCryptorKeyRingIndex(exact ?? caseFolded ?? 0))
    }

    private func frameCryptorDictionaryKey<T>(
        in dictionary: [String: T],
        matching participantId: String
    ) -> String? {
        if dictionary[participantId] != nil {
            return participantId
        }
        return dictionary.keys.first {
            $0.caseInsensitiveCompare(participantId) == .orderedSame
        }
    }

    private func enableAppleFrameCryptor(_ cryptor: RTCFrameCryptor, participantId: String) {
        cryptor.delegate = frameCryptorDelegate
        cryptor.keyIndex = appleFrameCryptorKeyIndex(for: participantId)
        cryptor.enabled = true
    }

    private func syncAppleFrameCryptorKeyIndex(
        participantId: String,
        index: Int,
        connection: RTCConnection
    ) {
        let keyIndex = Int32(frameCryptorKeyRingIndex(index))
        if frameEncryptionKeyMode == .shared ||
            participantId.caseInsensitiveCompare(connection.localParticipantId) == .orderedSame {
            connection.videoSenderCryptor?.keyIndex = keyIndex
            connection.audioSenderCryptor?.keyIndex = keyIndex
            connection.screenSenderCryptor?.keyIndex = keyIndex
        }

        if frameEncryptionKeyMode == .shared {
            for cryptor in connection.videoReceiverCryptorsByParticipantId.values { cryptor.keyIndex = keyIndex }
            for cryptor in connection.audioReceiverCryptorsByParticipantId.values { cryptor.keyIndex = keyIndex }
            for cryptor in connection.screenReceiverCryptorsByParticipantId.values { cryptor.keyIndex = keyIndex }
            connection.videoFrameCryptor?.keyIndex = keyIndex
            connection.audioFrameCryptor?.keyIndex = keyIndex
            return
        }

        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let videoKey = frameCryptorDictionaryKey(in: connection.videoReceiverCryptorsByParticipantId, matching: trimmed) {
            connection.videoReceiverCryptorsByParticipantId[videoKey]?.keyIndex = keyIndex
        }
        if let audioKey = frameCryptorDictionaryKey(in: connection.audioReceiverCryptorsByParticipantId, matching: trimmed) {
            connection.audioReceiverCryptorsByParticipantId[audioKey]?.keyIndex = keyIndex
        }
        if let screenKey = frameCryptorDictionaryKey(in: connection.screenReceiverCryptorsByParticipantId, matching: trimmed) {
            connection.screenReceiverCryptorsByParticipantId[screenKey]?.keyIndex = keyIndex
        }
        if frameCryptorDictionaryKey(in: connection.videoReceiverCryptorBindingsByParticipantId, matching: trimmed) != nil {
            connection.videoFrameCryptor?.keyIndex = keyIndex
        }
        if frameCryptorDictionaryKey(in: connection.audioReceiverCryptorBindingsByParticipantId, matching: trimmed) != nil {
            connection.audioFrameCryptor?.keyIndex = keyIndex
        }
    }

    private func syncAppleFrameCryptorKeyIndex(participantId: String, index: Int) async {
        let connections = await connectionManager.findAllConnections()
        for connection in connections {
            syncAppleFrameCryptorKeyIndex(
                participantId: participantId,
                index: index,
                connection: connection)
        }
    }

    private func receiverFrameCryptorParticipantId(
        connection: RTCConnection,
        participantIdOverride: String?
    ) -> String {
        let trimmedOverride = participantIdOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawParticipantId: String
        if !trimmedOverride.isEmpty {
            rawParticipantId = trimmedOverride
        } else if frameEncryptionKeyMode == .perParticipant,
                  Self.isTrueOneToOneSfuRoom(call: connection.call),
                  let remoteOwner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteOwner.isEmpty {
            rawParticipantId = remoteOwner
        } else {
            rawParticipantId = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return provisionedFrameKeyParticipantId(matching: rawParticipantId) ?? rawParticipantId
    }

    private func shouldDelayReceiverFrameCryptorBindingUntilReceiveKey(
        connection: RTCConnection,
        participantId: String
    ) -> Bool {
        guard enableEncryption else { return false }
        guard frameEncryptionKeyMode == .perParticipant else { return false }
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return provisionedFrameKeyParticipantId(matching: trimmed) == nil
    }

    private func appleReceiverCryptorBinding(
        receiver: RTCRtpReceiver,
        participantId: String,
        mediaKind: String,
        connectionId: String
    ) -> RTCReceiverCryptorBinding? {
        let participant = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participant.isEmpty else {
            logger.log(
                level: .warning,
                message: "Skipping \(mediaKind) receiver FrameCryptor: empty participant id connId=\(connectionId)"
            )
            return nil
        }

        guard let track = receiver.track else {
            logger.log(
                level: .info,
                message: "Skipping \(mediaKind) receiver FrameCryptor: receiver has no track yet participantId='\(participant)' connId=\(connectionId)"
            )
            return nil
        }

        let trackId = track.trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackId.isEmpty else {
            logger.log(
                level: .info,
                message: "Skipping \(mediaKind) receiver FrameCryptor: receiver track has empty trackId participantId='\(participant)' connId=\(connectionId)"
            )
            return nil
        }

        guard track.readyState != .ended else {
            logger.log(
                level: .info,
                message: "Skipping \(mediaKind) receiver FrameCryptor: receiver track ended participantId='\(participant)' trackId=\(trackId) connId=\(connectionId)"
            )
            return nil
        }

        return RTCReceiverCryptorBinding(
            participantId: participant,
            trackId: trackId,
            receiverId: String(describing: ObjectIdentifier(receiver))
        )
    }

    private func disableAppleFrameCryptor(_ cryptor: RTCFrameCryptor?) {
        cryptor?.enabled = false
        cryptor?.delegate = nil
    }

    private func shouldReuseReceiverFrameCryptor(
        existingBinding: RTCReceiverCryptorBinding,
        newBinding: RTCReceiverCryptorBinding
    ) -> Bool {
        // RTCFrameCryptor is constructed against one concrete RTCRtpReceiver. Even when the
        // logical track id is unchanged after SFU renegotiation, a different receiver binding
        // must get a fresh cryptor so decrypted frames flow through the active receive path.
        existingBinding.trackId == newBinding.trackId &&
            existingBinding.receiverId == newBinding.receiverId
    }

    private func receiverFrameCryptorRebindReason(
        existingBinding: RTCReceiverCryptorBinding,
        newBinding: RTCReceiverCryptorBinding
    ) -> String {
        var reasons: [String] = []
        if existingBinding.trackId != newBinding.trackId {
            reasons.append("trackChanged")
        }
        if existingBinding.receiverId != newBinding.receiverId {
            reasons.append("receiverChanged")
        }
        return reasons.isEmpty ? "bindingChanged" : reasons.joined(separator: "+")
    }

    private func logReceiverFrameCryptorRebind(
        kind: String,
        connectionId: String,
        existingBinding: RTCReceiverCryptorBinding,
        newBinding: RTCReceiverCryptorBinding
    ) {
        logger.log(
            level: .info,
            message: "Rebinding receiver FrameCryptor kind=\(kind) participantId=\(newBinding.participantId) connId=\(connectionId) reason=\(receiverFrameCryptorRebindReason(existingBinding: existingBinding, newBinding: newBinding)) oldTrackId=\(existingBinding.trackId) newTrackId=\(newBinding.trackId) oldReceiverId=\(existingBinding.receiverId) newReceiverId=\(newBinding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: newBinding.participantId))")
    }

    private func prepareVideoReceiverCryptorSlot(
        connection: inout RTCConnection,
        binding: RTCReceiverCryptorBinding
    ) -> RTCFrameCryptor? {
        let participantId = binding.participantId
        if let existingBinding = connection.videoReceiverCryptorBindingsByParticipantId[participantId] {
            if let existing = connection.videoReceiverCryptorsByParticipantId[participantId],
               shouldReuseReceiverFrameCryptor(existingBinding: existingBinding, newBinding: binding) {
                enableAppleFrameCryptor(existing, participantId: participantId)
                connection.videoFrameCryptor = existing
                connection.videoReceiverCryptorBindingsByParticipantId[participantId] = binding
                return existing
            }
            if connection.videoReceiverCryptorsByParticipantId[participantId] != nil {
                logReceiverFrameCryptorRebind(
                    kind: "video",
                    connectionId: connection.id,
                    existingBinding: existingBinding,
                    newBinding: binding)
            }
        }

        if let stale = connection.videoReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
            disableAppleFrameCryptor(stale)
            if connection.videoFrameCryptor === stale {
                connection.videoFrameCryptor = nil
            }
        }
        connection.videoReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)

        var duplicateParticipantIds: [String] = []
        for (key, existingBinding) in connection.videoReceiverCryptorBindingsByParticipantId {
            if key != participantId,
               existingBinding.trackId == binding.trackId {
                duplicateParticipantIds.append(key)
            }
        }
        for key in duplicateParticipantIds {
            if let stale = connection.videoReceiverCryptorsByParticipantId.removeValue(forKey: key) {
                disableAppleFrameCryptor(stale)
                if connection.videoFrameCryptor === stale {
                    connection.videoFrameCryptor = nil
                }
            }
            connection.videoReceiverCryptorBindingsByParticipantId.removeValue(forKey: key)
        }

        return nil
    }

    private func prepareAudioReceiverCryptorSlot(
        connection: inout RTCConnection,
        binding: RTCReceiverCryptorBinding
    ) -> RTCFrameCryptor? {
        let participantId = binding.participantId
        if let existingBinding = connection.audioReceiverCryptorBindingsByParticipantId[participantId] {
            if let existing = connection.audioReceiverCryptorsByParticipantId[participantId],
               shouldReuseReceiverFrameCryptor(existingBinding: existingBinding, newBinding: binding) {
                enableAppleFrameCryptor(existing, participantId: participantId)
                connection.audioFrameCryptor = existing
                connection.audioReceiverCryptorBindingsByParticipantId[participantId] = binding
                return existing
            }
            if connection.audioReceiverCryptorsByParticipantId[participantId] != nil {
                logReceiverFrameCryptorRebind(
                    kind: "audio",
                    connectionId: connection.id,
                    existingBinding: existingBinding,
                    newBinding: binding)
            }
        }

        if let stale = connection.audioReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
            disableAppleFrameCryptor(stale)
            if connection.audioFrameCryptor === stale {
                connection.audioFrameCryptor = nil
            }
        }
        connection.audioReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)

        var duplicateParticipantIds: [String] = []
        for (key, existingBinding) in connection.audioReceiverCryptorBindingsByParticipantId {
            if key != participantId,
               existingBinding.trackId == binding.trackId {
                duplicateParticipantIds.append(key)
            }
        }
        for key in duplicateParticipantIds {
            if let stale = connection.audioReceiverCryptorsByParticipantId.removeValue(forKey: key) {
                disableAppleFrameCryptor(stale)
                if connection.audioFrameCryptor === stale {
                    connection.audioFrameCryptor = nil
                }
            }
            connection.audioReceiverCryptorBindingsByParticipantId.removeValue(forKey: key)
        }

        return nil
    }

    private func prepareScreenReceiverCryptorSlot(
        connection: inout RTCConnection,
        binding: RTCReceiverCryptorBinding
    ) -> RTCFrameCryptor? {
        let participantId = binding.participantId
        if let existingBinding = connection.screenReceiverCryptorBindingsByParticipantId[participantId] {
            if let existing = connection.screenReceiverCryptorsByParticipantId[participantId],
               shouldReuseReceiverFrameCryptor(existingBinding: existingBinding, newBinding: binding) {
                enableAppleFrameCryptor(existing, participantId: participantId)
                connection.screenReceiverCryptorBindingsByParticipantId[participantId] = binding
                return existing
            }
            if connection.screenReceiverCryptorsByParticipantId[participantId] != nil {
                logReceiverFrameCryptorRebind(
                    kind: "screen",
                    connectionId: connection.id,
                    existingBinding: existingBinding,
                    newBinding: binding)
            }
        }

        if let stale = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
            disableAppleFrameCryptor(stale)
        }
        connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)

        var duplicateParticipantIds: [String] = []
        for (key, existingBinding) in connection.screenReceiverCryptorBindingsByParticipantId {
            if key != participantId,
               existingBinding.trackId == binding.trackId {
                duplicateParticipantIds.append(key)
            }
        }
        for key in duplicateParticipantIds {
            if let stale = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: key) {
                disableAppleFrameCryptor(stale)
            }
            connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: key)
        }

        return nil
    }

#endif

    //MARK: Key Derivation & Cleanup

    /// Applies a frame-encryption key for a participant.
    ///
    /// In `shared` mode the participantId is ignored and the key is applied to the shared key ring.
    /// In `perParticipant` mode the key is applied to the given participant. For SFU group media,
    /// callers must pass the sender / remote track-owner participant id, never the room id. Apple
    /// receiver FrameCryptors are reattached after the key install so tracks that arrived before
    /// the sender-key envelope can begin decrypting without recreating the PeerConnection.
    public func setFrameEncryptionKey(_ key: Data, index: Int, for participantId: String) async {
        let keyRingIndex = frameCryptorKeyRingIndex(index)
#if canImport(WebRTC)
        guard enableEncryption else { return }
        ensureFrameKeyProviderIfNeeded()
        guard let keyProvider else {
            logger.log(level: .error, message: "❌ FrameCryptorKeyProvider is nil; cannot set frame key (enableEncryption=true)")
            return
        }
        if frameEncryptionKeyMode == .shared {
            keyProvider.setSharedKey(key, with: Int32(keyRingIndex))
            lastSharedFrameKeyIndex = keyRingIndex
        } else {
            keyProvider.setKey(key, with: Int32(keyRingIndex), forParticipant: participantId)
            lastFrameKeyIndexByParticipantId[participantId] = keyRingIndex
        }
#elseif os(Android)
        guard enableEncryption else { return }
        if frameEncryptionKeyMode == .shared {
            rtcClient.setSharedKey(
                key,
                with: Int32(keyRingIndex),
                ratchetSalt: ratchetSalt)
            lastSharedFrameKeyIndex = keyRingIndex
        } else {
            rtcClient.setKey(
                key,
                with: Int32(keyRingIndex),
                forParticipant: participantId,
                ratchetSalt: ratchetSalt)
            lastFrameKeyIndexByParticipantId[participantId] = keyRingIndex
        }
#endif
#if canImport(WebRTC)
        await syncAppleFrameCryptorKeyIndex(participantId: participantId, index: keyRingIndex)
        if enableEncryption, frameEncryptionKeyMode == .perParticipant {
            let connections = await connectionManager.findAllConnections()
            for connection in connections {
                do {
                    try await appleReattachReceiverFrameCryptorsAfterFrameKeyInstall(
                        connection: connection,
                        provisionedRemoteTrackOwnerId: participantId)
                } catch {
                    logger.log(
                        level: .warning,
                        message: "Failed to reattach receiver FrameCryptors after setFrameEncryptionKey participantId='\(participantId)' connId=\(connection.id): \(error)"
                    )
                }
            }
        }
#endif

        // Diagnostics: prove which participantId/index we provisioned (without logging key bytes).
        // Keep at debug to avoid log noise in production.
        let mode = frameEncryptionKeyMode
        if mode == .shared {
            logger.log(level: .debug, message: "🔑 Provisioned shared frame key index=\(keyRingIndex) ratchetIndex=\(index) (participantId ignored)")
        } else {
            logger.log(level: .debug, message: "🔑 Provisioned per-participant frame key index=\(keyRingIndex) ratchetIndex=\(index) for participantId='\(participantId)'")
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
        let keyRingIndex = frameCryptorKeyRingIndex(index)
        if frameEncryptionKeyMode == .shared {
            return keyProvider.ratchetSharedKey(Int32(keyRingIndex))
        } else {
            return keyProvider.ratchetKey(participantId, with: Int32(keyRingIndex))
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
        let keyRingIndex = frameCryptorKeyRingIndex(index)
        if frameEncryptionKeyMode == .shared {
            return keyProvider.exportSharedKey(Int32(keyRingIndex))
        } else {
            return keyProvider.exportKey(participantId, with: Int32(keyRingIndex))
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
        case .videoReceiver, .audioReceiver, .screenReceiver:
            if let latest = await connectionManager.findConnection(with: connection.id) {
                connection = latest
            }
        case .videoSender, .audioSender, .screenSender:
            break
        }
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

            enableAppleFrameCryptor(videoFrameCryptor, participantId: connection.localParticipantId)
            connection.videoSenderCryptor = videoFrameCryptor
        case .videoReceiver(let receiver):
            let receiverParticipantId = receiverFrameCryptorParticipantId(
                connection: connection,
                participantIdOverride: participantIdOverride)
            guard !shouldDelayReceiverFrameCryptorBindingUntilReceiveKey(
                connection: connection,
                participantId: receiverParticipantId)
            else {
                logger.log(
                    level: .info,
                    message: "Receive-key guard: delaying video receiver FrameCryptor until frame key is installed participantId='\(receiverParticipantId)' connId=\(connection.id)")
                return
            }
            guard let binding = appleReceiverCryptorBinding(
                receiver: receiver,
                participantId: receiverParticipantId,
                mediaKind: "video",
                connectionId: connection.id)
            else { return }
            if prepareVideoReceiverCryptorSlot(connection: &connection, binding: binding) != nil {
                await connectionManager.updateConnection(id: connection.id, with: connection)
                logger.log(
                    level: .info,
                    message: "Reusing receiver FrameCryptor kind=video participantId=\(binding.participantId) connId=\(connection.id) trackId=\(binding.trackId) receiverId=\(binding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: binding.participantId))")
                return
            }

            let videoFrameCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpReceiver: receiver,
                participantId: binding.participantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)

            guard let videoFrameCryptor else {
                logger.log(level: .error, message: "Failed to create video FrameCryptor")
                return
            }

            enableAppleFrameCryptor(videoFrameCryptor, participantId: binding.participantId)
            connection.videoFrameCryptor = videoFrameCryptor
            connection.videoReceiverCryptorsByParticipantId[binding.participantId] = videoFrameCryptor
            connection.videoReceiverCryptorBindingsByParticipantId[binding.participantId] = binding
            logger.log(
                level: .info,
                message: "Created receiver FrameCryptor kind=video participantId=\(binding.participantId) connId=\(connection.id) trackId=\(binding.trackId) receiverId=\(binding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: binding.participantId))")

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

            enableAppleFrameCryptor(audioCryptor, participantId: connection.localParticipantId)
            connection.audioSenderCryptor = audioCryptor
        case .audioReceiver(let receiver):
            let receiverParticipantId = receiverFrameCryptorParticipantId(
                connection: connection,
                participantIdOverride: participantIdOverride)
            guard !shouldDelayReceiverFrameCryptorBindingUntilReceiveKey(
                connection: connection,
                participantId: receiverParticipantId)
            else {
                logger.log(
                    level: .info,
                    message: "Receive-key guard: delaying audio receiver FrameCryptor until frame key is installed participantId='\(receiverParticipantId)' connId=\(connection.id)")
                return
            }
            guard let binding = appleReceiverCryptorBinding(
                receiver: receiver,
                participantId: receiverParticipantId,
                mediaKind: "audio",
                connectionId: connection.id)
            else { return }
            if prepareAudioReceiverCryptorSlot(connection: &connection, binding: binding) != nil {
                await connectionManager.updateConnection(id: connection.id, with: connection)
                logger.log(
                    level: .info,
                    message: "Reusing receiver FrameCryptor kind=audio participantId=\(binding.participantId) connId=\(connection.id) trackId=\(binding.trackId) receiverId=\(binding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: binding.participantId))")
                return
            }

            let audioCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpReceiver: receiver,
                participantId: binding.participantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)

            guard let audioCryptor else {
                logger.log(level: .error, message: "Failed to create audio FrameCryptor")
                return
            }

            enableAppleFrameCryptor(audioCryptor, participantId: binding.participantId)
            connection.audioFrameCryptor = audioCryptor
            connection.audioReceiverCryptorsByParticipantId[binding.participantId] = audioCryptor
            connection.audioReceiverCryptorBindingsByParticipantId[binding.participantId] = binding
            logger.log(
                level: .info,
                message: "Created receiver FrameCryptor kind=audio participantId=\(binding.participantId) connId=\(connection.id) trackId=\(binding.trackId) receiverId=\(binding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: binding.participantId))")
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

            enableAppleFrameCryptor(screenCryptor, participantId: connection.localParticipantId)
            connection.screenSenderCryptor = screenCryptor
        case .screenReceiver(let receiver):
            let receiverParticipantId = receiverFrameCryptorParticipantId(
                connection: connection,
                participantIdOverride: participantIdOverride)
            guard !shouldDelayReceiverFrameCryptorBindingUntilReceiveKey(
                connection: connection,
                participantId: receiverParticipantId)
            else {
                logger.log(
                    level: .info,
                    message: "Receive-key guard: delaying screen receiver FrameCryptor until frame key is installed participantId='\(receiverParticipantId)' connId=\(connection.id)")
                return
            }
            guard let binding = appleReceiverCryptorBinding(
                receiver: receiver,
                participantId: receiverParticipantId,
                mediaKind: "screen",
                connectionId: connection.id)
            else { return }
            if prepareScreenReceiverCryptorSlot(connection: &connection, binding: binding) != nil {
                await connectionManager.updateConnection(id: connection.id, with: connection)
                logger.log(
                    level: .info,
                    message: "Reusing receiver FrameCryptor kind=screen participantId=\(binding.participantId) connId=\(connection.id) trackId=\(binding.trackId) receiverId=\(binding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: binding.participantId))")
                return
            }

            let screenCryptor = RTCFrameCryptor(
                factory: Self.factory,
                rtpReceiver: receiver,
                participantId: binding.participantId,
                algorithm: .aesGcm,
                keyProvider: keyProvider)

            guard let screenCryptor else {
                logger.log(level: .error, message: "Failed to create screen receiver FrameCryptor")
                return
            }

            enableAppleFrameCryptor(screenCryptor, participantId: binding.participantId)
            connection.screenReceiverCryptorsByParticipantId[binding.participantId] = screenCryptor
            connection.screenReceiverCryptorBindingsByParticipantId[binding.participantId] = binding
            logger.log(
                level: .info,
                message: "Created receiver FrameCryptor kind=screen participantId=\(binding.participantId) connId=\(connection.id) trackId=\(binding.trackId) receiverId=\(binding.receiverId) keyIndex=\(appleFrameCryptorKeyIndex(for: binding.participantId))")
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

    private func waitForSenderFrameKeyProvisioningToFinish(
        normalizedConnectionId: String,
        displayConnectionId: String
    ) async throws {
        let pollIntervalNanoseconds: UInt64 = 50_000_000
        let maxAttempts = 600
        for _ in 0..<maxAttempts {
            if !senderFrameKeyProvisioningConnectionIds.contains(normalizedConnectionId) {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw RTCErrors.invalidConfiguration(
            "Timed out waiting for sender frame key provisioning for connection \(displayConnectionId)"
        )
    }

    /// Derives and installs this client's outbound media frame key.
    ///
    /// This is the sender side of the `call_cipher` contract. In per-participant mode the key is
    /// installed only under `connection.localParticipantId`, because sender FrameCryptors encrypt
    /// with the local participant id. Receive slots are installed separately by
    /// ``setReceivingMessageKey(connection:ciphertext:remoteTrackOwnerParticipantId:)`` when the
    /// peer's `call_cipher` arrives.
    ///
    /// - Parameter force: Re-derive and resend the sender bootstrap even after provisioning. This
    ///   is only used when the peer frame identity changes from a provisional SFU/room identity to
    ///   the concrete peer identity.
    public func setMessageKey(
        connection: RTCConnection,
        call: Call,
        force: Bool = false
    ) async throws {
        let normalizedConnectionId = connection.id.normalizedConnectionId
        if Self.usesApplicationInjectedGroupFrameKeys(call: call) {
            var updatedConnection = await connectionManager.findConnection(with: connection.id) ?? connection
            if updatedConnection.cipherNegotiationState != .complete {
                updatedConnection.transition(to: .complete)
                await connectionManager.updateConnection(id: updatedConnection.id, with: updatedConnection)
            }
            senderFrameKeyProvisionedConnectionIds.insert(normalizedConnectionId)
            logger.log(
                level: .info,
                message: "Skipping pairwise call_cipher sender key for group/conference connection=\(connection.id); using application-injected per-sender frame keys"
            )
            return
        }

#if os(Android)
        // The Android answerer can create its SFU PeerConnection before the caller's
        // call_cipher arrives. At that point only the provisional SFU identity exists;
        // deriving an outbound frame key from it guarantees a later key replacement and
        // leaves the remote decoder without a usable starting video frame. Wait until the
        // caller's authoritative frame identity has been received. The offerer already
        // carries the answerer's frame props in call_answered and proceeds immediately.
        let hasRemoteFrameIdentityInCall = call.frameIdentityProps.map {
            framePropsBelongToRemotePeer(
                $0,
                localParticipantId: connection.localParticipantId)
        } ?? false
        if !force,
           Self.isTrueOneToOneSfuRoom(call: call),
           !hasRemoteFrameIdentityInCall,
           !oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(connection.id)) {
            logger.log(
                level: .info,
                message: "Android 1:1 SFU sender-key guard: deferring sender call_cipher until peer frame identity is received connId=\(connection.id)"
            )
            return
        }
#endif

        if !force, senderFrameKeyProvisionedConnectionIds.contains(normalizedConnectionId) {
            logger.log(
                level: .debug,
                message: "Skipping duplicate sender frame key provisioning for connection=\(connection.id); sender key is already provisioned")
            return
        }

        if senderFrameKeyProvisioningConnectionIds.contains(normalizedConnectionId) {
            logger.log(
                level: .info,
                message: "Waiting for in-flight sender frame key provisioning for connection=\(connection.id); an earlier setMessageKey is deriving this key")
        }
        while senderFrameKeyProvisioningConnectionIds.contains(normalizedConnectionId) {
            try await waitForSenderFrameKeyProvisioningToFinish(
                normalizedConnectionId: normalizedConnectionId,
                displayConnectionId: connection.id)
            if !force, senderFrameKeyProvisionedConnectionIds.contains(normalizedConnectionId) {
                logger.log(
                    level: .debug,
                    message: "Sender frame key provisioning for connection=\(connection.id) completed by the in-flight setMessageKey")
                return
            }
        }

        senderFrameKeyProvisioningConnectionIds.insert(normalizedConnectionId)
        defer { senderFrameKeyProvisioningConnectionIds.remove(normalizedConnectionId) }

        let activeConnection = await connectionManager.findConnection(with: connection.id) ?? connection
        if !force, activeConnection.cipherNegotiationState == .complete {
            logger.log(
                level: .debug,
                message: "Skipping sender frame key provisioning for connection=\(connection.id); cipher negotiation is already complete")
            senderFrameKeyProvisionedConnectionIds.insert(normalizedConnectionId)
            return
        }

        let (messageKey, ratchetIndex) = try await deriveMessageKey(
            connection: activeConnection,
            call: call,
            force: force)
        let keyRingIndex = frameCryptorKeyRingIndex(ratchetIndex)

#if canImport(WebRTC)
        // Only apply media key to the WebRTC FrameCryptorKeyProvider when frame encryption is enabled.
        if enableEncryption {
            ensureFrameKeyProviderIfNeeded()
            guard let keyProvider else {
                throw RTCErrors.invalidConfiguration("FrameCryptorKeyProvider is nil (enableEncryption=true)")
            }
            // Apply media key to the WebRTC key provider.
            // - Shared-key mode: one key ring for all participants.
            // - Per-participant mode: provision the local sender slot only. Receiver slots are
            //   populated by setReceivingMessageKey after the peer's call_cipher arrives.
            if frameEncryptionKeyMode == .shared {
                keyProvider.setSharedKey(messageKey, with: Int32(keyRingIndex))
                lastSharedFrameKeyIndex = keyRingIndex
                await syncAppleFrameCryptorKeyIndex(
                    participantId: connection.localParticipantId,
                    index: keyRingIndex)
                logger.log(level: .info, message: "🔑 Derived+provisioned shared frame key (setMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id)")
            } else {
                // Always provision the local sender slot — that's what our sender FrameCryptor
                // (bound with participantId == connection.localParticipantId) reads to encrypt.
                let senderParticipantId = Self.senderFrameKeyParticipantIdForSetMessageKey(
                    connectionLocalParticipantId: connection.localParticipantId)
                keyProvider.setKey(messageKey, with: Int32(keyRingIndex), forParticipant: senderParticipantId)
                lastFrameKeyIndexByParticipantId[senderParticipantId] = keyRingIndex
                await syncAppleFrameCryptorKeyIndex(
                    participantId: senderParticipantId,
                    index: keyRingIndex)

                logger.log(
                    level: .info,
                    message: "🔑 Derived+provisioned per-participant sender frame key (setMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id) local='\(senderParticipantId)'"
                )
            }
        }
#elseif os(Android)
        // Only provision frame keys on Android when frame encryption is enabled.
        // JNI keyProvider calls must run on main thread; MainActor ensures that.
        if enableEncryption {
            if frameEncryptionKeyMode == .shared {
                rtcClient.setSharedKey(
                    messageKey,
                    with: Int32(keyRingIndex),
                    ratchetSalt: ratchetSalt)
                lastSharedFrameKeyIndex = keyRingIndex
                logger.log(
                    level: .info,
                    message: "Derived+provisioned shared frame key (setMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id)"
                )
            } else {
                let senderParticipantId = Self.senderFrameKeyParticipantIdForSetMessageKey(
                    connectionLocalParticipantId: connection.localParticipantId)
                rtcClient.setKey(
                    messageKey,
                    with: Int32(keyRingIndex),
                    forParticipant: senderParticipantId,
                    ratchetSalt: ratchetSalt)
                lastFrameKeyIndexByParticipantId[senderParticipantId] = keyRingIndex
                logger.log(
                    level: .info,
                    message: "Derived+provisioned per-participant sender frame key (setMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id) local='\(senderParticipantId)'"
                )
            }
            // Mirror Apple: attach sender FrameCryptors once the key is set (in case tracks were added before key derivation).
            try await createEncryptedFrame(connection: connection)
        }
#endif
        senderFrameKeyProvisionedConnectionIds.insert(normalizedConnectionId)
    }

    /// Applies the derived receive key to the frame cryptor key provider.
    ///
    /// This is the receive side of the `call_cipher` contract. In per-participant mode, the key is
    /// installed only under the remote track owner. Do not mirror it to the local participant, the
    /// room id, or every known participant: those slots represent different ratchet directions or
    /// different senders and will break decryption in multi-party/SFU scenarios.
    ///
    /// The method records the key ring index for late-bound receiver FrameCryptors. After the key
    /// is installed, Apple receiver cryptors are reattached so existing RTP receivers pick up the
    /// newly provisioned slot.
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
        let remoteParticipantId = remoteTrackOwnerParticipantId ?? connection.remoteParticipantId
        let (messageKey, ratchetIndex) = try await deriveReceivedMessageKey(
            connectionId: connection.id,
            participant: remoteParticipantId,
            localKeys: connection.localKeys,
            symmetricKey: connection.symmetricKey,
            sessionIdentity: connection.sessionIdentity,
            ciphertext: ciphertext)
        let keyRingIndex = frameCryptorKeyRingIndex(ratchetIndex)

        let isTrueOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: connection.call)
        if !isTrueOneToOneSfuRoom,
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
            if frameEncryptionKeyMode == .shared {
                // Shared-key mode: same media key & index is used for decrypting frames, independent of participantId.
                keyProvider.setSharedKey(messageKey, with: Int32(keyRingIndex))
                lastSharedFrameKeyIndex = keyRingIndex
                await syncAppleFrameCryptorKeyIndex(
                    participantId: remoteParticipantId,
                    index: keyRingIndex)
            } else {
                // Per-participant mode: this key is the receive key for the *specific* remote
                // track owner (cipher sender). Provision ONLY that slot. Mirroring it to other
                // peers' slots — or to the local slot in multi-party calls — would clobber per-peer
                // receive keys and our own send key, since Double-Ratchet derives a distinct key
                // per direction/peer.
                keyProvider.setKey(messageKey, with: Int32(keyRingIndex), forParticipant: remoteParticipantId)
                lastFrameKeyIndexByParticipantId[remoteParticipantId] = keyRingIndex
                await syncAppleFrameCryptorKeyIndex(
                    participantId: remoteParticipantId,
                    index: keyRingIndex)
            }

            // Diagnostics: show which ids got provisioned for receiving.
            if frameEncryptionKeyMode == .shared {
                logger.log(level: .info, message: "🔑 Derived+provisioned shared frame key (setReceivingMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id)")
            } else {
                logger.log(level: .info, message: "🔑 Derived+provisioned per-participant receiver frame key (setReceivingMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id) remoteTrackOwner='\(remoteParticipantId)'")
            }

            // Android mirrors this with `createReceiverEncryptedFrame` in the branch below. On Apple we
            // only inject into `RTCFrameCryptorKeyProvider` here; if RTP receivers were bound before
            // the receive key existed, receiver cryptors may never decrypt. Reattach for 1:1 SFU and
            // direct (non-SFU-group) calls only — multi-party group PCs share `videoFrameCryptor`
            // slots across peers and need a narrower fix than blind rebind.
            try await appleReattachReceiverFrameCryptorsAfterFrameKeyInstall(
                connection: connection,
                provisionedRemoteTrackOwnerId: remoteParticipantId)
        }
#elseif os(Android)
        if enableEncryption {
            // JNI keyProvider calls must run on main thread; MainActor ensures that.
            if frameEncryptionKeyMode == .shared {
                rtcClient.setSharedKey(
                    messageKey,
                    with: Int32(keyRingIndex),
                    ratchetSalt: ratchetSalt)
                lastSharedFrameKeyIndex = keyRingIndex
                logger.log(
                    level: .info,
                    message: "Derived+provisioned shared frame key (setReceivingMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id)"
                )
            } else {
                // Provision ONLY the cipher sender's slot. See Apple branch for rationale.
                rtcClient.setKey(
                    messageKey,
                    with: Int32(keyRingIndex),
                    forParticipant: remoteParticipantId,
                    ratchetSalt: ratchetSalt)
                lastFrameKeyIndexByParticipantId[remoteParticipantId] = keyRingIndex
                logger.log(
                    level: .info,
                    message: "Derived+provisioned per-participant receiver frame key (setReceivingMessageKey) index=\(keyRingIndex) ratchetIndex=\(ratchetIndex) fingerprint=\(frameEncryptionKeyFingerprint(messageKey)) connId=\(connection.id) remoteTrackOwner='\(remoteParticipantId)'"
                )
            }

            // Attach receiver cryptors (Android needs explicit receiver attachment).
            // For inbound media, participantId must be the REMOTE track owner.
            rtcClient.createReceiverEncryptedFrame(
                participant: remoteParticipantId,
                connectionId: connection.id)
        }
#endif

        if isTrueOneToOneSfuRoom {
            let normId = teardownConnectionIdKey(connection.id)
            oneToOneSfuReceiveKeyReadyConnectionIds.insert(normId)
            logger.log(
                level: .info,
                message: enableEncryption
                    ? "1:1 SFU receive key installed; media readiness may be sent for remoteTrackOwner='\(remoteParticipantId)' connId=\(connection.id)"
                    : "1:1 SFU call_cipher received with FrameCryptor disabled; media readiness may be sent for remoteTrackOwner='\(remoteParticipantId)' connId=\(connection.id)")
            try await sendOneToOneSfuPostCipherHandshakeCompleteIfNeeded(
                connection: connection,
                call: connection.call)
        }
    }

    /// Initializes the send-side media ratchet and sends `call_cipher` when the negotiation state
    /// requires the peer to learn this client's frame identity.
    ///
    /// The ratchet session id is derived from direction, connection id, remote participant id, and
    /// remote frame-identity fingerprint. That makes send-side media keys independent from
    /// receive-side keys and from signaling-ratchet state.
    private func deriveMessageKey(
        connection: RTCConnection,
        call: Call,
        force: Bool = false
    ) async throws -> (Data, Int) {
        var connection = await connectionManager.findConnection(with: connection.id) ?? connection

        let remoteConnectionIdentity = try await keyManager.fetchConnectionIdentity(connection: connection.id)
        guard let storedRemoteProps = await remoteConnectionIdentity.sessionIdentity.props(symmetricKey: remoteConnectionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote peer did not provide a valid connection identity")
        }
        let remoteProps = senderRemoteFrameProps(
            connection: connection,
            call: call,
            storedRemoteProps: storedRemoteProps)
        let remoteIdentityFingerprint = frameIdentityPropsFingerprint(remoteProps)
        if remoteIdentityFingerprint != frameIdentityPropsFingerprint(storedRemoteProps) {
            _ = try await keyManager.createRecipientIdentity(
                connectionId: connection.id,
                props: remoteProps)
            logger.log(
                level: .info,
                message: "Using call frame identity for sender media ratchet connId=\(connection.id) remote='\(remoteProps.secretName)' fingerprint=\(remoteIdentityFingerprint)")
        }
        let localParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteParticipantId = ([call.sender.secretName] + call.recipients.map(\.secretName))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.caseInsensitiveCompare(localParticipantId) != .orderedSame }
            ?? connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendSessionIdentity = try await mediaRatchetSessionIdentity(
            base: connection.sessionIdentity,
            symmetricKey: connection.symmetricKey,
            direction: "send",
            connectionId: connection.id,
            participantId: remoteParticipantId,
            remoteIdentityFingerprint: remoteIdentityFingerprint)
        senderFrameKeyIdentityFingerprintByConnectionId[connection.id.normalizedConnectionId] = remoteIdentityFingerprint

        try await ratchetManager.senderInitialization(
            sessionIdentity: sendSessionIdentity,
            sessionSymmetricKey: connection.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(remoteProps.longTermPublicKey),
                oneTime: remoteProps.oneTimePublicKey,
                mlKEM: remoteProps.mlKEMPublicKey),
            localKeys: connection.localKeys)

        switch connection.cipherNegotiationState {
        case .waiting, .setRecipientKey:
            // Check per-connection instead of global flag: each party must send its own
            // `call_cipher` so the peer receives the matching local frame identity props.
            let ciphertext = try await ratchetManager.getCipherText(sessionId: sendSessionIdentity.id)
            let outboundCall = try await callCipherPayloadWithLocalIdentityProps(call)
            for recipient in call.recipients {
                try await requireTransport().sendCiphertext(
                    recipient: recipient.secretName,
                    connectionId: connection.id,
                    ciphertext: ciphertext,
                    call: outboundCall)
                logger.log(level: .info, message: "Sent ciphertext to recipient: \(recipient.secretName)")
            }

            // The actor can be re-entered while `sendCiphertext` awaits. Re-read the current
            // connection before writing negotiation state back so a stale `.waiting` snapshot
            // cannot regress a connection that already received the peer's cipher.
            connection = await connectionManager.findConnection(with: connection.id) ?? connection
            if connection.cipherNegotiationState == .setRecipientKey {
                connection.transition(to: .complete)
            } else if connection.cipherNegotiationState == .waiting {
                connection.transition(to: .setSenderKey)
            }
        default:
            if force {
                let ciphertext = try await ratchetManager.getCipherText(sessionId: sendSessionIdentity.id)
                let outboundCall = try await callCipherPayloadWithLocalIdentityProps(call)
                for recipient in call.recipients {
                    try await requireTransport().sendCiphertext(
                        recipient: recipient.secretName,
                        connectionId: connection.id,
                        ciphertext: ciphertext,
                        call: outboundCall)
                    logger.log(
                        level: .info,
                        message: "Sent refreshed ciphertext to recipient: \(recipient.secretName)")
                }
            }
            break
        }
        if connection.cipherNegotiationState == .setRecipientKey {
            connection.transition(to: .complete)
        }
        await connectionManager.updateConnection(id: connection.id, with: connection)
        if connection.cipherNegotiationState == .complete {
            logger.log(level: .info, message: "Completed cipher negotiation 🔒")
        }
        let (messageKey, index) = try await ratchetManager.deriveMessageKey(sessionId: sendSessionIdentity.id)
        return (messageKey.bytes, index)
    }

    /// Creates an isolated Double Ratchet session identity for frame-key derivation.
    ///
    /// Signaling ratchets and frame-key ratchets must never share session state. The generated
    /// identity id is stable for a single direction/connection/participant/remote-identity tuple.
    /// Receive sessions also include the inbound ciphertext fingerprint so a refreshed
    /// `call_cipher` starts a fresh receive chain at key index 0 instead of advancing a stale one.
    private func mediaRatchetSessionIdentity(
        base sessionIdentity: SessionIdentity,
        symmetricKey: SymmetricKey,
        direction: String,
        connectionId: String,
        participantId: String,
        remoteIdentityFingerprint: String,
        sessionDiscriminator: String? = nil
    ) async throws -> SessionIdentity {
        guard var props = await sessionIdentity.props(symmetricKey: symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local frame identity props are missing")
        }

        // Media keys are derived from PQXDH ciphertexts that are scoped to direction, peer
        // identity, and (for receive) the inbound `call_cipher` ciphertext. Keep this ratchet state
        // local so provisional room bootstrap state cannot be reused for peer media encryption.
        props.state = nil

        let connectionKey = connectionId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedConnectionId
            .lowercased()
        let participantKey = participantId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sessionStem = connectionKey.isEmpty
            ? sessionIdentity.id.uuidString.lowercased()
            : connectionKey
        let discriminator = sessionDiscriminator?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let directionKey = [
            "pqsrtc-frame-\(direction)",
            sessionStem,
            participantKey,
            remoteIdentityFingerprint,
            discriminator
        ]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "|")
        return try SessionIdentity(
            id: directionKey.stableUUIDConnectionId,
            props: props,
            symmetricKey: symmetricKey)
    }

    /// Initializes the receive-side media ratchet and returns the frame key for the inbound peer.
    ///
    /// `participant` must be the remote track owner used by receiver FrameCryptors. For 1:1 SFU
    /// this is the peer `secretName`, not the SFU room id.
    private func deriveReceivedMessageKey(
        connectionId: String,
        participant: String,
        localKeys: LocalKeys,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity,
        ciphertext: Data
    ) async throws -> (Data, Int) {

        let remoteConnectionIdentity = try await keyManager.fetchConnectionIdentity(connection: connectionId)
        guard let remoteProps = await remoteConnectionIdentity.sessionIdentity.props(symmetricKey: remoteConnectionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote peer did not provide a valid connection identity")
        }

        guard !ciphertext.isEmpty else {
            throw EncryptionErrors.missingCipherText
        }
        let remoteIdentityFingerprint = frameIdentityPropsFingerprint(remoteProps)
        // Each call_cipher payload is a fresh media ratchet bootstrap. Include its
        // ciphertext in the receive session id so refreshes restart at frame key index 0.
        let ciphertextFingerprint = ratchetCiphertextFingerprint(ciphertext)

        let receiveSessionIdentity = try await mediaRatchetSessionIdentity(
            base: sessionIdentity,
            symmetricKey: symmetricKey,
            direction: "receive",
            connectionId: connectionId,
            participantId: participant,
            remoteIdentityFingerprint: remoteIdentityFingerprint,
            sessionDiscriminator: ciphertextFingerprint)

        try await ratchetManager.recipientInitialization(
            sessionIdentity: receiveSessionIdentity,
            sessionSymmetricKey: symmetricKey,
            localKeys: localKeys,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(remoteProps.longTermPublicKey),
                oneTime: remoteProps.oneTimePublicKey,
                mlKEM: remoteProps.mlKEMPublicKey),
            ciphertext: ciphertext)

        let (messageKey, index) = try await ratchetManager.deriveReceivedMessageKey(
            sessionId: receiveSessionIdentity.id,
            cipherText: ciphertext)

        return (messageKey.bytes, index)
    }

    //MARK: RTCCipherTransport

    /// Handles an inbound `call_cipher` / media-ratchet ciphertext from the application transport.
    ///
    /// Contract:
    /// - `ciphertext` is opaque PQXDH bootstrap material generated by the remote peer.
    /// - `call.frameIdentityProps` is the remote peer's authoritative frame identity.
    /// - `call.signalingIdentityProps` is the remote peer's authoritative signaling identity.
    /// - `call.sharedCommunicationId` is the connection id used for both stored identity lookup
    ///   and duplicate detection.
    ///
    /// This method intentionally replaces any provisional recipient identity before deriving
    /// receive keys. If the remote frame identity changed after our sender key was provisioned, it
    /// forces one refreshed sender `call_cipher` so both sides agree at frame key index 0.
    func receiveCiphertext(
        recipient: String,
        ciphertext: Data,
        call: Call
    ) async throws {
        let cipherKey = InboundCallCiphertextKey(
            connectionId: call.sharedCommunicationId.normalizedConnectionId,
            ciphertext: ciphertext)
        if inboundCallCiphertextsInFlight.contains(cipherKey) || processedInboundCallCiphertexts.contains(cipherKey) {
            logger.log(
                level: .debug,
                message: "Skipping duplicate inbound call cipher control for connectionId=\(call.sharedCommunicationId)")
            return
        }
        inboundCallCiphertextsInFlight.insert(cipherKey)
        var rememberProcessedCiphertext = false
        defer {
            inboundCallCiphertextsInFlight.remove(cipherKey)
            if rememberProcessedCiphertext {
                processedInboundCallCiphertexts.insert(cipherKey)
            }
        }

        guard let remoteFrameProps = call.frameIdentityProps else {
            logger.log(level: .error, message: "Call will not proceed the session identity for sender is missing, Call will not proceed the frame session identity for sender is missing, Call: \(call)")
            return
        }

        guard let remoteSignalingProps = call.signalingIdentityProps else {
            logger.log(level: .error, message: "Call will not proceed the session identity for sender is missing, Call will not proceed the signalling session identity for sender is missing, Call: \(call)")
            return
        }
        let remoteFrameIdentityFingerprint = frameIdentityPropsFingerprint(remoteFrameProps)
        let normalizedCallCipherConnectionId = call.sharedCommunicationId.normalizedConnectionId
        let previousSenderRemoteFingerprint = senderFrameKeyIdentityFingerprintByConnectionId[normalizedCallCipherConnectionId]
        let shouldRefreshSenderFrameKey =
            previousSenderRemoteFingerprint != nil &&
            previousSenderRemoteFingerprint != remoteFrameIdentityFingerprint

        // `call_cipher` is the authoritative peer frame identity exchange. Replace any provisional
        // room bootstrap identity before deriving receive keys or refreshing our sender key.
        _ = try await keyManager.createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: remoteFrameProps)

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

        guard Self.shouldProcessOneToOneSfuCallCipher(
            connectionCall: connection.call,
            inboundCall: call
        ) else {
            logger.log(
                level: .info,
                message: "Ignoring 1:1 SFU call_cipher from non-active peer device sender=\(call.sender.secretName) deviceId=\(call.sender.deviceId) connectionId=\(connection.id)"
            )
            return
        }

        let initialState = connection.cipherNegotiationState
        logger.log(level: .info, message: "Received ciphertext for connectionId: \(connection.id) in cipher negotiation state: \(initialState)")
        switch initialState {
        case .waiting, .setSenderKey, .complete:
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

            let norm = connection.id.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
            pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId.removeValue(forKey: norm)
            if hasVideoReceiver || hasAudioReceiver {
                logger.log(level: .info, message: "🚀 Receivers available, completing ciphertext handshake")
            } else {
                logger.log(level: .info, message: "⏳ Receivers not yet available, deriving receive key now; receiver FrameCryptors will bind when receivers start")
            }
            try await setReceivingMessageKey(connection: connection, ciphertext: ciphertext, remoteTrackOwnerParticipantId: remoteTrackOwner)
            logger.log(level: .info, message: "👌 Handshake complete")
#else
            // Android PeerConnection APIs differ. We attempt setup here and let AndroidRTCClient
            // decide whether receivers are present when attaching FrameCryptors.
            logger.log(level: .info, message: "(Android) Attempting receiver cryptor setup after handshake")
            try await setReceivingMessageKey(connection: connection, ciphertext: ciphertext, remoteTrackOwnerParticipantId: remoteTrackOwner)
            logger.log(level: .info, message: "👌 Handshake complete")
#endif

            var updatedConnection = await connectionManager.findConnection(with: connection.id) ?? connection
            if initialState == .setSenderKey {
                updatedConnection.transition(to: .complete)
            } else if initialState == .waiting {
                updatedConnection.transition(to: .setRecipientKey)
            }
            await connectionManager.updateConnection(id: updatedConnection.id, with: updatedConnection)
            if updatedConnection.cipherNegotiationState == .complete {
                logger.log(level: .info, message: "Completed cipher negotiation 🔒")
            }
            rememberProcessedCiphertext = true
            if shouldRefreshSenderFrameKey {
                senderFrameKeyProvisionedConnectionIds.remove(normalizedCallCipherConnectionId)
                logger.log(
                    level: .info,
                    message: "Refreshing sender frame key after peer frame identity update connId=\(updatedConnection.id)")
                try await setMessageKey(connection: updatedConnection, call: call, force: true)
            } else if updatedConnection.cipherNegotiationState == .setRecipientKey {
                // Only the pure receiver (initially in .waiting) should initiate an outbound
                // handshake & media key derivation here. If we were already in .setSenderKey,
                // we've run the sender path before and only needed to finalize the receive side.
                // Always respond with our ciphertext so signaling can proceed.
                // FrameCryptor (media frame encryption) is independently gated by `enableEncryption`.
                try await setMessageKey(connection: updatedConnection, call: call)
            }
        default:
            rememberProcessedCiphertext = true
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
    /// Legacy Apple retry hook for receive-side frame key provisioning.
    ///
    /// The current `receiveCiphertext` path derives the receive key immediately. This hook remains
    /// for older flows and tests that seed `pendingAppleDeferredReceiveFrameKeyContext...`; it is a
    /// no-op when no pending context exists.
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
