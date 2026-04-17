//
//  RTCSession+PeerNotificationsHandler.swift
//  pqs-rtc
//
//  Created by Cole M on 12/3/25.
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

#if canImport(WebRTC)
import WebRTC
#endif
import BinaryCodable
import DequeModule
import Foundation

extension RTCSession {
    private func shouldHandleNotification(for connectionId: String) -> Bool {
        guard let active = activeConnectionId else { return true }
        return active.normalizedConnectionId == connectionId.normalizedConnectionId
    }

    /// Whether `connectionId` belongs to the active SFU group/conference peer connection.
    private func isGroupCallConnection(_ connectionId: String) -> Bool {
        let norm = connectionId.normalizedConnectionId
        if groupCalls[norm] != nil { return true }
        if groupCalls[connectionId] != nil { return true }
        if isGroupCall, activeConnectionId?.normalizedConnectionId == norm { return true }
        return false
    }

    /// Resolves which participantId to bind receiver FrameCryptors to.
    ///
    /// - For 1:1 calls:
    ///   - `.perParticipant`: use `connection.remoteParticipantId` (keys are provisioned under real participant ids)
    ///   - `.shared`: participantId is irrelevant → `nil`
    /// - For SFU/group calls:
    ///   - default: use the participantId derived from `streamIds` (track owner)
    ///   - production fallback (1:1 SFU rooms): if the SFU emits a UUID-like streamId that doesn't match
    ///     the real remote participant id, use `connection.remoteParticipantId` so E2EE keys line up.
    private func receiverParticipantIdOverrideForE2EE(
        connection: RTCConnection,
        participantIdFromStreamIds: String
    ) -> (override: String?, didOverrideToRemote: Bool) {
        let isGroup = isGroupCallConnection(connection.id)
        let remoteId = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamId = participantIdFromStreamIds.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isGroup {
            // 1:1 call
            if frameEncryptionKeyMode == .perParticipant {
                return (remoteId.isEmpty ? nil : remoteId, false)
            }
            return (nil, false)
        }

        // Group call (SFU)
        guard frameEncryptionKeyMode == .perParticipant else {
            // Shared mode: participantId does not affect key lookup
            return (nil, false)
        }

        guard !streamId.isEmpty else {
            return (nil, false)
        }

        // Safe fallback for 1:1 SFU rooms where SFU stream ids are random UUIDs.
        // Conference channels use `conf-<uuid>` room ids and often have empty recipients; do not
        // treat them as 1:1-over-SFU or we remap stream ids to the room string and break E2EE keys.
        let commNorm = connection.call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        let isConferenceStyleRoom = commNorm.hasPrefix("conf-")
        let isOneToOneSfuRoom = connection.call.recipients.count <= 1 && !isConferenceStyleRoom
        let streamLooksLikeUuid = UUID(uuidString: streamId) != nil
        if isOneToOneSfuRoom,
           streamLooksLikeUuid,
           !remoteId.isEmpty,
           streamId != remoteId {
            return (remoteId, true)
        }

        return (streamId, false)
    }

    /// SFU signaling sometimes attaches recv tracks labeled with the **local** participant id (self-loop /
    /// placeholder). A receiver FrameCryptor for that id has no decryption key and spams `missingKey`.
    private func shouldSkipGroupReceiverFrameCryptor(
        connection: RTCConnection,
        participantIdOverride: String?
    ) -> Bool {
        guard enableEncryption else { return false }
        guard isGroupCallConnection(connection.id) else { return false }
        guard frameEncryptionKeyMode == .perParticipant else { return false }
        let trimmedOverride = participantIdOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remote = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmedOverride.isEmpty ? remote : trimmedOverride
        guard !effective.isEmpty else { return false }
        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        return effective.caseInsensitiveCompare(local) == .orderedSame
    }
    
    func handlePeerConnectionNotifications(generation: UInt64) async {
        notificationsConsumerIsRunning = true
        logger.log(level: .info, message: "Peer-notifications consumer is now listening (generation=\(generation))")
        defer {
            notificationsConsumerIsRunning = false
            let activeConnectionIdDescription = activeConnectionId ?? "nil"
            logger.log(
                level: .info,
                message: "Peer-notifications consumer exited (generation=\(generation), cancelled=\(Task.isCancelled), currentGeneration=\(notificationsTaskGeneration), activeConnectionId=\(activeConnectionIdDescription))"
            )
        }

        var didLogFirstNotification = false
        for await notification in peerConnectionNotificationsStream {
            if Task.isCancelled { break }
            if generation != notificationsTaskGeneration { break }
            guard let notification else { continue }

            if !didLogFirstNotification {
                didLogFirstNotification = true
                logger.log(level: .info, message: "Peer-notifications consumer received first notification")
            }
            
            // Extract connection ID from notification
            let connectionId: String
            switch notification {
            case .iceGatheringDidChange(let id, _),
                    .signalingStateDidChange(let id, _),
                    .addedStream(let id, _),
                    .removedStream(let id, _),
                    .didAddReceiver(let id, _, _, _),
                    .iceConnectionStateDidChange(let id, _),
                    .generatedIceCandidate(let id, _, _, _),
                    .standardizedIceConnectionState(let id, _),
                    .removedIceCandidates(let id, _),
                    .startedReceiving(let id, _),
                    .dataChannel(let id, _),
                    .dataChannelMessage(let id, _, _),
                    .shouldNegotiate(let id):
                connectionId = id
            }
            
            // Find the matching connection
            guard let connection = await connectionManager.findConnection(with: connectionId) else {
                self.logger.log(level: .warning, message: "No connection found for id: \(connectionId)")
                continue
            }
            
            // Process notification for the specific connection
            switch notification {
            case .iceGatheringDidChange(_, let newState):
                self.logger.log(level: .info, message: "peerConnection new gathering state: \(newState.description)")
            case .signalingStateDidChange(_, let stateChanged):
                self.logger.log(level: .info, message: "peerConnection new signaling state: \(stateChanged.description)")
                if stateChanged.description == "stable" {}
            case .addedStream(_, _):
                self.logger.log(level: .info, message: "peerConnection did add stream")
#if os(Android)
                // Mirror Apple: attach sender FrameCryptors when stream is added (fallback if not already created in addAudioToStream/addVideoToStream).
                if enableEncryption && rtcClient.isFrameKeyProviderReady() {
                    rtcClient.createSenderEncryptedFrame(participant: connection.localParticipantId, connectionId: connection.id)
                    if let localScreenTrack = connection.localScreenTrack {
                        rtcClient.createScreenSenderEncryptedFrame(
                            participant: connection.localParticipantId,
                            connectionId: connection.id,
                            trackId: localScreenTrack.trackId
                        )
                    }
                } else if enableEncryption {
                    self.logger.log(level: .debug, message: "Skipping addedStream sender cryptor attach until Android key provider is ready")
                }
#elseif canImport(WebRTC)
                
                for sender in connection.peerConnection.senders {
                    let params = sender.parameters
                    for encoding in params.encodings {
                        encoding.isActive = true
                        self.logger.log(level: .info, message: "Setting Network Priority")
                        encoding.networkPriority = .high
                        self.logger.log(level: .info, message: "Set Network Priority to high")

                        // SFU/group-call reliability:
                        // Apply a conservative *starting* ceiling if none is set yet.
                        // The adaptive send loop will raise/lower this based on `availableOutgoingBitrate`.
                        if connection.id.isGroupCall, sender.track?.kind == kRTCMediaStreamTrackKindVideo {
                            let cfg = sfuVideoQualityProfile.adaptiveConfig
                            if encoding.maxBitrateBps == nil { encoding.maxBitrateBps = NSNumber(value: cfg.startingBitrateBps) }
                            if encoding.maxFramerate == nil { encoding.maxFramerate = NSNumber(value: cfg.startingFramerate) }
                        }
                    }
                    sender.parameters = params
                }
                
                do {
                    // Create video sender FrameCryptor if not already created.
                    // Filter out screen-track senders so we bind the camera cryptor
                    // to the camera sender specifically.
                    if let videoSender = connection.peerConnection.senders.first(where: {
                        $0.track?.kind == kRTCMediaStreamTrackKindVideo && !RTCSession.isScreenShareId($0.track?.trackId ?? "")
                    }), connection.videoSenderCryptor == nil {
                        if enableEncryption {
                            try await self.createEncryptedFrame(connection: connection, kind: .videoSender(videoSender))
                        }
                    }
                    // Create audio sender FrameCryptor if not already created
                    if let audioSender = connection.peerConnection.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindAudio }),
                       connection.audioSenderCryptor == nil {
                        if enableEncryption {
                            try await self.createEncryptedFrame(connection: connection, kind: .audioSender(audioSender))
                        }
                    }
                    // Create screen sender FrameCryptor if a screen track sender
                    // exists but hasn't been encrypted yet.
                    if let screenSender = connection.peerConnection.senders.first(where: {
                        $0.track?.kind == kRTCMediaStreamTrackKindVideo && RTCSession.isScreenShareId($0.track?.trackId ?? "")
                    }), connection.screenSenderCryptor == nil {
                        if enableEncryption {
                            try await self.createEncryptedFrame(connection: connection, kind: .screenSender(screenSender))
                        }
                    }
                } catch {
                    logger.log(level: .error, message: "Failed to create sender FrameCryptors in addedStream: \(error)")
                }
                
#endif
            case .removedStream(_, let streamId):
                self.logger.log(level: .info, message: "peerConnection did remove stream \(streamId)")
#if canImport(WebRTC) && !os(Android)
                if RTCSession.isScreenShareId(streamId) {
                    let participantId = RTCSession.participantIdFromScreenShareId(streamId) ?? connection.id
                    if var updated = await connectionManager.findConnection(with: connection.id) {
                        updated.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
                        if let cryptor = updated.screenReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                            cryptor.enabled = false
                            cryptor.delegate = nil
                        }
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                    }
                    notifyRemoteScreenTrackChanged(
                        RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
                    )
                }
#elseif os(Android)
                let participantId = RTCSession.participantIdFromScreenShareId(streamId) ?? streamId
                if RTCSession.isScreenShareId(streamId) {
                    if var updated = await connectionManager.findConnection(with: connection.id) {
                        updated.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
                        updated.remoteScreenTrack = nil
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                    }
                    notifyRemoteScreenTrackChanged(
                        RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
                    )
                } else {
                    if var updated = await connectionManager.findConnection(with: connection.id) {
                        updated.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                    }
                    notifyRemoteParticipantTrackChanged(
                        RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
                    )
                }
#endif
            case .didAddReceiver(_, let trackKind, let streamIds, let trackId):
                self.logger.log(level: .info, message: "peerConnection did add receiver kind=\(trackKind) trackId=\(trackId) streamIds=\(streamIds)")
                // Convention for SFU-style calls: streamId identifies the remote participant.
                // If your SFU uses a different mapping, configure `setRemoteParticipantIdResolver`.
                let participantId = remoteParticipantIdResolver?(streamIds, trackId, trackKind) ?? (streamIds.first ?? "")
#if os(Android)
                    let isScreenTrack = RTCSession.isScreenShareId(trackId) || streamIds.contains(where: { RTCSession.isScreenShareId($0) })

                    if trackKind == "video" {
                        var updated = connection
                        if isScreenTrack {
                            let resolvedScreenParticipant = participantId.isEmpty ? connection.id : participantId
                            let screenTrack = rtcClient.getRemoteScreenVideoTrackById(peerConnection: connection.peerConnection, trackId: trackId)
                                ?? rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection)
                            if let screenTrack {
                                updated.remoteScreenTrack = screenTrack
                                updated.remoteScreenTracksByParticipantId[resolvedScreenParticipant] = screenTrack
                                await connectionManager.updateConnection(id: updated.id, with: updated)
                            }
                        } else {
                            let videoTrack = rtcClient.getRemoteVideoTrackById(peerConnection: connection.peerConnection, trackId: trackId)
                                ?? rtcClient.getRemoteVideoTrack(peerConnection: connection.peerConnection)
                            if let videoTrack {
                                let resolvedParticipant = participantId.isEmpty
                                    ? (connection.remoteParticipantId.isEmpty ? connection.id : connection.remoteParticipantId)
                                    : participantId
                                updated.remoteVideoTrack = videoTrack
                                if !resolvedParticipant.isEmpty {
                                    updated.remoteVideoTracksByParticipantId[resolvedParticipant] = videoTrack
                                }
                                await connectionManager.updateConnection(id: updated.id, with: updated)

                                if let pendingRenderer = pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: updated.id.normalizedConnectionId) as? AndroidSampleCaptureView {
                                    logger.log(level: .info, message: "Attaching buffered remote renderer for 1:1 call (trackId=\(trackId))")
                                    pendingRenderer.attach(videoTrack)
                                }

                                notifyRemoteParticipantTrackChanged(
                                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: resolvedParticipant, kind: "video", isActive: true)
                                )
                            }
                        }
                    }

                    let reportedKind = isScreenTrack ? "screen" : trackKind
                    if isScreenTrack {
                        let resolvedScreenParticipant = participantId.isEmpty ? connection.id : participantId
                        notifyRemoteScreenTrackChanged(
                            RemoteScreenTrackEvent(connectionId: connection.id, participantId: resolvedScreenParticipant, isActive: true)
                        )
                    }
                    if let mediaDelegate, !participantId.isEmpty {
                        await mediaDelegate.didAddRemoteTrack(connectionId: connection.id, participantId: participantId, kind: reportedKind, trackId: trackId)
                    }

                    let receiverParticipantId: String
                    if self.isGroupCallConnection(connection.id) {
                        receiverParticipantId = participantId.isEmpty ? connection.remoteParticipantId : participantId
                    } else {
                        receiverParticipantId = connection.remoteParticipantId
                    }

                    if enableEncryption, !receiverParticipantId.isEmpty {
                        rtcClient.createReceiverEncryptedFrame(
                            participant: receiverParticipantId,
                            connectionId: connection.id,
                            trackKind: trackKind,
                            trackId: trackId
                        )
                    }
#elseif canImport(WebRTC)
                do {
                    await tryCompleteAppleDeferredReceivingMessageKey(connectionId: connection.id)

                    let isScreenTrack = RTCSession.isScreenShareId(trackId) || streamIds.contains(where: { RTCSession.isScreenShareId($0) })

                    if trackKind == kRTCMediaStreamTrackKindVideo, isScreenTrack,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let videoTrack = receiver.track as? WebRTC.RTCVideoTrack {
                        var updated = connection
                        let resolvedScreenParticipant = participantId.isEmpty ? connection.id : participantId
                        updated.remoteScreenTracksByParticipantId[resolvedScreenParticipant] = videoTrack
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                        notifyRemoteScreenTrackChanged(
                            RemoteScreenTrackEvent(connectionId: updated.id, participantId: resolvedScreenParticipant, isActive: true)
                        )

                        if let mediaDelegate {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: resolvedScreenParticipant, kind: "screen", trackId: trackId)
                        }

                        if enableEncryption {
                            let resolved = receiverParticipantIdOverrideForE2EE(
                                connection: connection,
                                participantIdFromStreamIds: participantId
                            )
                            let receiverParticipantId = resolved.override
                            if !shouldSkipGroupReceiverFrameCryptor(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                try await self.createEncryptedFrame(
                                    connection: updated,
                                    kind: .screenReceiver(receiver),
                                    participantIdOverride: receiverParticipantId)
                            } else {
                                self.logger.log(
                                    level: .debug,
                                    message: "Skipping screen receiver FrameCryptor: participant id matches local (SFU self-label).")
                            }
                        }
                    } else if trackKind == kRTCMediaStreamTrackKindVideo, !isScreenTrack,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let videoTrack = receiver.track as? WebRTC.RTCVideoTrack {
                        var updated = connection
                        if !participantId.isEmpty {
                            updated.remoteVideoTracksByParticipantId[participantId] = videoTrack
                        }
                        updated.remoteVideoTrack = videoTrack
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                        
                        if let pendingRenderer = pendingRemoteVideoRenderersByConnectionId[updated.id] {
                            logger.log(level: .info, message: "Rebinding remote renderer now that remote video track is available (trackId=\(trackId))")
                            connection.remoteVideoTrack?.remove(pendingRenderer)
                            videoTrack.add(pendingRenderer)
                        }
                        
                        if let mediaDelegate, !participantId.isEmpty {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: participantId, kind: "video", trackId: trackId)
                        }
                        
                        // Determine the correct participant ID for the receiver cryptor:
                        // - For group calls: use participantId from streamIds (identifies the track owner)
                        // - For 1:1 calls in perParticipant mode: use connection.remoteParticipantId (matches the key that was set)
                        let resolved = receiverParticipantIdOverrideForE2EE(
                            connection: connection,
                            participantIdFromStreamIds: participantId
                        )
                        let receiverParticipantId = resolved.override
                        if enableEncryption, resolved.didOverrideToRemote {
                            self.logger.log(
                                level: .warning,
                                message: "⚠️ SFU streamId '\(participantId)' looks UUID-like in 1:1 room; overriding receiver participantId -> '\(connection.remoteParticipantId)' for E2EE key alignment"
                            )
                        }

                        // Diagnostics: prove which participantId we bind the receiver FrameCryptor to,
                        // and whether we've ever provisioned a frame key for that participant id.
                        if enableEncryption {
                            let isGroup = self.isGroupCallConnection(connection.id)
                            let resolved = receiverParticipantId ?? "<nil>"
                            let lastIdx = receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] }
                            self.logger.log(
                                level: .debug,
                                message: "🔎 E2EE receiver mapping (video): connId=\(updated.id) isGroup=\(isGroup) frameKeyMode=\(self.frameEncryptionKeyMode) streamIds=\(streamIds) resolvedParticipantId=\(resolved) connection.remoteParticipantId=\(connection.remoteParticipantId) lastProvisionedKeyIndex=\(lastIdx.map(String.init) ?? "<none>")"
                            )
                            if isGroup,
                               self.frameEncryptionKeyMode == .perParticipant,
                               receiverParticipantId != nil,
                               lastIdx == nil,
                               UUID(uuidString: participantId) != nil {
                                self.logger.log(
                                    level: .warning,
                                    message: "⚠️ No frame key provisioned for resolvedParticipantId=\(resolved) yet. If SFU uses streamId UUIDs, expect FrameCryptor missingKey until keys are injected for that exact participantId (or resolver maps to real participant ids)."
                                )
                            }
                        }
                        if enableEncryption {
                            if !shouldSkipGroupReceiverFrameCryptor(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                try await self.createEncryptedFrame(
                                    connection: updated,
                                    kind: .videoReceiver(receiver),
                                    participantIdOverride: receiverParticipantId)
                            } else {
                                self.logger.log(
                                    level: .debug,
                                    message: "Skipping video receiver FrameCryptor: participant id matches local (SFU self-label / placeholder).")
                            }
                        }
                    }

                    if trackKind == kRTCMediaStreamTrackKindAudio,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let audioTrack = receiver.track as? WebRTC.RTCAudioTrack {
                        var updated = connection
                        if !participantId.isEmpty {
                            updated.remoteAudioTracksByParticipantId[participantId] = audioTrack
                        }
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                        
                        if let mediaDelegate, !participantId.isEmpty {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: participantId, kind: "audio", trackId: trackId)
                        }
                        
                        // Determine the correct participant ID for the receiver cryptor:
                        // - For group calls: use participantId from streamIds (identifies the track owner)
                        // - For 1:1 calls in perParticipant mode: use connection.remoteParticipantId (matches the key that was set)
                        let resolved = receiverParticipantIdOverrideForE2EE(
                            connection: connection,
                            participantIdFromStreamIds: participantId
                        )
                        let receiverParticipantId = resolved.override
                        if enableEncryption, resolved.didOverrideToRemote {
                            self.logger.log(
                                level: .warning,
                                message: "⚠️ SFU streamId '\(participantId)' looks UUID-like in 1:1 room; overriding receiver participantId -> '\(connection.remoteParticipantId)' for E2EE key alignment"
                            )
                        }

                        // Diagnostics: prove which participantId we bind the receiver FrameCryptor to,
                        // and whether we've ever provisioned a frame key for that participant id.
                        if enableEncryption {
                            let isGroup = self.isGroupCallConnection(connection.id)
                            let resolved = receiverParticipantId ?? "<nil>"
                            let lastIdx = receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] }
                            self.logger.log(
                                level: .debug,
                                message: "🔎 E2EE receiver mapping (audio): connId=\(updated.id) isGroup=\(isGroup) frameKeyMode=\(self.frameEncryptionKeyMode) streamIds=\(streamIds) resolvedParticipantId=\(resolved) connection.remoteParticipantId=\(connection.remoteParticipantId) lastProvisionedKeyIndex=\(lastIdx.map(String.init) ?? "<none>")"
                            )
                            if isGroup,
                               self.frameEncryptionKeyMode == .perParticipant,
                               receiverParticipantId != nil,
                               lastIdx == nil,
                               UUID(uuidString: participantId) != nil {
                                self.logger.log(
                                    level: .warning,
                                    message: "⚠️ No frame key provisioned for resolvedParticipantId=\(resolved) yet. If SFU uses streamId UUIDs, expect FrameCryptor missingKey until keys are injected for that exact participantId (or resolver maps to real participant ids)."
                                )
                            }
                        }
                        if enableEncryption {
                            if !shouldSkipGroupReceiverFrameCryptor(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                try await self.createEncryptedFrame(
                                    connection: updated,
                                    kind: .audioReceiver(receiver),
                                    participantIdOverride: receiverParticipantId)
                            } else {
                                self.logger.log(
                                    level: .debug,
                                    message: "Skipping audio receiver FrameCryptor: participant id matches local (SFU self-label / placeholder).")
                            }
                        }
                    }
                } catch {
                    logger.log(level: .error, message: "Failed to handle didAddReceiver (kind=\(trackKind), trackId=\(trackId)): \(error)")
                }
#endif
            case .iceConnectionStateDidChange(let connectionId, let newState):
                if !shouldHandleNotification(for: connection.id) {
                    self.logger.log(
                        level: .debug,
                        message: "Ignoring iceConnectionStateDidChange for non-active connection (active=\(activeConnectionId ?? "nil"), got=\(connection.id))"
                    )
                    continue
                }
                self.logger.log(level: .info, message: "peerConnection new connection state: \(newState.description)")
                if newState.state == .connected, let callDirection = await self.callState.callDirection {
                    let id: String? = connectionId
                    cancelRelayFallbackTimer(connectionId: connection.id)
                    cancelDisconnectGraceTask()
                    
                    await self.callState.transition(
                        to: .connected(
                            callDirection,
                            connection.call))
                    
#if canImport(WebRTC)
                    // Start periodic stats logging so we can prove whether RTP is actually leaving the client.
                    await startOutboundRtpStatsLoggingIfEnabled(connectionId: connection.id)
                    // Always run outbound video flow probe (caller/callee correlation; not diagnostics-gated).
                    startOutboundVideoFlowProbe(connectionId: connection.id)
                    // Start adaptive video send control only for SFU group calls that use video.
                    if connection.call.supportsVideo {
                        await startAdaptiveVideoSendIfNeeded(connectionId: connection.id)
                    }
#endif
#if os(Android)
                    if connection.call.supportsVideo {
                        await startAdaptiveVideoSendIfNeeded(connectionId: connection.id)
                    }
#endif
                }
                if newState.state == .closed {
#if canImport(WebRTC)
                    stopOutboundRtpStatsLogging(connectionId: connection.id)
                    stopOutboundVideoFlowProbe(connectionId: connection.id)
                    stopAdaptiveVideoSend(connectionId: connection.id)
#endif
#if os(Android)
                    stopAdaptiveVideoSend(connectionId: connection.id)
#endif
                    await finishEndConnection(currentCall: connection.call)
                }
            case .generatedIceCandidate(_, let sdp, let mLine, let mid):
                if !shouldHandleNotification(for: connection.id) {
                    self.logger.log(
                        level: .debug,
                        message: "Ignoring generatedIceCandidate for non-active connection (active=\(activeConnectionId ?? "nil"), got=\(connection.id))"
                    )
                    continue
                }
                do {
                    iceId += 1
                    var candidate: IceCandidate?
#if os(Android)
                    let rtc = RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLine, sdpMid: mid)
                    candidate = try IceCandidate(from: rtc, id: iceId)
#elseif canImport(WebRTC)
                    let rtc: WebRTC.RTCIceCandidate = WebRTC.RTCIceCandidate(sdp: sdp, sdpMLineIndex: mLine, sdpMid: mid)
                    candidate = try IceCandidate(from: rtc, id: iceId)
#endif
                    
                    self.logger.log(level: .info, message: "Generated Ice Candidate \(iceId)")
                    guard let candidate else {
                        self.logger.log(level: .error, message: "Generated ICE candidate could not be constructed (id=\(iceId))")
                        continue
                    }
                    
                    let connKey = connection.id.normalizedConnectionId
                    if readyForCandidatesByConnectionId[connKey] == true {
                        do {
                            try await sendEncryptedSfuCandidateFromDeque(candidate, call: connection.call)
                        } catch {
                            self.logger.log(level: .error, message: "Failed to send ICE candidate (id=\(candidate.id)): \(error)")
                        }
                    } else {
                        iceDequeByConnectionId[connKey, default: Deque<IceCandidate>()].append(candidate)
                    }
                } catch {
                    self.logger.log(level: .error, message: "Failed to Send Ice Candidate \(error)")
                }
            case .standardizedIceConnectionState(let connectionId, let newState):
                if !shouldHandleNotification(for: connection.id) {
                    self.logger.log(
                        level: .debug,
                        message: "Ignoring standardizedIceConnectionState for non-active connection (active=\(activeConnectionId ?? "nil"), got=\(connection.id))"
                    )
                    continue
                }
                self.logger.log(level: .info, message: "peerConnection did change ice state \(newState.description)")

                // Some platforms primarily surface "connected/completed" through standardized ICE.
                // Ensure fallback timer and call-state are updated from this path as well.
                if newState.state == .connected || newState.state == .completed {
                    cancelRelayFallbackTimer(connectionId: connection.id)
                    cancelDisconnectGraceTask()
                    if let callDirection = await self.callState.callDirection,
                       case .connecting = await self.callState.currentState {
                        await self.callState.transition(
                            to: .connected(
                                callDirection,
                                connection.call))
                    }
                }

                // During relay fallback retry we intentionally close/recreate the peer.
                // Ignore stale disconnected/failed/closed callbacks from the recycled peer
                // until retry completes, otherwise we can tear down the fresh replacement.
                if relayFallbackRetryingConnectionIds.contains(connection.id.normalizedConnectionId),
                   newState.state == .failed || newState.state == .disconnected || newState.state == .closed {
                    self.logger.log(level: .debug, message: "Ignoring ICE state \(newState.description) while relay fallback retry is in progress for \(connection.id)")
                    continue
                }
                
                if newState.state == .failed {
                    if await retryWithRelayIfNeeded(call: connection.call, reason: "ice_failed") {
                        continue
                    }
                }

                if newState.state == .disconnected {
                    if shouldDeferDisconnectFailure(for: connection.call) {
                        self.logger.log(level: .warning, message: "Deferring disconnect failure while outbound relay fallback remains available for \(connection.id)")
                        continue
                    }
                    if case .connected = await self.callState.currentState {
                        armDisconnectGraceTimer(for: connection)
                        continue
                    }
                }

                if newState.state == .failed || newState.state == .disconnected || newState.state == .closed {
                    cancelDisconnectGraceTask()
#if canImport(WebRTC)
                    stopOutboundRtpStatsLogging(connectionId: connection.id)
                    stopOutboundVideoFlowProbe(connectionId: connection.id)
#endif
                    let connKey = connection.id.normalizedConnectionId
                    iceDequeByConnectionId[connKey] = nil
                    readyForCandidatesByConnectionId[connKey] = nil
                    if let id = connectionId as String? {
                        cancelRelayFallbackTimer(connectionId: id)
                    }

                    let errorMessage: String
                    if newState.state == .failed {
                        errorMessage = "PeerConnection Failed"
                    } else if newState.state == .disconnected {
                        errorMessage = "PeerConnection Disconnected"
                    } else {
                        errorMessage = "PeerConnection Closed"
                    }

                    let callDirection: CallStateMachine.CallDirection
                    if let existingDirection = await self.callState.callDirection {
                        callDirection = existingDirection
                    } else {
                        callDirection = .inbound(connection.call.supportsVideo ? .video : .voice)
                    }

                    await callState.transition(to: .failed(callDirection, connection.call, errorMessage))
                    await finishEndConnection(currentCall: connection.call)
                }
                
            case .removedIceCandidates(_, _):
                self.logger.log(level: .info, message: "peerConnection did remove candidate(s)")
            case .startedReceiving(_, let trackKind):
                self.logger.log(level: .info, message: "peerConnection didStartReceiving \(trackKind)")
#if canImport(WebRTC)
                do {
                    await tryCompleteAppleDeferredReceivingMessageKey(connectionId: connection.id)
                    // Determine the correct participant ID for receiver cryptors:
                    // - For group calls: participantIdOverride will be set in didAddReceiver
                    // - For 1:1 calls in perParticipant mode: use remoteParticipantId to match the key
                    let receiverParticipantId: String?
                    if self.isGroupCallConnection(connection.id) {
                        // Group call: participantId will be set when didAddReceiver fires
                        receiverParticipantId = nil
                    } else if self.frameEncryptionKeyMode == .perParticipant {
                        // 1:1 call in perParticipant mode: use remoteParticipantId to match the key
                        receiverParticipantId = connection.remoteParticipantId
                    } else {
                        // 1:1 call in shared mode: participantId doesn't matter
                        receiverParticipantId = nil
                    }
                    
                    if trackKind == "video", let videoReceiver = connection.peerConnection.transceivers.first(where: {
                        $0.mediaType == .video && !RTCSession.isScreenShareId($0.receiver.track?.trackId ?? "")
                    })?.receiver {
                        if enableEncryption,
                           !shouldSkipGroupReceiverFrameCryptor(
                            connection: connection,
                            participantIdOverride: receiverParticipantId) {
                            try await self.createEncryptedFrame(connection: connection, kind: .videoReceiver(videoReceiver), participantIdOverride: receiverParticipantId)
                        }
                    }
                    if trackKind == "audio", let audioReceiver = connection.peerConnection.transceivers.first(where: { $0.mediaType == .audio })?.receiver {
                        if enableEncryption,
                           !shouldSkipGroupReceiverFrameCryptor(
                            connection: connection,
                            participantIdOverride: receiverParticipantId) {
                            try await self.createEncryptedFrame(connection: connection, kind: .audioReceiver(audioReceiver), participantIdOverride: receiverParticipantId)
                        }
                    }
                } catch {
                    logger.log(level: .error, message: "Failed to create encrypted frame")
                }
#endif
            case .dataChannel(let connectionId, let channelLabel):
                logger.log(level: .info, message: "Data channel '\(channelLabel)' opened for connection \(connectionId)")
#if canImport(WebRTC) && !os(Android)
                if let dataChannel = connection.delegateWrapper.delegate?.getDataChannel(for: channelLabel) {
                    var updated = connection
                    updated.dataChannels[channelLabel] = dataChannel
                    await connectionManager.updateConnection(id: updated.id, with: updated)
                }
#endif
            case .dataChannelMessage(_, let channelLabel, let data):
                
                self.logger.log(level: .info, message: "Received data channel message on channel: \(channelLabel), size: \(data.count) bytes")
                do {
                    try await processDataMessage(
                        connectionId: connectionId,
                        channelLabel: channelLabel,
                        data: data)
                } catch {
                    logger.log(level: .error, message: "Failed to process data message: \(error)")
                }
            case .shouldNegotiate(_):
                self.logger.log(level: .info, message: "peerConnection should negotiate")
                let normId = connection.id.normalizedConnectionId
                if pendingInitialSfuGroupOfferConnectionIds.contains(normId) {
                    self.logger.log(
                        level: .debug,
                        message: "Skipping shouldNegotiate SFU offer during initial group bootstrap for connection=\(connection.id)")
                } else if isGroupCallConnection(connection.id) {
                    // For SFU/group calls, proactively generate and send a fresh offer when the
                    // peer requests renegotiation (e.g. new remote participants/tracks).
                    do {
                        let updatedCall = try await sendGroupCallOffer(connection.call)
                        if var refreshed = await connectionManager.findConnection(with: connection.id) {
                            refreshed.call = updatedCall
                            await connectionManager.updateConnection(id: refreshed.id, with: refreshed)
                        }
                        self.logger.log(level: .info, message: "Handled peerConnection shouldNegotiate by sending SFU renegotiation offer for connection=\(connection.id)")
                    } catch {
                        self.logger.log(level: .error, message: "Failed to handle shouldNegotiate for connection=\(connection.id): \(error)")
                    }
                } else {
                    self.logger.log(level: .debug, message: "Ignoring shouldNegotiate for non-group connection=\(connection.id)")
                }
            }
        }
    }
}
