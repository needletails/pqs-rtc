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
    ) {
        let connectionId = normalizedFallbackConnectionId(for: call.sharedCommunicationId)
        let direction = inferredCallDirection(for: call)
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
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
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
        guard case .outbound = existing.direction else { return false }
        guard existing.currentPolicy == .all, !existing.hasRetriedToRelay else { return false }

        guard let state = await callState.currentState else { return false }
        switch state {
        case .connecting:
            break
        default:
            return false
        }

        existing.hasRetriedToRelay = true
        existing.currentPolicy = .relay
        existing.timeoutTask?.cancel()
        existing.timeoutTask = nil
        connectionFallbackStateByConnectionId[connectionId] = existing

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
            logger.log(level: .error, message: "Relay fallback retry failed for connection=\(connectionId): \(error)")
            if let direction = await callState.callDirection {
                await callState.transition(to: .failed(direction, existing.latestCall, "Relay fallback failed: \(error.localizedDescription)"))
            }
            await finishEndConnection(currentCall: existing.latestCall)
            return false
        }
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
        readyForCandidates = false
        iceDeque.removeAll()
        pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: connectionId)
#if os(Android)
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
            connection.videoFrameCryptor?.enabled = false
            connection.videoSenderCryptor?.enabled = false
            connection.audioFrameCryptor?.enabled = false
            connection.audioSenderCryptor?.enabled = false
            connection.videoFrameCryptor?.delegate = nil
            connection.videoSenderCryptor?.delegate = nil
            connection.audioFrameCryptor?.delegate = nil
            connection.audioSenderCryptor?.delegate = nil
#endif
#if os(Android)
            stopAdaptiveVideoSend(connectionId: connectionId)
            rtcClient.close()
#else
            connection.peerConnection.delegate = nil
            connection.peerConnection.close()
#endif
            await connectionManager.removeConnection(with: connectionId)
        }
    }
}
