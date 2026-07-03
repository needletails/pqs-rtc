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

    /// Whether an SFU group renegotiation is currently in flight for the room.
    func isSfuGroupRenegotiationInFlight(for connectionId: String) -> Bool {
        sfuRenegotiationInFlightConnectionIds.contains(connectionId.normalizedConnectionId)
    }

    /// Whether SFU group SDP signaling is currently stable for the room.
    func isSfuGroupSignalingStable(for connectionId: String) -> Bool {
        sfuGroupSignalingIsStableByConnectionId[connectionId.normalizedConnectionId] ?? true
    }

    func noteSfuGroupSignalingStability(for connectionId: String, isStable: Bool) {
        let norm = connectionId.normalizedConnectionId
        sfuGroupSignalingIsStableByConnectionId[norm] = isStable
        if isStable {
            notifySfuGroupSignalingBecameStable(connectionId: norm)
        }
    }

    /// Defer participant renderer attaches while SFU renegotiation or SDP signaling is still settling.
    func shouldDeferSfuGroupParticipantVideoAttach(for connectionId: String) -> Bool {
        let norm = connectionId.normalizedConnectionId
        return GroupSfuVideoAttachPolicy.shouldDeferParticipantVideoAttach(
            renegotiationInFlight: sfuRenegotiationInFlightConnectionIds.contains(norm),
            signalingIsStable: sfuGroupSignalingIsStableByConnectionId[norm] ?? true
        )
    }

    /// Tells the SFU this client has installed the group sender key for a specific source.
    ///
    /// Group/conference E2EE uses one sender key per publishing participant. The SFU must not
    /// forward source RTP to this receiver until the receiver confirms that source's key is
    /// installed, otherwise encrypted media can arrive before a matching receiver FrameCryptor key.
    public func sendSfuGroupMediaReady(
        sourceParticipantId: String,
        roomId: String,
        call: Call
    ) async throws {
        let sourceId = sourceParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceId.isEmpty else { return }

        let sourceParticipant = call.recipients.first {
            $0.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(sourceId) == .orderedSame
        } ?? (call.sender.secretName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(sourceId) == .orderedSame ? call.sender : nil)

        var readinessCall = call
        if let sourceParticipant {
            readinessCall.sender = sourceParticipant
        } else {
            readinessCall.sender = try Call.Participant(
                secretName: sourceId,
                nickname: sourceId,
                deviceId: ""
            )
        }
        if let sessionParticipant {
            readinessCall.recipients = [sessionParticipant]
        }
        readinessCall.metadata = nil

        let plaintext = try BinaryEncoder().encode(readinessCall)
        let writeTask = WriteTask(
            data: plaintext,
            roomId: roomId.normalizedConnectionId,
            flag: .mediaReady,
            call: readinessCall)
        try await taskProcessor.feedTask(task: EncryptableTask(task: .writeMessage(writeTask)))
        logger.log(
            level: .info,
            message: "Sent SFU group media readiness for source=\(sourceId) room=\(roomId)"
        )
    }

    private func mergeGroupCallForMediaBootstrap(
        stored: Call,
        update: Call,
        sfuRecipientId: String
    ) -> Call {
        func participantKey(_ secretName: String) -> String {
            secretName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var merged = stored

        if merged.sharedMessageId == nil {
            merged.sharedMessageId = update.sharedMessageId
        }

        let updatedWireId = update.channelWireId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !updatedWireId.isEmpty {
            merged.channelWireId = update.channelWireId
        } else if merged.channelWireId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            merged.channelWireId = sfuRecipientId.isGroupCall ? sfuRecipientId.ensureIRCChannel : nil
        }

        if merged.channelDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            merged.channelDisplayName = update.channelDisplayName
        }
        merged.supportsVideo = update.supportsVideo

        var participantBySecret: [String: Call.Participant] = [:]
        participantBySecret[participantKey(update.sender.secretName)] = update.sender
        for participant in update.recipients {
            participantBySecret[participantKey(participant.secretName)] = participant
        }

        let senderKey = participantKey(merged.sender.secretName)
        if merged.sender.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let replacement = participantBySecret[senderKey],
           !replacement.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.sender.deviceId = replacement.deviceId
        }

        merged.recipients = merged.recipients.map { recipient in
            var recipient = recipient
            let recipientKey = participantKey(recipient.secretName)
            if let replacement = participantBySecret[recipientKey],
               !replacement.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recipient.deviceId = replacement.deviceId
            }
            return recipient
        }

        if merged.recipients.isEmpty, !update.recipients.isEmpty {
            merged.recipients = update.recipients
        }
        if merged.frameIdentityProps == nil {
            merged.frameIdentityProps = update.frameIdentityProps
        }
        if merged.signalingIdentityProps == nil {
            merged.signalingIdentityProps = update.signalingIdentityProps
        }

        return merged
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
        var call = try Call(
            groupSharedCommunicationId: normalizedId,
            sender: sender,
            recipients: participants,
            supportsVideo: supportsVideo,
            isActive: true)
        if !sfuRecipientId.isGroupCall {
            call.channelWireId = nil
        }
        try await groupCallNegotiation(call: call, sfuRecipientId: sfuRecipientId)
    }

    /// Backward-compatible entry point for joining/registering an SFU group call.
    public func join(
        sender: Call.Participant,
        participants: [Call.Participant],
        sfuRecipientId: String,
        supportsVideo: Bool = true
    ) async throws {
        try await groupCallNegotiation(
            sender: sender,
            participants: participants,
            sfuRecipientId: sfuRecipientId,
            supportsVideo: supportsVideo
        )
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
        if call.channelWireId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           sfuRecipientId.isGroupCall {
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
        notifyGroupCallRegistered(roomId: normalizedId)
        
        setMediaDelegate(group)
        try await group.join()
        
        let transportSfuRecipientId = sfuRecipientId.isGroupCall ? sfuRecipientId.ensureIRCChannel : sfuRecipientId
        try await delegate?.negotiateGroupIdentity(
            call: call,
            sfuRecipientId: transportSfuRecipientId)
    }
    
    public func leave(
        sfuRecipientId: String,
        call: Call,
        endState: CallStateMachine.EndState = .userInitiated
    ) async throws {
        let normalizedId = sfuRecipientId.normalizedConnectionId
        guard let group = groupCalls[normalizedId] else {
            throw RTCErrors.missingGroupCall
        }
        await group.leave()
        groupCalls.removeValue(forKey: normalizedId)
        await shutdown(with: call, endState: endState)
    }
    
    public func sendGroupCallOffer(_ call: Call, iceRestart: Bool = false) async throws -> Call {
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

        if let connection = await connectionManager.findConnection(with: call.sharedCommunicationId),
           call.sharedCommunicationId.isGroupCall,
           connection.call.supportsVideo {
            let reserved = ensureGroupCallScreenSlotReserved(with: connection)
            await connectionManager.updateConnection(id: reserved.id, with: reserved)
        }

        // Create the offer (sets local SDP, triggers ICE gathering).
        call = try await createOffer(call: call, iceRestart: iceRestart)
        
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
        let senderDeviceId = call.sender.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let deviceId = UUID(uuidString: senderDeviceId) else {
            throw RTCErrors.invalidConfiguration("Invalid SFU sender deviceId: \(senderDeviceId)")
        }

        // Signaling ratchet (SDP/ICE over SFU): `pcKeyManager` + `TaskProcessor`.
        //
        // This identity is authoritative for encrypted SFU packets. A peer `call_cipher` can arrive
        // before registration and create a room-scoped signaling identity with the peer's props; if
        // we keep that provisional identity, the next `.offer` / `.candidate` is encrypted to the
        // peer instead of the SFU and the server rejects it with `maxSkippedHeadersExceeded`.
        _ = try await pcKeyManager.createSFUSignalingRecipientIdentity(
            roomId: call.sharedCommunicationId,
            deviceId: deviceId,
            sessionContext: call.id.uuidString,
            props: props,
            aliases: [connId, sfuRecipientId, call.resolvedChannelWireId ?? ""])

        // Provisional media ratchet bootstrap: `keyManager` + `ratchetManager`.
        //
        // True 1:1 SFU relay later replaces this provisional entry through `call_cipher`
        // `frameIdentityProps`. Channel-backed groups and `conf-` rooms do not use pairwise
        // `call_cipher` for media keys; their sender frame keys are injected by the host app under
        // each sender's participant id. We still keep the provisional room identity for legacy
        // bootstrap code that expects one before media setup starts.
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
    /// No-op if there is no registered group for `sfuRecipientId`, or if the initial SFU media offer
    /// was already sent (idempotent for duplicate registrations).
    ///
    /// Cipher negotiation can create the room `PeerConnection` before registration finishes. That
    /// connection is reusable, but it is not enough for SFU media: the room still needs one initial
    /// `.offer` so the server can attach local source tracks and replay them to other participants.
    public func beginGroupCallMediaAfterSfuRegistrationIfNeeded(
        sfuRecipientId: String,
        updatedCall: Call? = nil,
        sendInitialOffer: Bool = true
    ) async throws {
        let normalizedLookup = sfuRecipientId.normalizedConnectionId
        guard let group = groupCall(forSfuIdentity: normalizedLookup) else {
            logger.log(
                level: .warning,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: no RTCGroupCall for sfuRecipientId=\(sfuRecipientId) normalized=\(normalizedLookup) (registration reply may not have arrived, or room id does not match groupCallNegotiation)")
            return
        }

        if let updatedCall {
            let stored = await group.currentCall
            let merged = mergeGroupCallForMediaBootstrap(
                stored: stored,
                update: updatedCall,
                sfuRecipientId: sfuRecipientId)
            await group.applyUpdatedCallForNegotiation(merged)
            updateFallbackLatestCall(merged)
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
        guard !sfuGroupMediaBootstrapInFlightConnectionIds.contains(bootstrapKey) else {
            logger.log(
                level: .info,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: bootstrap already in flight for room=\(normalizedLookup); skipping duplicate")
            return
        }
        sfuGroupMediaBootstrapInFlightConnectionIds.insert(bootstrapKey)
        defer {
            sfuGroupMediaBootstrapInFlightConnectionIds.remove(bootstrapKey)
        }

        if var existingConnection = await connectionManager.findConnection(with: mediaCall.sharedCommunicationId) {
            existingConnection.call = mediaCall
            await connectionManager.updateConnection(id: existingConnection.id, with: existingConnection)

            if !sendInitialOffer {
                logger.log(
                    level: .info,
                    message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: reusing SFU PeerConnection without initial offer for room=\(normalizedLookup)")
                return
            }

            guard !initialSfuGroupMediaOfferSentConnectionIds.contains(bootstrapKey) else {
                logger.log(
                    level: .debug,
                    message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: connection already exists and initial SFU offer already sent for \(mediaCall.sharedCommunicationId)")
                return
            }

            logger.log(
                level: .info,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: reusing pre-created SFU PeerConnection and sending initial offer for room=\(normalizedLookup)")

            pendingInitialSfuGroupOfferConnectionIds.insert(bootstrapKey)
            defer { pendingInitialSfuGroupOfferConnectionIds.remove(bootstrapKey) }

            try await bootstrapOneToOneSfuSenderKeyIfReady(call: mediaCall)

            let updatedCall = try await sendGroupCallOffer(mediaCall)
            initialSfuGroupMediaOfferSentConnectionIds.insert(bootstrapKey)
            await group.applyUpdatedCallForNegotiation(updatedCall)

            if var refreshedConnection = await connectionManager.findConnection(with: mediaCall.sharedCommunicationId) {
                refreshedConnection.call = updatedCall
                await connectionManager.updateConnection(id: refreshedConnection.id, with: refreshedConnection)
            }
            return
        }

        logger.log(
            level: .info,
            message: sendInitialOffer
                ? "beginGroupCallMediaAfterSfuRegistrationIfNeeded: creating SFU PeerConnection and offer for room=\(normalizedLookup)"
                : "beginGroupCallMediaAfterSfuRegistrationIfNeeded: creating SFU PeerConnection (awaiting remote offer) for room=\(normalizedLookup)")

        if sendInitialOffer {
            pendingInitialSfuGroupOfferConnectionIds.insert(bootstrapKey)
        }
        defer {
            if sendInitialOffer {
                pendingInitialSfuGroupOfferConnectionIds.remove(bootstrapKey)
            }
        }

#if os(iOS)
        // No CallKit `didActivate:` for channel/conference SFU — align WebRTC with `AVAudioSession`
        // before `createPeerConnection` (see `prepareNonCallKitGroupCallAudio`).
        // Inbound 1:1 CallKit answers defer until `didActivate:`; do not activate the session here.
        if isAudioActivated && audioSession.useManualAudio {
            logger.log(
                level: .debug,
                message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: skipping non-CallKit audio prep (CallKit/manual audio already active) room=\(normalizedLookup)")
        } else {
            do {
                try await MainActor.run {
                    try self.prepareNonCallKitGroupCallAudio(supportsVideo: mediaCall.supportsVideo)
                }
            } catch {
                let message = String(describing: error).lowercased()
                if message.contains("session activation failed") {
                    logger.log(
                        level: .info,
                        message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: deferring SFU PeerConnection until CallKit audio activation for room=\(normalizedLookup)")
                    return
                }
                self.logger.log(
                    level: .error,
                    message: "beginGroupCallMediaAfterSfuRegistrationIfNeeded: non-CallKit audio prep failed before SFU PeerConnection: \(error)")
                throw error
            }
        }
#endif

        // Default `willFinishNegotiation: false` so 1:1 SFU relay calls still run the `call_cipher`
        // sender path at PC creation. Channel/conference group rooms are detected inside
        // `setMessageKey` and use application-injected per-sender frame keys instead; a pairwise
        // `call_cipher` bootstrap cannot represent one outbound group RTP stream for many peers.
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

        try await bootstrapOneToOneSfuSenderKeyIfReady(call: mediaCall)

        guard sendInitialOffer else { return }

        let updatedCall = try await sendGroupCallOffer(mediaCall)
        initialSfuGroupMediaOfferSentConnectionIds.insert(bootstrapKey)
        await group.applyUpdatedCallForNegotiation(updatedCall)

        if var refreshedConnection = await connectionManager.findConnection(with: mediaCall.sharedCommunicationId) {
            refreshedConnection.call = updatedCall
            await connectionManager.updateConnection(id: refreshedConnection.id, with: refreshedConnection)
        }
    }
    
    /// Single entrypoint to apply decoded control-plane messages.
    ///
    /// This is the intended transport-agnostic surface: your app owns the networking and
    /// calls into this API as messages arrive.
    ///
    /// Your networking layer should decode inbound SFU signaling and roster updates into
    /// ``ControlMessage`` and call this method. Media frame keys are not delivered through this enum;
    /// inject them with ``setFrameEncryptionKey(_:index:for:)`` after your app-level sender-key
    /// exchange resolves the track owner participant id.
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
        try await enqueueSfuEncryptedPacket(packet)
    }

    /// Routes an encrypted SFU control packet through decrypt + ``handleDecryptedPacket(_:packet:call:)``.
    ///
    /// Use for flags handled only after ratchet decrypt (e.g. ``PacketFlag/screenSharePreempt``).
    public func handleSfuEncryptedPacket(_ packet: RatchetMessagePacket) async throws {
        try await enqueueSfuEncryptedPacket(packet)
    }

    private func enqueueSfuEncryptedPacket(_ packet: RatchetMessagePacket) async throws {
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
            do {
                try await completeSfuRenegotiationOfferHandling(sdp: sdp, call: call)
                logger.log(level: .info, message: "Handled SFU renegotiation offer for group call: \(packet.sfuIdentity)")
            } catch RTCErrors.deferredSfuRenegotiationOffer {
                logger.log(
                    level: .info,
                    message: "Queued inbound SFU renegotiation offer for later processing connId=\(call.sharedCommunicationId)"
                )
            }
        case .participants:
            let participants: [RTCGroupCall.Participant] = try BinaryDecoder().decode([RTCGroupCall.Participant].self, from: plaintext)
            guard let group = groupCall(forSfuIdentity: packet.sfuIdentity) else {
                throw RTCErrors.missingGroupCall
            }
            await group.updateParticipants(participants)
#if canImport(WebRTC) && !os(Android)
            await pruneRemoteMediaForGroupRoster(participants, group: group, sfuIdentity: packet.sfuIdentity)
#endif
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
                message: "Applied inbound SFU post-cipher identity handshake for room=\(packet.sfuIdentity)")
        case .mediaReady:
            logger.log(
                level: .debug,
                message: "Ignoring inbound SFU mediaReady packet on client; media readiness is consumed by the SFU room=\(packet.sfuIdentity)")
        case .screenSharePreempt:
            let decoded = try BinaryDecoder().decode(Call.self, from: plaintext)
            await handleInboundScreenSharePreempt(call: decoded, sfuIdentity: packet.sfuIdentity)
        }
    }

#if canImport(WebRTC) && !os(Android)
    private struct GroupRemoteMediaPruneResult {
        var didUpdate = false
        var removedVideoParticipants: [String] = []
        var removedAudioParticipants: [String] = []
        var removedScreenParticipants: [String] = []
    }

    private func retireFrameKeyIndex(forParticipantId participantId: String) {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return }
        lastFrameKeyIndexByParticipantId = lastFrameKeyIndexByParticipantId.filter { existing, _ in
            Self.conferenceParticipantIdentityKey(existing) != participantKey
        }
    }

    private func pruneRemoteMedia(
        on connection: inout RTCConnection,
        shouldPruneParticipant: (String) -> Bool
    ) -> GroupRemoteMediaPruneResult {
        var result = GroupRemoteMediaPruneResult()

        func clearScreenShareBookkeeping(for participantId: String) {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            guard !participantKey.isEmpty else { return }
            connection.suppressedRemoteScreenShareParticipantIds.remove(participantKey)
            connection.remoteScreenShareStopRequestedParticipantKeys.remove(participantKey)
            clearRemoteScreenIngressFlatObservation(
                connectionId: connection.id,
                participantKey: participantKey
            )
        }

        for participantId in Array(connection.remoteVideoTracksByParticipantId.keys) where shouldPruneParticipant(participantId) {
            clearScreenShareBookkeeping(for: participantId)
            let track = connection.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
            if let track, connection.remoteVideoTrack === track {
                connection.remoteVideoTrack = nil
            }
            if let cryptor = connection.videoReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                cryptor.enabled = false
                cryptor.delegate = nil
                if connection.videoFrameCryptor === cryptor {
                    connection.videoFrameCryptor = nil
                }
            }
            connection.videoReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
            result.removedVideoParticipants.append(participantId)
            result.didUpdate = true
        }

        for participantId in Array(connection.remoteAudioTracksByParticipantId.keys) where shouldPruneParticipant(participantId) {
            clearScreenShareBookkeeping(for: participantId)
            let track = connection.remoteAudioTracksByParticipantId.removeValue(forKey: participantId)
            track?.isEnabled = false
            if let cryptor = connection.audioReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                cryptor.enabled = false
                cryptor.delegate = nil
                if connection.audioFrameCryptor === cryptor {
                    connection.audioFrameCryptor = nil
                }
            }
            connection.audioReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
            result.removedAudioParticipants.append(participantId)
            result.didUpdate = true
        }

        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) where shouldPruneParticipant(participantId) {
            clearScreenShareBookkeeping(for: participantId)
            connection.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
            if let cryptor = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                cryptor.enabled = false
                cryptor.delegate = nil
            }
            connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
            result.removedScreenParticipants.append(participantId)
            result.didUpdate = true
        }

        return result
    }

    private func emitRemoteMediaPruneEvents(
        connectionId: String,
        result: GroupRemoteMediaPruneResult
    ) {
        for participantId in result.removedVideoParticipants {
            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(connectionId: connectionId, participantId: participantId, kind: "video", isActive: false)
            )
        }
        for participantId in result.removedScreenParticipants {
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connectionId, participantId: participantId, isActive: false)
            )
        }
    }

    /// Removes one departed participant's receiver media and FrameCryptors from a live group call.
    ///
    /// Use this for server-authoritative participant-leave signals in channel-backed group calls.
    /// It deliberately does not close the peer connection: remaining participants keep their media,
    /// while the departed participant's stale receiver FrameCryptors and remembered frame-key index
    /// are retired so a later rejoin must install a fresh sender key before decrypting media.
    public func removeRemoteParticipantFromGroupCall(
        connectionId: String,
        participantId: String
    ) async {
        let targetKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !targetKey.isEmpty else { return }

        let normalizedId = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: normalizedId) else {
            logger.log(
                level: .debug,
                message: "No group connection found while pruning departed participant=\(participantId) connection=\(connectionId)"
            )
            retireFrameKeyIndex(forParticipantId: participantId)
            return
        }

        let result = pruneRemoteMedia(on: &connection) { candidate in
            Self.conferenceParticipantIdentityKey(candidate) == targetKey
        }
        retireFrameKeyIndex(forParticipantId: participantId)
        let clearedSuppressedState = connection.suppressedRemoteScreenShareParticipantIds.remove(targetKey) != nil
        let clearedStopRequestState = connection.remoteScreenShareStopRequestedParticipantKeys.remove(targetKey) != nil
        if clearedSuppressedState || clearedStopRequestState {
            clearRemoteScreenIngressFlatObservation(
                connectionId: connection.id,
                participantKey: targetKey
            )
        }

        guard result.didUpdate else {
            if clearedSuppressedState || clearedStopRequestState {
                await connectionManager.updateConnection(id: connection.id, with: connection)
            }
            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
            )
            logger.log(
                level: .debug,
                message: "No receiver media to prune for departed participant=\(participantId) connection=\(connection.id)"
            )
            return
        }

        await connectionManager.updateConnection(id: connection.id, with: connection)
        emitRemoteMediaPruneEvents(connectionId: connection.id, result: result)

        logger.log(
            level: .info,
            message: "Pruned departed SFU participant media participant=\(participantId) connection=\(connection.id) video=\(result.removedVideoParticipants.count) audio=\(result.removedAudioParticipants.count) screen=\(result.removedScreenParticipants.count)"
        )
    }

    /// Removes receiver tracks and FrameCryptors for participants the SFU roster no longer advertises.
    ///
    /// SDP renegotiation is the normal source of truth for media, but conference rooms can also
    /// publish roster updates when a participant leaves. Treat those updates as an additional cleanup
    /// signal so old receiver cryptors cannot keep decoding against a participant that has departed.
    private func pruneRemoteMediaForGroupRoster(
        _ participants: [RTCGroupCall.Participant],
        group: RTCGroupCall,
        sfuIdentity: String
    ) async {
        let call = await group.currentCall
        guard var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else {
            return
        }

        let localKey = Self.conferenceParticipantIdentityKey(connection.localParticipantId)
        let activeKeys = Set(participants.compactMap { participant -> String? in
            let key = Self.conferenceParticipantIdentityKey(participant.id)
            guard !key.isEmpty, UUID(uuidString: key) == nil, key != localKey else { return nil }
            return key
        })
        guard !participants.isEmpty else { return }

        func shouldPruneParticipant(_ participantId: String) -> Bool {
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { return false }
            let key = Self.conferenceParticipantIdentityKey(trimmed)
            guard !key.isEmpty, key != localKey else { return false }
            return !activeKeys.contains(key)
        }

        let result = pruneRemoteMedia(on: &connection, shouldPruneParticipant: shouldPruneParticipant)
        guard result.didUpdate else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)

        let removedParticipants = Set(
            result.removedVideoParticipants
                + result.removedAudioParticipants
                + result.removedScreenParticipants
        )
        for participantId in removedParticipants {
            retireFrameKeyIndex(forParticipantId: participantId)
        }
        emitRemoteMediaPruneEvents(connectionId: connection.id, result: result)

        logger.log(
            level: .info,
            message: "Pruned stale SFU receiver media after roster update room=\(sfuIdentity) connection=\(connection.id) activeParticipants=\(activeKeys.count)"
        )
    }
#endif

#if os(Android)
    /// Removes one departed participant's receiver media from a live Android group call.
    ///
    /// Android does not keep Apple `RTCFrameCryptor` bindings, but it still needs the same
    /// participant-scoped cleanup so UI tiles disappear and a rejoin waits for a fresh frame key.
    public func removeRemoteParticipantFromGroupCall(
        connectionId: String,
        participantId: String
    ) async {
        let targetKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !targetKey.isEmpty else { return }
        lastFrameKeyIndexByParticipantId = lastFrameKeyIndexByParticipantId.filter { existing, _ in
            Self.conferenceParticipantIdentityKey(existing) != targetKey
        }

        let normalizedId = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: normalizedId) else { return }

        func shouldRemove(_ candidate: String) -> Bool {
            Self.conferenceParticipantIdentityKey(candidate) == targetKey
        }

        var removedVideoParticipants: [String] = []
        var removedScreenParticipants: [String] = []

        for participantId in Array(connection.remoteVideoTracksByParticipantId.keys) where shouldRemove(participantId) {
            connection.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
            removedVideoParticipants.append(participantId)
        }
        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) where shouldRemove(participantId) {
            connection.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
            removedScreenParticipants.append(participantId)
        }

        guard !removedVideoParticipants.isEmpty || !removedScreenParticipants.isEmpty else {
            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
            )
            return
        }
        await connectionManager.updateConnection(id: connection.id, with: connection)

        for participantId in removedVideoParticipants {
            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
            )
        }
        for participantId in removedScreenParticipants {
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
            )
        }
    }
#elseif !canImport(WebRTC)
    public func removeRemoteParticipantFromGroupCall(
        connectionId: String,
        participantId: String
    ) async {
        let targetKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !targetKey.isEmpty else { return }
        lastFrameKeyIndexByParticipantId = lastFrameKeyIndexByParticipantId.filter { existing, _ in
            Self.conferenceParticipantIdentityKey(existing) != targetKey
        }
    }
#endif

}
