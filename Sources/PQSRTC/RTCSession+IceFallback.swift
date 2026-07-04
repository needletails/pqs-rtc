//
//  RTCSession+IceFallback.swift
//  pqs-rtc
//
//  Created by GPT-5.4 on 4/3/26.
//

import Foundation
import BinaryCodable
import DoubleRatchetKit

extension RTCSession {
    func normalizedFallbackConnectionId(for connectionId: String) -> String {
        connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
    }

    func initialIceTransportSelection() -> RTCIceTransportSelection {
        switch iceTransportPolicyStrategy {
        case .all, .allThenRelay:
            return .all
        case .relayOnly:
            return .relay
        }
    }

    func registerFallbackStateIfNeeded(
        call: Call,
        sender: String,
        recipient: String,
        localIdentity: ConnectionLocalIdentity,
        policyOverride: RTCIceTransportSelection?
    ) async {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        // Prefer explicit call-state direction when available.
        // `Call` shape can be rewritten during inbound crypto/signaling normalization
        // and may temporarily look outbound even while call-state is inbound.
        let direction = await callState.callDirection ?? inferredCallDirection(for: call)
        let policy = policyOverride ?? connectionFallbackStateByConnectionId[connectionId]?.currentPolicy ?? initialIceTransportSelection()

        if var existing = connectionFallbackStateByConnectionId[connectionId] {
            existing.latestCall = call
            existing.currentPolicy = policy
            connectionFallbackStateByConnectionId[connectionId] = existing
            return
        }

        connectionFallbackStateByConnectionId[connectionId] = RTCConnectionFallbackState(
            connectionId: connectionId,
            sender: sender,
            recipient: recipient,
            localIdentity: localIdentity,
            direction: direction,
            latestCall: call,
            currentPolicy: policy,
            hasRetriedToRelay: policy == .relay,
            timeoutTask: nil)
    }

    func updateFallbackLatestCall(_ call: Call) {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        guard var existing = connectionFallbackStateByConnectionId[connectionId] else { return }
        existing.latestCall = call
        connectionFallbackStateByConnectionId[connectionId] = existing
    }

    func iceTransportSelection(for connectionId: String) -> RTCIceTransportSelection {
        let key = normalizedFallbackConnectionId(for: connectionId)
        return connectionFallbackStateByConnectionId[key]?.currentPolicy ?? initialIceTransportSelection()
    }

    public func currentIceTransportSelection(for connectionId: String) -> RTCIceTransportSelection {
        iceTransportSelection(for: connectionId)
    }

    public func didRetryWithRelay(for connectionId: String) -> Bool {
        let key = normalizedFallbackConnectionId(for: connectionId)
        return connectionFallbackStateByConnectionId[key]?.hasRetriedToRelay ?? false
    }

    func cancelRelayFallbackTimer(connectionId: String) {
        let key = normalizedFallbackConnectionId(for: connectionId)
        guard var existing = connectionFallbackStateByConnectionId[key] else { return }
        existing.timeoutTask?.cancel()
        existing.timeoutTask = nil
        connectionFallbackStateByConnectionId[key] = existing
    }

    func clearFallbackState(connectionId: String?) {
        guard let connectionId else { return }
        let key = normalizedFallbackConnectionId(for: connectionId)
        guard let existing = connectionFallbackStateByConnectionId.removeValue(forKey: key) else { return }
        existing.timeoutTask?.cancel()
    }

    func resetAttemptFlagsForNewCall(connectionId: String) {
        let normalizedId = normalizedFallbackConnectionId(for: connectionId)
        clearFallbackState(connectionId: normalizedId)
        resetTeardownIdempotency(forConnectionId: connectionId)
#if canImport(WebRTC)
        stopInboundVideoFlowProbe(connectionId: normalizedId)
        stopOutboundVideoFlowProbe(connectionId: normalizedId)
#endif
        oneToOneSfuReceiveKeyReadyConnectionIds.remove(normalizedId)
        oneToOneSfuPostCipherHandshakeSentConnectionIds.remove(normalizedId)
        remoteVideoRendererAttachedTrackIdByConnectionId.removeValue(forKey: normalizedId)
        clearRemoteParticipantVideoRendererAttachments(connectionId: normalizedId)
        sfuRenegotiationReceiverCryptorRebindDeferredConnectionIds.remove(normalizedId)
        oneToOneSfuLockedRemoteDeviceIdByNormalizedConnectionId.removeValue(forKey: normalizedId)
        senderFrameKeyIdentityFingerprintByConnectionId.removeValue(forKey: normalizedId)
        pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedId)

        logger.log(level: .debug, message: "Reset per-connection retry flags for new call attempt: \(normalizedId)")
    }

    func armRelayFallbackTimerIfNeeded(for call: Call) {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        guard var existing = connectionFallbackStateByConnectionId[connectionId] else { return }
        guard case .outbound = existing.direction else { return }
        guard existing.currentPolicy == .all else { return }
        guard !existing.hasRetriedToRelay else { return }

        let timeoutMs: UInt64
        switch iceTransportPolicyStrategy {
        case .allThenRelay(let configured):
            timeoutMs = configured
        case .all, .relayOnly:
            return
        }

        existing.timeoutTask?.cancel()
        existing.timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            } catch {
                // Timer was canceled (for example after ICE connected); never run fallback.
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            _ = await self.retryWithRelayIfNeeded(call: call, reason: "ice_timeout")
        }
        connectionFallbackStateByConnectionId[connectionId] = existing

        logger.log(
            level: .info,
            message: "Armed ICE fallback timer for connection=\(connectionId) timeoutMs=\(timeoutMs) policy=\(existing.currentPolicy.rawValue)")
    }

    func shouldDeferDisconnectFailure(for call: Call) -> Bool {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        guard let existing = connectionFallbackStateByConnectionId[connectionId] else { return false }
        guard case .outbound = existing.direction else { return false }
        return existing.currentPolicy == .all && !existing.hasRetriedToRelay
    }

    func retryWithRelayIfNeeded(call: Call, reason: String) async -> Bool {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        guard var existing = connectionFallbackStateByConnectionId[connectionId] else { return false }
        guard !isConnectionFinishingOrEnded(connectionId) else { return false }
        guard case .outbound = existing.direction else { return false }
        guard existing.currentPolicy == .all, !existing.hasRetriedToRelay else { return false }

        guard let state = await callState.currentState else { return false }
        switch state {
        case .connecting, .connected:
            break
        default:
            return false
        }

        // A stale timer can race after ICE already connected but before call-state propagation.
        // If the live peer is already connected, suppress relay retry.
        if await peerTransportIsEstablished(for: connectionId) {
            cancelRelayFallbackTimer(connectionId: connectionId)
            logger.log(
                level: .info,
                message: "Skipping relay fallback for connection=\(connectionId) because peer transport is already established")
            return false
        }

        if reason == "ice_timeout", case .connected = await callState.currentState {
            cancelRelayFallbackTimer(connectionId: connectionId)
            logger.log(
                level: .info,
                message: "Skipping relay fallback for connection=\(connectionId) because call is already connected (stale ice_timeout)")
            return false
        }

        existing.hasRetriedToRelay = true
        existing.currentPolicy = .relay
        existing.timeoutTask?.cancel()
        existing.timeoutTask = nil
        connectionFallbackStateByConnectionId[connectionId] = existing
        relayFallbackRetryingConnectionIds.insert(connectionId)
        defer { relayFallbackRetryingConnectionIds.remove(connectionId) }

        logger.log(level: .warning, message: "Retrying connection=\(connectionId) with relay-only ICE after \(reason)")

        do {
            await discardPeerConnectionAttemptForRetry(call: existing.latestCall)

            _ = try await createPeerConnection(
                with: existing.latestCall,
                sender: existing.sender,
                recipient: existing.recipient,
                localIdentity: existing.localIdentity)

            let retriedCall = try await resendOfferForRelayFallback(call: existing.latestCall)
            existing.latestCall = retriedCall
            connectionFallbackStateByConnectionId[connectionId] = existing
            return true
        } catch {
            if error is CancellationError {
                logger.log(level: .warning, message: "Relay fallback retry canceled for connection=\(connectionId); preserving existing call state")
                return false
            }
            logger.log(level: .error, message: "Relay fallback retry failed for connection=\(connectionId): \(error)")
            if let direction = await callState.callDirection {
                await callState.transition(to: .failed(direction, existing.latestCall, "Relay fallback failed: \(error.localizedDescription)"))
            }
            await finishEndConnection(currentCall: existing.latestCall)
            return false
        }
    }

    private func peerTransportIsEstablished(for connectionId: String) async -> Bool {
        let key = normalizedFallbackConnectionId(for: connectionId)
        guard let liveConnection = await connectionManager.findConnection(with: key) else {
            return false
        }
#if canImport(WebRTC) && !os(Android)
        let iceState = liveConnection.peerConnection.iceConnectionState
        let pcState = liveConnection.peerConnection.connectionState
        return iceState == .connected || iceState == .completed || pcState == .connected
#elseif os(Android)
        return rtcClient.peerConnectionTransportIsEstablished(liveConnection.peerConnection)
#else
        return false
#endif
    }

    private func resendOfferForRelayFallback(call: Call) async throws -> Call {
        if call.sharedCommunicationId.isGroupCall || isGroupCall {
            let updated = try await sendGroupCallOffer(call)
            updateFallbackLatestCall(updated)
            return updated
        }

        var updated = try await createOffer(call: call)
        let keyBundle = try await pcKeyManager.fetchCallKeyBundle()
        guard let localProps = await keyBundle.sessionIdentity.props(symmetricKey: keyBundle.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local signaling props are missing for relay retry")
        }

        updated.signalingIdentityProps = localProps
        let offerPlaintext = try BinaryEncoder().encode(updated)
        let writeTask = WriteTask(
            data: offerPlaintext,
            roomId: updated.sharedCommunicationId.normalizedConnectionId,
            flag: .offer,
            call: updated)
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)
        updateFallbackLatestCall(updated)
        return updated
    }

    private func discardPeerConnectionAttemptForRetry(call: Call) async {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        cancelRelayFallbackTimer(connectionId: connectionId)
        readyForCandidatesByConnectionId[connectionId] = nil
        iceDequeByConnectionId[connectionId] = nil
#if os(Android)
        pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: connectionId)
        pendingLocalVideoRenderersByConnectionId.removeValue(forKey: connectionId)
#endif
        pcState = .none
        pcStateByConnectionId.removeValue(forKey: call.sharedCommunicationId)
        pcStateByConnectionId.removeValue(forKey: connectionId)
        if let consumer = inboundCandidateConsumers.removeValue(forKey: connectionId) {
            await consumer.removeAll()
        }

        if var connection = await connectionManager.findConnection(with: connectionId) {
#if canImport(WebRTC)
            stopOutboundRtpStatsLogging(connectionId: connectionId)
            stopOutboundVideoFlowProbe(connectionId: connectionId)
            stopAdaptiveVideoSend(connectionId: connectionId)
#if os(iOS) || os(macOS)
            // Stop injecting camera frames before the peer connection (and its RTP senders) is
            // closed below. The renderer stays registered; the retry attempt rebinds it via
            // rebindRegisteredLocalPreviewCaptureIfNeeded when the fresh video source is created.
            if let previewRenderer = localPreviewCaptureRenderersByConnectionId[connectionId] {
                await previewRenderer.setCapture(nil)
            }
#endif
            connection.videoFrameCryptor?.enabled = false
            connection.videoSenderCryptor?.enabled = false
            connection.audioFrameCryptor?.enabled = false
            connection.audioSenderCryptor?.enabled = false
            connection.screenSenderCryptor?.enabled = false
            connection.videoFrameCryptor?.delegate = nil
            connection.videoSenderCryptor?.delegate = nil
            connection.audioFrameCryptor?.delegate = nil
            connection.audioSenderCryptor?.delegate = nil
            connection.screenSenderCryptor?.delegate = nil
            for (_, cryptor) in connection.videoReceiverCryptorsByParticipantId {
                cryptor.enabled = false
                cryptor.delegate = nil
            }
            connection.videoReceiverCryptorsByParticipantId.removeAll()
            connection.videoReceiverCryptorBindingsByParticipantId.removeAll()
            for (_, cryptor) in connection.audioReceiverCryptorsByParticipantId {
                cryptor.enabled = false
                cryptor.delegate = nil
            }
            connection.audioReceiverCryptorsByParticipantId.removeAll()
            connection.audioReceiverCryptorBindingsByParticipantId.removeAll()
            for (_, cryptor) in connection.screenReceiverCryptorsByParticipantId {
                cryptor.enabled = false
                cryptor.delegate = nil
            }
            connection.screenReceiverCryptorsByParticipantId.removeAll()
            connection.screenReceiverCryptorBindingsByParticipantId.removeAll()
            if connection.localScreenTrack != nil {
                notifyLocalScreenShareChanged(isSharing: false)
            }
            for participantId in connection.remoteScreenTracksByParticipantId.keys {
                notifyRemoteScreenTrackChanged(
                    RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
                )
            }
            connection.remoteScreenTracksByParticipantId.removeAll()
            // Capture injection unbound and sender cryptors disabled above; drain in-flight
            // encrypted frames before the close below destroys the RTP senders.
            await drainAppleSenderFrameTransformersBeforeSenderTeardown()
#endif
#if os(Android)
            stopAdaptiveVideoSend(connectionId: connectionId)
            for participantId in connection.remoteVideoTracksByParticipantId.keys {
                notifyRemoteParticipantTrackChanged(
                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
                )
            }
            for participantId in connection.remoteScreenTracksByParticipantId.keys {
                notifyRemoteScreenTrackChanged(
                    RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
                )
            }
            rtcClient.resetPeerConnectionForRetry()
#else
            connection.peerConnection.delegate = nil
            connection.peerConnection.close()
#endif
            await connectionManager.removeConnection(with: connectionId)
        }
    }

    // MARK: - ICE Disconnect Grace Period

    func armDisconnectGraceTimer(for connection: RTCConnection) {
        armDisconnectGraceTimer(call: connection.call, connectionId: connection.id)
    }

    func armDisconnectGraceTimer(call: Call, connectionId: String) {
        cancelDisconnectGraceTask()
        let gracePeriodNs = iceDisconnectGracePeriodMs * 1_000_000

        disconnectGraceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: gracePeriodNs)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }

            let currentState = await self.callState.currentState
            guard case .connected = currentState else { return }

            self.logger.log(level: .warning, message: "ICE disconnect grace period expired for \(connectionId), failing call")

            let callDirection: CallStateMachine.CallDirection
            if let existingDirection = await self.callState.callDirection {
                callDirection = existingDirection
            } else {
                callDirection = .inbound(call.supportsVideo ? .video : .voice)
            }

            await self.callState.transition(to: .failed(callDirection, call, "PeerConnection Disconnected"))
            await self.finishEndConnection(currentCall: call)
        }

        logger.log(level: .info, message: "Armed ICE disconnect grace timer for \(connectionId) (\(iceDisconnectGracePeriodMs)ms)")
    }

    func cancelDisconnectGraceTask() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    // MARK: - ICE restart during SFU media renegotiation

    private static let iceRestartCooldownNs: UInt64 = 15_000_000_000

    /// Attempts an ICE-restart SFU renegotiation when transport collapses during screen-share churn.
    func attemptIceRestartRenegotiationIfNeeded(connectionId: String, reason: String) async {
#if canImport(WebRTC) && !os(Android)
        let normalizedId = normalizedFallbackConnectionId(for: connectionId)
        guard !normalizedId.isEmpty else { return }
        guard await isConnectionStillActiveForRecovery(normalizedId) else { return }
        guard let connection = await connectionManager.findConnection(with: normalizedId) else { return }

        let wireRoomId = connection.call.resolvedChannelWireId ?? connection.call.sharedCommunicationId
        let isSfuConnection = connection.id.isGroupCall
            || wireRoomId.isGroupCall
            || groupCall(forSfuIdentity: normalizedId) != nil
            || groupCall(forSfuIdentity: wireRoomId) != nil
        guard isSfuConnection else { return }

        guard case .connected = await callState.currentState else { return }

        let iceState = connection.peerConnection.iceConnectionState
        let inboundFlow = await evaluateInboundRemoteVideoFlow(connectionId: normalizedId)
        let dtlsDisconnected = inboundFlow?.dtlsState != "connected"
        let transportUnstable = iceState == .disconnected
            || iceState == .failed
            || dtlsDisconnected
        guard transportUnstable else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastIceRestartAttemptUptimeNsByConnectionId[normalizedId],
           now >= last,
           now - last < Self.iceRestartCooldownNs {
            return
        }
        lastIceRestartAttemptUptimeNsByConnectionId[normalizedId] = now

        logger.log(
            level: .warning,
            message: "Attempting ICE-restart SFU renegotiation connId=\(normalizedId) reason=\(reason) iceState=\(iceState.rawValue)"
        )
        do {
            let updatedCall = try await sendGroupCallOffer(connection.call, iceRestart: true)
            if var refreshed = await connectionManager.findConnection(with: normalizedId) {
                refreshed.call = updatedCall
                await connectionManager.updateConnection(id: normalizedId, with: refreshed)
            }
            if let group = groupCall(forSfuIdentity: wireRoomId) ?? groupCall(forSfuIdentity: normalizedId) {
                await group.applyUpdatedCallForNegotiation(updatedCall)
            }
        } catch {
            logger.log(
                level: .error,
                message: "ICE-restart SFU renegotiation failed connId=\(normalizedId) reason=\(reason): \(error)"
            )
        }
#endif
    }
}
