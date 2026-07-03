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
    internal static func shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder(
        enableEncryption: Bool,
        isGroupCallConnection: Bool,
        frameEncryptionKeyMode: RTCFrameEncryptionKeyMode,
        participantIdOverride: String?
    ) -> Bool {
        guard enableEncryption else { return false }
        guard isGroupCallConnection else { return false }
        guard frameEncryptionKeyMode == .perParticipant else { return false }
        let resolved = participantIdOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolved.isEmpty else { return false }
        return UUID(uuidString: resolved) != nil
    }

    internal static func shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
        enableEncryption: Bool,
        isGroupCallConnection: Bool,
        frameEncryptionKeyMode: RTCFrameEncryptionKeyMode,
        participantIdOverride: String?,
        connectionId: String,
        remoteParticipantId: String,
        localParticipantId: String?
    ) -> Bool {
        guard enableEncryption else { return false }
        guard isGroupCallConnection else { return false }
        guard frameEncryptionKeyMode == .perParticipant else { return false }

        let raw = participantIdOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return true }

        let normalizedFromMediaLabel = normalizedRemoteParticipantIdFromSfuMediaLabel(
            raw,
            connectionId: connectionId,
            localParticipantId: localParticipantId
        )
        let effective = (normalizedFromMediaLabel ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effective.isEmpty else { return true }

        if normalizedFromMediaLabel == nil {
            let lowercasedRaw = raw.lowercased()
            if lowercasedRaw.hasPrefix("audio_")
                || lowercasedRaw.hasPrefix("video_")
                || lowercasedRaw.hasPrefix("streamid_") {
                return true
            }
        }

        if UUID(uuidString: effective) != nil {
            return true
        }

        let local = localParticipantId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !local.isEmpty, effective.caseInsensitiveCompare(local) == .orderedSame {
            return true
        }

        let participantKey = effective.normalizedConnectionId.lowercased()
        let connectionKey = connectionId.normalizedConnectionId.lowercased()
        let remoteKey = remoteParticipantId.normalizedConnectionId.lowercased()
        return participantKey == connectionKey || (!remoteKey.isEmpty && participantKey == remoteKey)
    }

    internal static func normalizedRemoteParticipantIdFromSfuMediaLabel(
        _ rawLabel: String,
        connectionId: String,
        localParticipantId: String?
    ) -> String? {
        var id = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard !RTCSession.isScreenShareId(id) else { return nil }

        if id.hasPrefix("streamId_") {
            id = String(id.dropFirst("streamId_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if id.hasPrefix("video_") {
            id = String(id.dropFirst("video_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if id.hasPrefix("audio_") {
            id = String(id.dropFirst("audio_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmedConnectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let connectionSuffixes = [
            "_\(trimmedConnectionId)",
            "_\(trimmedConnectionId.normalizedConnectionId)",
            "_\(trimmedConnectionId.ensureIRCChannel)"
        ]
        for suffix in connectionSuffixes where !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if id.hasSuffix("_") {
            id = String(id.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !id.isEmpty else { return nil }
        guard UUID(uuidString: id) == nil else { return nil }
        guard !RTCSession.isScreenShareId(id) else { return nil }
        guard !Self.isGenericWebRTCStreamLabel(id) else { return nil }

        let local = localParticipantId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !local.isEmpty, id.caseInsensitiveCompare(local) == .orderedSame {
            return nil
        }

        return id
    }

    private static func isGenericWebRTCStreamLabel(_ value: String) -> Bool {
        let label = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return label == "stream"
            || label == "default"
            || label == "audio"
            || label == "video"
            || label == "remote"
            || label == "local"
    }

    /// WebRTC/msid recv stream labels often use `secretName_` while receive keys use `secretName`.
    ///
    /// - **1:1 SFU:** Normalize only when the stripped label matches the resolved remote peer
    ///   (conservative).
    /// - **Conference / multi-party SFU:** The same `peer_` msid pattern applies, but
    ///   ``remoteTrackOwnerParticipantId`` may still be the room id (`conf-…`), so the strict match
    ///   never succeeds. When the stripped id is not the local participant and not UUID-like, treat
    ///   it as the publisher `secretName` for FrameCryptor key lookup.
    internal static func normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
        streamId: String,
        isOneToOneSfuRoom: Bool,
        isGroupCallConnection: Bool,
        effectiveRemoteSecretName: String?,
        localParticipantSecretName: String?
    ) -> String? {
        let s = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasSuffix("_") else { return nil }
        let withoutUnderscore = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutUnderscore.isEmpty else { return nil }

        let effective = effectiveRemoteSecretName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let local = localParticipantSecretName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if (isOneToOneSfuRoom || isGroupCallConnection),
           !effective.isEmpty,
           withoutUnderscore.caseInsensitiveCompare(effective) == .orderedSame {
            return effective
        }

        if isOneToOneSfuRoom {
            // 1:1-over-SFU: only the strict match above.
            return nil
        }

        if isGroupCallConnection,
           !local.isEmpty,
           withoutUnderscore.caseInsensitiveCompare(local) != .orderedSame,
           UUID(uuidString: withoutUnderscore) == nil {
            return withoutUnderscore
        }

        return nil
    }

    private func shouldHandleNotification(for connectionId: String) -> Bool {
        guard let active = activeConnectionId else { return true }
        return active.normalizedConnectionId == connectionId.normalizedConnectionId
    }

    /// Whether `connectionId` belongs to the active SFU group/conference peer connection.
    func isGroupCallConnection(_ connectionId: String) -> Bool {
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
    ///   - production fallback (1:1 SFU rooms): if the SFU emits a UUID-like streamId, remap to the
    ///     **remote peer's** frame id (same as ``remoteTrackOwnerParticipantId`` / sender `localParticipantId`),
    ///     not the room id in `connection.recipient`, so FrameCryptor key lookup matches
    ///     ``setReceivingMessageKey`` and the remote sender's local sender key.
    ///     This guards a historical outage where remote tracks attached successfully but rendered
    ///     zero decrypted frames because receiver cryptors were bound to room/placeholder ids.
    ///   - WebRTC/msid labels often use a trailing underscore (`echo_`, `nudge_`) while frame keys are
    ///     provisioned under the peer ``secretName`` without that suffix — remap so rebinding after
    ///     renegotiation does not attach cryptors to ids with no receive-key entry (symptom: ICE
    ///     connected, tracks attached, **zero** decrypted video frames).
    private func receiverParticipantIdOverrideForE2EE(
        connection: RTCConnection,
        participantIdFromStreamIds: String
    ) -> (override: String?, didOverrideToRemote: Bool, isUuidLikeStreamRemap: Bool) {
        let isGroup = isGroupCallConnection(connection.id)
        let remoteId = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamId = participantIdFromStreamIds.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isGroup {
            // 1:1 call
            if frameEncryptionKeyMode == .perParticipant {
                return (remoteId.isEmpty ? nil : remoteId, false, false)
            }
            return (nil, false, false)
        }

        // Group call (SFU)
        guard frameEncryptionKeyMode == .perParticipant else {
            // Shared mode: participantId does not affect key lookup
            return (nil, false, false)
        }

        guard !streamId.isEmpty else {
            return (nil, false, false)
        }
        guard !Self.isGenericWebRTCStreamLabel(streamId) else {
            return (nil, false, false)
        }

        // Safe fallback for 1:1 SFU rooms where SFU stream ids are random UUIDs.
        // Conference channels use `conf-<uuid>` room ids and often have empty recipients; do not
        // treat them as 1:1-over-SFU or we remap stream ids to the room string and break E2EE keys.
        let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: connection.call)
        let streamLooksLikeUuid = UUID(uuidString: streamId) != nil
        if isOneToOneSfuRoom,
           streamLooksLikeUuid {
            let effectiveRemote = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)
                ?? remoteId
            if !effectiveRemote.isEmpty,
               streamId.caseInsensitiveCompare(effectiveRemote) != .orderedSame {
                return (effectiveRemote, true, true)
            }
        }

        // Conference SFU relay screen legs often publish UUID stream labels (no `screen_<participant>`
        // prefix). Frame keys are provisioned under stable participant ids such as `echo`.
        #if canImport(WebRTC) && !os(Android)
        if isGroup,
           !isOneToOneSfuRoom,
           streamLooksLikeUuid {
            let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
            let loneRemoteParticipantIds = connection.remoteVideoTracksByParticipantId.keys.compactMap { key -> String? in
                let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty, candidate.caseInsensitiveCompare(local) != .orderedSame else { return nil }
                return candidate
            }
            if loneRemoteParticipantIds.count == 1, let relay = loneRemoteParticipantIds.first {
                return (relay, true, true)
            }
            if let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !owner.isEmpty {
                return (owner, true, true)
            }
        }
        #endif

        if isGroup,
           let normalized = Self.normalizedRemoteParticipantIdFromSfuMediaLabel(
            streamId,
            connectionId: connection.id,
            localParticipantId: connection.localParticipantId
           ) {
            if isOneToOneSfuRoom {
                let effectiveRemote = (remoteTrackOwnerParticipantId(connection: connection, call: connection.call) ?? remoteId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if effectiveRemote.isEmpty
                    || normalized.caseInsensitiveCompare(effectiveRemote) == .orderedSame {
                    return (normalized, true, false)
                }
            } else {
                return (normalized, true, false)
            }
        }

        // Native/SFU PeerConnection often publishes recv stream labels as `secretName_` (msid) while
        // frame encryption keys use `secretName` from the call graph — align cryptor ids with keys.
        let effectiveRemoteForUnderscore = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)
            ?? remoteId
        if let normalized = Self.normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
            streamId: streamId,
            isOneToOneSfuRoom: isOneToOneSfuRoom,
            isGroupCallConnection: isGroup,
            effectiveRemoteSecretName: effectiveRemoteForUnderscore,
            localParticipantSecretName: connection.localParticipantId
        ) {
            return (normalized, true, false)
        }

        return (streamId, false, false)
    }

    /// SFU signaling sometimes attaches recv tracks labeled with the **local** participant id (self-loop /
    /// placeholder). A receiver FrameCryptor for that id has no decryption key and spams `missingKey`.
    private func shouldSkipGroupReceiverFrameCryptor(
        connection: RTCConnection,
        participantIdOverride: String?
    ) -> Bool {
        Self.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: enableEncryption,
            isGroupCallConnection: isGroupCallConnection(connection.id),
            frameEncryptionKeyMode: frameEncryptionKeyMode,
            participantIdOverride: participantIdOverride,
            connectionId: connection.id,
            remoteParticipantId: connection.remoteParticipantId,
            localParticipantId: connection.localParticipantId
        )
    }

    /// Whether a camera receiver should be surfaced to multi-participant UI as an actual remote tile.
    ///
    /// Apple Unified Plan can emit a receiver/track for the initial SFU answer even when the SFU has no
    /// remote source to forward yet. In those answers the recv stream label is UUID-shaped and the SDP
    /// carries no remote SSRC/msid, so rendering it creates a black "remote participant" tile forever.
    func shouldSurfaceRemoteParticipantCameraTrack(
        connection: RTCConnection,
        participantId: String
    ) -> Bool {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if Self.isTrueOneToOneSfuRoom(call: connection.call) {
            let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !local.isEmpty, trimmed.caseInsensitiveCompare(local) == .orderedSame {
                logger.log(
                    level: .info,
                    message: "Ignoring self-labeled 1:1 SFU camera receiver participantId=\(trimmed) connection=\(connection.id)"
                )
                return false
            }
            return true
        }
        guard isGroupCallConnection(connection.id) else { return true }
        if UUID(uuidString: trimmed) != nil {
            logger.log(
                level: .info,
                message: "Ignoring UUID-like SFU placeholder camera receiver participantId=\(trimmed) connection=\(connection.id)"
            )
            return false
        }
        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty, trimmed.caseInsensitiveCompare(local) == .orderedSame {
            logger.log(
                level: .info,
                message: "Ignoring self-labeled SFU camera receiver participantId=\(trimmed) connection=\(connection.id)"
            )
            return false
        }
        let connectionKey = connection.id.normalizedConnectionId.lowercased()
        let remoteKey = connection.remoteParticipantId.normalizedConnectionId.lowercased()
        let participantKey = trimmed.normalizedConnectionId.lowercased()
        if participantKey == connectionKey || (!remoteKey.isEmpty && participantKey == remoteKey) {
            logger.log(
                level: .info,
                message: "Ignoring room-labeled SFU camera receiver participantId=\(trimmed) connection=\(connection.id)"
            )
            return false
        }
        return true
    }

    /// In SFU group calls, a UUID-like stream id is often a transient placeholder before
    /// renegotiation publishes the stable participant id (`echo`/`nudge`/etc). Binding receiver
    /// FrameCryptors to that placeholder causes permanent `missingKey` unless we later rebind.
    private func shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
        connection: RTCConnection,
        participantIdOverride: String?
    ) -> Bool {
        Self.shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder(
            enableEncryption: enableEncryption,
            isGroupCallConnection: isGroupCallConnection(connection.id),
            frameEncryptionKeyMode: frameEncryptionKeyMode,
            participantIdOverride: participantIdOverride
        )
    }

    private func oneToOneSfuRemoteScreenParticipantId(
        in connection: RTCConnection
    ) -> String? {
        guard Self.isTrueOneToOneSfuRoom(call: connection.call) else { return nil }
        let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let owner, !owner.isEmpty {
            return owner
        }
        let remote = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        return remote.isEmpty ? nil : remote
    }

    #if canImport(WebRTC) && !os(Android)
    /// WebRTC fires `didAddReceiver` only once for the SFU recv transceiver. The first answer can
    /// contain only a UUID-like placeholder stream id, then a later SFU renegotiation updates the
    /// same receiver with the real publisher `msid` (`echo_`, `nudge_`, etc.). Reconcile after every
    /// remote SDP so that real participant camera tracks are surfaced even when no second receiver
    /// callback is emitted.
    func reconcileAppleRemoteParticipantCameraTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isAppleSfuMediaConnection(connection) else { return }

        let cameraLabels = appleStableRemoteCameraTrackLabels(in: remoteSdp, connection: connection)
        let participantIds = cameraLabels.map(\.participantId)
        guard !participantIds.isEmpty else { return }

        connection = clearUuidAliasedReceiverCryptors(on: connection, keepingParticipantId: nil)

        let cameraReceivers: [(receiver: RTCRtpReceiver, track: RTCVideoTrack, mid: String)] = connection.peerConnection.transceivers.compactMap { transceiver in
            guard transceiver.mediaType == .video,
                  let track = transceiver.receiver.track as? RTCVideoTrack,
                  !RTCSession.isScreenShareId(track.trackId),
                  !isAppleDedicatedScreenShareTransceiver(transceiver, connection: connection),
                  track.readyState != .ended
            else { return nil }
            return (transceiver.receiver, track, transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !cameraReceivers.isEmpty else {
            logger.log(
                level: .warning,
                message: "SFU SDP advertised participant camera msid(s) \(participantIds) but no live video receiver exists for connection=\(connection.id)"
            )
            return
        }

        var updated = connection
        var consumedTrackIds = Set<String>()
        var didUpdate = false

        for label in cameraLabels {
            let participantId = label.participantId
            guard shouldSurfaceRemoteParticipantCameraTrack(connection: updated, participantId: participantId) else { continue }

            if let existing = updated.remoteVideoTracksByParticipantId[participantId],
               existing.readyState != .ended {
                consumedTrackIds.insert(existing.trackId)
                let advertisedTrackId = label.trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let advertisedMid = label.mid?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let livePair = cameraReceivers.first(where: { pair in
                    guard pair.track.trackId == existing.trackId || pair.track === existing else { return false }
                    if let advertisedTrackId, !advertisedTrackId.isEmpty {
                        return pair.track.trackId == advertisedTrackId
                    }
                    if let advertisedMid, !advertisedMid.isEmpty {
                        return pair.mid == advertisedMid
                    }
                    return pair.track.trackId == existing.trackId
                }), livePair.track !== existing {
                    let remoteSdp = updated.peerConnection.remoteDescription?.sdp ?? ""
                    let advertisedOwners = Self.advertisedRemoteCameraOwnersByTrackId(in: remoteSdp)
                    let allowOwnershipTransfer = advertisedOwners[livePair.track.trackId]
                        .map {
                            Self.conferenceParticipantIdentityKey($0) == Self.conferenceParticipantIdentityKey(participantId)
                        } ?? true
                    if Self.claimRemoteCameraTrack(
                        livePair.track,
                        participantId: participantId,
                        in: &updated,
                        allowReplacingExistingStableOwner: allowOwnershipTransfer
                    ) {
                        didUpdate = true
                    }
                }
                if enableEncryption,
                   updated.videoReceiverCryptorsByParticipantId[participantId] == nil,
                   let pair = cameraReceivers.first(where: { $0.track === existing }) {
                    do {
                        try await createEncryptedFrame(
                            connection: updated,
                            kind: .videoReceiver(pair.receiver),
                            participantIdOverride: participantId
                        )
                    } catch {
                        logger.log(
                            level: .error,
                            message: "Failed to rebind video receiver FrameCryptor for SFU participant=\(participantId): \(error)"
                        )
                    }
                    if let refreshed = await connectionManager.findConnection(with: updated.id) {
                        updated = refreshed
                    }
                }
                continue
            }

            let advertisedTrackId = label.trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let advertisedMid = label.mid?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pair = cameraReceivers.first(where: { pair in
                guard !consumedTrackIds.contains(pair.track.trackId) else { return false }
                guard let advertisedTrackId, !advertisedTrackId.isEmpty else { return false }
                return pair.track.trackId == advertisedTrackId
            }) ?? cameraReceivers.first(where: { pair in
                guard !consumedTrackIds.contains(pair.track.trackId) else { return false }
                guard let advertisedMid, !advertisedMid.isEmpty else { return false }
                return pair.mid == advertisedMid
            }) ?? cameraReceivers.first(where: { pair in
                guard !consumedTrackIds.contains(pair.track.trackId) else { return false }
                return !updated.remoteVideoTracksByParticipantId.values.contains(where: { $0 === pair.track })
            }) ?? cameraReceivers.first(where: { !consumedTrackIds.contains($0.track.trackId) }) else {
                logger.log(
                    level: .warning,
                    message: "No unmapped camera receiver available for SFU participant=\(participantId) connection=\(updated.id)"
                )
                continue
            }

            guard Self.claimRemoteCameraTrack(
                pair.track,
                participantId: participantId,
                in: &updated,
                allowReplacingExistingStableOwner: {
                    let remoteSdp = updated.peerConnection.remoteDescription?.sdp ?? ""
                    let advertisedOwners = Self.advertisedRemoteCameraOwnersByTrackId(in: remoteSdp)
                    guard let owner = advertisedOwners[pair.track.trackId] else { return false }
                    return Self.conferenceParticipantIdentityKey(owner) == Self.conferenceParticipantIdentityKey(participantId)
                }()
            ) else {
                logger.log(
                    level: .warning,
                    message: "Rejected duplicate SFU camera receiver claim participant=\(participantId) trackId=\(pair.track.trackId) connection=\(updated.id)"
                )
                continue
            }
            updated.remoteVideoTrack = pair.track
            consumedTrackIds.insert(pair.track.trackId)
            didUpdate = true
            await connectionManager.updateConnection(id: updated.id, with: updated)

            logger.log(
                level: .info,
                message: "Mapped SFU renegotiated camera receiver to participant=\(participantId) trackId=\(pair.track.trackId) connection=\(updated.id)"
            )

            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(connectionId: updated.id, participantId: participantId, kind: "video", isActive: true)
            )

            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: updated.id,
                    participantId: participantId,
                    kind: "video",
                    trackId: pair.track.trackId
                )
            }

            if enableEncryption {
                do {
                    try await createEncryptedFrame(
                        connection: updated,
                        kind: .videoReceiver(pair.receiver),
                        participantIdOverride: participantId
                    )
                } catch {
                    logger.log(
                        level: .error,
                        message: "Failed to bind video receiver FrameCryptor for SFU participant=\(participantId): \(error)"
                    )
                }
                if let refreshed = await connectionManager.findConnection(with: updated.id) {
                    updated = refreshed
                }
            }
        }

        if didUpdate {
            await connectionManager.updateConnection(id: updated.id, with: updated)
        }
    }

    /// Apple WebRTC can reuse the same recv audio track across SFU leave/rejoin cycles while the
    /// SDP advertises a fresh `a=msid:<participant> <track-id>` value. Reconcile the stable owner
    /// from SDP after every remote description so receiver audio FrameCryptors are rebound under
    /// the same participant id as the sender frame key.
    func reconcileAppleRemoteParticipantAudioTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isAppleSfuMediaConnection(connection) else { return }

        let participantIds = stableRemoteAudioParticipantIds(in: remoteSdp, connection: connection)
        guard !participantIds.isEmpty else { return }

        connection = clearUuidAliasedReceiverCryptors(on: connection, keepingParticipantId: nil)

        let audioReceivers: [(receiver: RTCRtpReceiver, track: RTCAudioTrack)] = connection.peerConnection.transceivers.compactMap { transceiver in
            guard transceiver.mediaType == .audio,
                  // The local publish m-line's receiver is not a remote leg; binding a remote
                  // participant (and their frame key) to it garbles that participant's audio.
                  transceiver.sender.track == nil,
                  let track = transceiver.receiver.track as? RTCAudioTrack,
                  track.readyState != .ended
            else { return nil }
            return (transceiver.receiver, track)
        }
        guard !audioReceivers.isEmpty else {
            logger.log(
                level: .warning,
                message: "SFU SDP advertised participant audio msid(s) \(participantIds) but no live audio receiver exists for connection=\(connection.id)"
            )
            return
        }

        suppressUnboundAppleRemoteSfuAudioReceivers(connection)

        var updated = connection
        var consumedTrackIds = Set<String>()
        var didUpdate = false

        for participantId in participantIds {
            if let existing = updated.remoteAudioTracksByParticipantId[participantId],
               existing.readyState != .ended {
                let advertisedIds = advertisedSfuRemoteMediaTrackIds(
                    mediaKind: "audio",
                    participantId: participantId,
                    connection: updated
                )
                let preferredPair = audioReceivers.first(where: { pair in
                    pair.track.readyState != .ended
                        && pair.track !== existing
                        && (advertisedIds.isEmpty || advertisedIds.contains(pair.track.trackId))
                })
                let activeTrack: RTCAudioTrack
                let activeReceiver: RTCRtpReceiver?
                if let preferredPair,
                   !advertisedIds.isEmpty,
                   advertisedIds.contains(preferredPair.track.trackId) {
                    existing.isEnabled = false
                    // Decrypt must follow the new leg: drop the cryptor bound to the superseded
                    // receiver so the rebind below re-creates it on `activeReceiver`. This must
                    // happen BEFORE syncing playback — otherwise the stale binding releases the
                    // new leg with no cryptor on its receiver and ciphertext hits the decoder.
                    if let staleCryptor = updated.audioReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                        staleCryptor.enabled = false
                        staleCryptor.delegate = nil
                        if updated.audioFrameCryptor === staleCryptor {
                            updated.audioFrameCryptor = nil
                        }
                    }
                    updated.audioReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
                    updated.remoteAudioTracksByParticipantId[participantId] = preferredPair.track
                    syncAppleRemoteSfuAudioTrackPlayback(
                        connection: updated,
                        participantId: participantId,
                        track: preferredPair.track
                    )
                    activeTrack = preferredPair.track
                    activeReceiver = preferredPair.receiver
                    didUpdate = true
                    // Persist the drop immediately: createEncryptedFrame below re-reads the stored
                    // connection (and can defer during renegotiation), and the refresh after it
                    // must not resurrect the stale binding/cryptor from the connection manager.
                    await connectionManager.updateConnection(id: updated.id, with: updated)
                    logger.log(
                        level: .info,
                        message: "Upgraded SFU audio mapping participant=\(participantId) from trackId=\(existing.trackId) to advertised trackId=\(preferredPair.track.trackId) connection=\(updated.id)"
                    )
                } else {
                    syncAppleRemoteSfuAudioTrackPlayback(
                        connection: updated,
                        participantId: participantId,
                        track: existing
                    )
                    activeTrack = existing
                    activeReceiver = audioReceivers.first(where: { $0.track === existing })?.receiver
                }
                consumedTrackIds.insert(activeTrack.trackId)
                if enableEncryption,
                   updated.audioReceiverCryptorsByParticipantId[participantId] == nil,
                   let activeReceiver {
                    do {
                        try await createEncryptedFrame(
                            connection: updated,
                            kind: .audioReceiver(activeReceiver),
                            participantIdOverride: participantId
                        )
                    } catch {
                        logger.log(
                            level: .error,
                            message: "Failed to rebind audio receiver FrameCryptor for SFU participant=\(participantId): \(error)"
                        )
                    }
                    if let refreshed = await connectionManager.findConnection(with: updated.id) {
                        updated = refreshed
                    }
                }
                continue
            }

            guard let pair = audioReceivers.first(where: { pair in
                guard !consumedTrackIds.contains(pair.track.trackId) else { return false }
                return !updated.remoteAudioTracksByParticipantId.values.contains(where: { $0 === pair.track })
            }) ?? audioReceivers.first(where: { !consumedTrackIds.contains($0.track.trackId) }) else {
                logger.log(
                    level: .warning,
                    message: "No unmapped audio receiver available for SFU participant=\(participantId) connection=\(updated.id)"
                )
                continue
            }

            if let prior = updated.remoteAudioTracksByParticipantId[participantId],
               prior !== pair.track,
               prior.readyState != .ended {
                prior.isEnabled = false
            }

            syncAppleRemoteSfuAudioTrackPlayback(
                connection: updated,
                participantId: participantId,
                track: pair.track
            )
            updated.remoteAudioTracksByParticipantId[participantId] = pair.track
            consumedTrackIds.insert(pair.track.trackId)
            didUpdate = true
            await connectionManager.updateConnection(id: updated.id, with: updated)

            logger.log(
                level: .info,
                message: "Mapped SFU renegotiated audio receiver to participant=\(participantId) trackId=\(pair.track.trackId) connection=\(updated.id)"
            )

            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: updated.id,
                    participantId: participantId,
                    kind: "audio",
                    trackId: pair.track.trackId
                )
            }

            if enableEncryption {
                do {
                    try await createEncryptedFrame(
                        connection: updated,
                        kind: .audioReceiver(pair.receiver),
                        participantIdOverride: participantId
                    )
                } catch {
                    logger.log(
                        level: .error,
                        message: "Failed to bind audio receiver FrameCryptor for SFU participant=\(participantId): \(error)"
                    )
                }
                if let refreshed = await connectionManager.findConnection(with: updated.id) {
                    updated = refreshed
                }
            }
        }

        if disableSupersededAppleInboundAudioReceivers(
            connection: &updated,
            keepingActiveTrackIds: consumedTrackIds
        ) {
            didUpdate = true
        }

        releaseAllAppleRemoteSfuAudioTracksWithBoundCryptors(updated)

        if didUpdate {
            await connectionManager.updateConnection(id: updated.id, with: updated)
        }
    }

    #if canImport(WebRTC) && !os(Android)
    /// Disables stale SFU audio receivers after renegotiation (e.g. group → 1:1 upgrade leaves both
    /// anonymous UUID legs and `audio_echo_*` direct legs enabled, which garbles playback).
    @discardableResult
    private func disableSupersededAppleInboundAudioReceivers(
        connection: inout RTCConnection,
        keepingActiveTrackIds activeTrackIds: Set<String>
    ) -> Bool {
        guard isAppleSfuMediaConnection(connection) else { return false }
        guard !activeTrackIds.isEmpty else { return false }

        var didUpdate = false
        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .audio {
            guard let track = transceiver.receiver.track as? RTCAudioTrack,
                  track.readyState != .ended,
                  track.isEnabled,
                  !activeTrackIds.contains(track.trackId)
            else { continue }

            let retireInOneToOne = Self.isTrueOneToOneSfuRoom(call: connection.call)
            let isAnonymousLeg = UUID(uuidString: track.trackId) != nil
            guard retireInOneToOne || isAnonymousLeg else { continue }

            track.isEnabled = false
            didUpdate = true

            for (participantId, mappedTrack) in connection.remoteAudioTracksByParticipantId where mappedTrack === track {
                connection.remoteAudioTracksByParticipantId.removeValue(forKey: participantId)
                if let cryptor = connection.audioReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                    cryptor.enabled = false
                    cryptor.delegate = nil
                    if connection.audioFrameCryptor === cryptor {
                        connection.audioFrameCryptor = nil
                    }
                }
                connection.audioReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
            }

            logger.log(
                level: .info,
                message: "Disabled superseded SFU audio receiver trackId=\(track.trackId) connection=\(connection.id) activeLegs=\(activeTrackIds.sorted())"
            )
        }
        return didUpdate
    }
    #endif

    /// WebRTC may not emit `didRemoveStream` when the SFU removes only the screen-share sender
    /// during renegotiation, and it may not emit a second `didAddReceiver` when the same recv
    /// transceiver is reused for a subsequent share. Reconcile stored screen tracks against the
    /// current remote SDP so tiles disappear when sharing stops and reappear when sharing resumes.
    #if canImport(WebRTC) && !os(Android)
    private func appleTransceiver(
        for receiver: RTCRtpReceiver,
        in peerConnection: RTCPeerConnection
    ) -> RTCRtpTransceiver? {
        let receiverObjectId = ObjectIdentifier(receiver)
        if let matched = peerConnection.transceivers.first(where: { ObjectIdentifier($0.receiver) == receiverObjectId }) {
            return matched
        }
        guard let trackId = receiver.track?.trackId else { return nil }
        return peerConnection.transceivers.first { $0.receiver.track?.trackId == trackId }
    }

    private func appleTransceiver(
        containingVideoTrackId trackId: String,
        in peerConnection: RTCPeerConnection
    ) -> RTCRtpTransceiver? {
        peerConnection.transceivers.first {
            $0.mediaType == .video && $0.receiver.track?.trackId == trackId
        }
    }

    private func appleVideoTransceivers(in peerConnection: RTCPeerConnection) -> [RTCRtpTransceiver] {
        peerConnection.transceivers.filter { $0.mediaType == .video }
    }

    /// SFU viewers use additional `m=video` transceivers for screen-share slots. In 1:1 SFU rooms
    /// the second transceiver is typically the screen leg; in conference calls each remote
    /// participant has their own camera transceiver and must not be classified as screen by index alone.
    private func allowsAppleSlotBasedScreenShareInference(connection: RTCConnection) -> Bool {
        Self.isTrueOneToOneSfuRoom(call: connection.call)
    }

    private func appleDedicatedScreenShareTransceivers(
        in peerConnection: RTCPeerConnection,
        connection: RTCConnection
    ) -> [RTCRtpTransceiver] {
        let videoTransceivers = appleVideoTransceivers(in: peerConnection)
        guard !videoTransceivers.isEmpty else { return [] }
        let cameraTrackIds = Set(connection.remoteVideoTracksByParticipantId.values.map(\.trackId))

        let explicitScreenTransceivers = videoTransceivers.filter { transceiver in
            RTCSession.isAppleTransceiverReceivingRemoteMedia(transceiver)
                && (
                    RTCSession.isScreenShareId(transceiver.receiver.track?.trackId ?? "")
                        || transceiver.sender.streamIds.contains(where: RTCSession.isScreenShareId)
                )
        }
        if !explicitScreenTransceivers.isEmpty {
            if let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
               !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let relayMids = activeIncomingScreenShareVideoMids(in: remoteSdp, connection: connection)
                if !relayMids.isEmpty {
                    if let contractRelay = Self.contractScreenRelayTransceiver(
                        among: explicitScreenTransceivers,
                        relayMids: relayMids
                    ) {
                        return [contractRelay]
                    }
                    let relayReceivers = videoTransceivers.filter { transceiver in
                        guard RTCSession.isAppleTransceiverReceivingRemoteMedia(transceiver) else { return false }
                        let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard relayMids.contains(mid) else { return false }
                        guard let track = transceiver.receiver.track as? RTCVideoTrack,
                              track.readyState != .ended
                        else { return false }
                        if Self.isSfuCameraMediaId(track.trackId) { return false }
                        if cameraTrackIds.contains(track.trackId) { return false }
                        if connection.remoteVideoTracksByParticipantId.values.contains(where: { $0 === track }) {
                            return false
                        }
                        return true
                    }
                    if let contractRelay = Self.contractScreenRelayTransceiver(
                        among: relayReceivers,
                        relayMids: relayMids
                    ) {
                        return [contractRelay]
                    }
                }
            }
            if let last = explicitScreenTransceivers.last {
                return [last]
            }
        }

        let relayScreenTransceivers = videoTransceivers.filter { transceiver in
            guard RTCSession.isAppleTransceiverReceivingRemoteMedia(transceiver) else { return false }
            guard let track = transceiver.receiver.track as? RTCVideoTrack,
                  track.readyState != .ended
            else { return false }
            if Self.isSfuCameraMediaId(track.trackId) { return false }
            if cameraTrackIds.contains(track.trackId) { return false }
            if connection.remoteVideoTracksByParticipantId.values.contains(where: { $0 === track }) {
                return false
            }
            return true
        }
        if isGroupCallConnection(connection.id), !Self.isTrueOneToOneSfuRoom(call: connection.call) {
            guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
                  !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return [] }
            let relayMids = activeIncomingScreenShareVideoMids(in: remoteSdp, connection: connection)
            guard !relayMids.isEmpty else { return [] }
            let relayReceivers = relayScreenTransceivers.filter { transceiver in
                let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
                return !mid.isEmpty && relayMids.contains(mid)
            }
            if let contractRelay = Self.contractScreenRelayTransceiver(
                among: relayReceivers,
                relayMids: relayMids
            ) {
                return [contractRelay]
            }
            return Array(relayReceivers.suffix(1))
        }
        if let relayScreenTransceiver = relayScreenTransceivers.last {
            return [relayScreenTransceiver]
        }

        guard allowsAppleSlotBasedScreenShareInference(connection: connection),
              videoTransceivers.count == 2
        else { return [] }
        return [videoTransceivers[1]]
    }

    private func isAppleDedicatedScreenShareTransceiver(
        _ transceiver: RTCRtpTransceiver,
        connection: RTCConnection
    ) -> Bool {
        if RTCSession.isScreenShareId(transceiver.receiver.track?.trackId ?? "")
            || transceiver.sender.streamIds.contains(where: RTCSession.isScreenShareId) {
            return true
        }
        if let track = transceiver.receiver.track,
           connection.remoteVideoTracksByParticipantId.values.contains(where: { $0 === track }) {
            return false
        }
        return appleDedicatedScreenShareTransceivers(in: connection.peerConnection, connection: connection)
            .contains { $0 === transceiver }
    }

    private func liveScreenReceiverCandidates(
        in connection: RTCConnection,
        excludingTrackIds: Set<String> = []
    ) -> [(receiver: RTCRtpReceiver, track: RTCVideoTrack)] {
        appleDedicatedScreenShareTransceivers(in: connection.peerConnection, connection: connection).compactMap { transceiver in
            guard let track = transceiver.receiver.track as? RTCVideoTrack,
                  track.readyState != .ended,
                  !excludingTrackIds.contains(track.trackId)
            else { return nil }
            return (transceiver.receiver, track)
        }
    }

    private static func contractScreenRelayTransceiver(
        among transceivers: [RTCRtpTransceiver],
        relayMids: Set<String>
    ) -> RTCRtpTransceiver? {
        let contractMid = ScreenShareGroupCallContract.MediaMid.screen.rawValue
        guard relayMids.contains(contractMid) else { return nil }
        return transceivers.first {
            $0.mid.trimmingCharacters(in: .whitespacesAndNewlines) == contractMid
        }
    }

    /// Live screen receiver on an SFU relay `m=video` mid for a known remote sharer.
    private func relayScreenReceiverPair(
        for participantId: String,
        connection: RTCConnection,
        remoteSdp: String,
        excludingTrackIds: Set<String> = []
    ) -> (receiver: RTCRtpReceiver, track: RTCVideoTrack)? {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return nil }
        let cameraTrackIds = Set(connection.remoteVideoTracksByParticipantId.compactMap { key, track -> String? in
            guard Self.conferenceParticipantIdentityKey(key) == participantKey else { return nil }
            return track.trackId
        })
        let relayMids = activeIncomingScreenShareVideoMids(in: remoteSdp, connection: connection)
        guard !relayMids.isEmpty else { return nil }
        let contractMid = ScreenShareGroupCallContract.MediaMid.screen.rawValue
        let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: connection.call)

        let preferredTransceiver = connection.peerConnection.transceivers.first { transceiver in
            guard transceiver.mediaType == .video else { return false }
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard mid == contractMid, relayMids.contains(contractMid) else { return false }
            guard let track = transceiver.receiver.track as? RTCVideoTrack,
                  track.readyState != .ended,
                  !excludingTrackIds.contains(track.trackId),
                  !cameraTrackIds.contains(track.trackId),
                  (Self.isScreenShareId(track.trackId) || isOneToOneSfuRoom)
            else { return false }
            return true
        }
        guard let transceiver = preferredTransceiver,
              let track = transceiver.receiver.track as? RTCVideoTrack
        else { return nil }
        return (transceiver.receiver, track)
    }

    private func reclaimWronglyMappedCameraAsScreen(
        participantId: String,
        connection: RTCConnection
    ) -> (receiver: RTCRtpReceiver, track: RTCVideoTrack)? {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return nil }
        guard let cameraTrack = connection.remoteVideoTracksByParticipantId.first(where: {
            Self.conferenceParticipantIdentityKey($0.key) == participantKey
        })?.value,
              cameraTrack.readyState != .ended
        else { return nil }
        guard let transceiver = connection.peerConnection.transceivers.first(where: {
            $0.receiver.track === cameraTrack || $0.receiver.track?.trackId == cameraTrack.trackId
        }),
              isAppleDedicatedScreenShareTransceiver(transceiver, connection: connection)
        else { return nil }
        return (transceiver.receiver, cameraTrack)
    }

    private func clearRemoteCameraMapping(
        for participantId: String,
        on connection: inout RTCConnection,
        track: RTCVideoTrack
    ) {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        for key in connection.remoteVideoTracksByParticipantId.keys
        where Self.conferenceParticipantIdentityKey(key) == participantKey
            && (
                connection.remoteVideoTracksByParticipantId[key] === track
                    || connection.remoteVideoTracksByParticipantId[key]?.trackId == track.trackId
            ) {
            connection.remoteVideoTracksByParticipantId.removeValue(forKey: key)
        }
        if connection.remoteVideoTrack === track || connection.remoteVideoTrack?.trackId == track.trackId {
            connection.remoteVideoTrack = nil
        }
    }

    private func isAppleSfuMediaConnection(_ connection: RTCConnection) -> Bool {
        isGroupCallConnection(connection.id) || Self.isTrueOneToOneSfuRoom(call: connection.call)
    }

    private func shouldTreatAppleVideoTrackAsRemoteScreenShare(
        trackId: String,
        streamIds: [String],
        transceiver: RTCRtpTransceiver,
        connection: RTCConnection
    ) -> Bool {
        if RTCSession.isScreenShareId(trackId) || streamIds.contains(where: RTCSession.isScreenShareId) {
            return true
        }
        if isGroupCallConnection(connection.id),
           !Self.isTrueOneToOneSfuRoom(call: connection.call) {
            // Multiparty SFU camera receivers can temporarily land on the reserved screen
            // transceiver during renegotiation. Only explicit `screen_*` identity should
            // create screen-share UI in group calls.
            return false
        }
        guard isAppleSfuMediaConnection(connection),
              isAppleDedicatedScreenShareTransceiver(transceiver, connection: connection)
        else { return false }
        return true
    }

    private func resolvedAppleRelayScreenShareParticipantId(
        streamIds: [String],
        trackId: String,
        connection: RTCConnection
    ) -> String? {
        if let mapped = normalizedKnownRemoteScreenParticipantId(trackId, connection: connection) {
            return mapped
        }
        let streamParticipant = streamIds.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !streamParticipant.isEmpty,
           UUID(uuidString: streamParticipant) == nil,
           let normalized = normalizedRemoteParticipantIdFromSfuStreamLabel(streamParticipant, connection: connection) {
            return normalized
        }
        if let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !owner.isEmpty {
            return owner
        }
        return ambiguousRelayScreenParticipantId(in: connection)
    }

    /// Remote screen sharers advertised in the current SFU remote SDP, including relay-style
    /// `m=video` legs that never produced a `remoteScreenTracksByParticipantId` mapping.
    func sdpAdvertisedActiveRemoteScreenShareParticipantIds(connection: RTCConnection) -> [String] {
        #if canImport(WebRTC)
        guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
              !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return stableRemoteScreenTrackLabels(in: remoteSdp, connection: connection).map(\.participantId)
        #else
        return []
        #endif
    }

    /// Retries SDP reconcile when screen-share was advertised before a live receiver existed.
    func reconcileDeferredAppleRemoteScreenTracksIfNeeded(connectionId: String) async {
        #if canImport(WebRTC)
        guard let connection = await connectionManager.findConnection(with: connectionId),
              isAppleSfuMediaConnection(connection),
              let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
              !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let advertised = stableRemoteScreenTrackLabels(in: remoteSdp, connection: connection)
        let hasUnmappedAdvertisement = advertised.contains { label in
            let participantKey = Self.conferenceParticipantIdentityKey(label.participantId)
            guard !participantKey.isEmpty else { return false }
            return !connection.remoteScreenTracksByParticipantId.contains { participantId, track in
                Self.conferenceParticipantIdentityKey(participantId) == participantKey
                    && track.readyState != .ended
            }
        }
        guard hasUnmappedAdvertisement, !liveScreenReceiverCandidates(in: connection).isEmpty else { return }

        await reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(remoteSdp, connectionId: connectionId)
        #endif
    }
    #endif

    private func mappedScreenReceiverMidIsActiveInSdp(
        participantId: String,
        connection: RTCConnection,
        remoteSdp: String
    ) -> Bool {
        guard let track = connection.remoteScreenTracksByParticipantId[participantId]
            ?? connection.remoteScreenTracksByParticipantId.first(where: {
                Self.conferenceParticipantIdentityKey($0.key)
                    == Self.conferenceParticipantIdentityKey(participantId)
            })?.value,
              track.readyState != .ended
        else { return false }

        let activeRelayMids = activeIncomingScreenShareVideoMids(in: remoteSdp, connection: connection)
        guard !activeRelayMids.isEmpty else { return false }

        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .video {
            guard transceiver.receiver.track === track else { continue }
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            return activeRelayMids.contains(mid)
        }
        return false
    }
    #endif

    private func activeIncomingScreenShareVideoMids(
        in remoteSdp: String,
        connection: RTCConnection
    ) -> Set<String> {
        var mids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
            .union(Self.sfuRelayIncomingScreenShareVideoMids(in: remoteSdp))
        if Self.isTrueOneToOneSfuRoom(call: connection.call) {
            mids.formUnion(Self.oneToOneSfuIncomingScreenShareVideoMids(in: remoteSdp))
        }
        return mids
    }

    private func ambiguousRelayScreenParticipantId(in connection: RTCConnection) -> String? {
        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteParticipantIds = connection.remoteVideoTracksByParticipantId.keys.compactMap { key -> String? in
            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, candidate.caseInsensitiveCompare(local) != .orderedSame else { return nil }
            return candidate
        }
        guard remoteParticipantIds.count == 1 else { return nil }
        return remoteParticipantIds[0]
    }

    #if canImport(WebRTC) && !os(Android)
    func reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isAppleSfuMediaConnection(connection) else { return }

        let advertisedLabels = stableRemoteScreenTrackLabels(in: remoteSdp, connection: connection)
        let advertisedParticipantList = advertisedLabels.map(\.participantId)
        let advertisedParticipants = Set(advertisedParticipantList)
        let explicitlyInactiveParticipants = Set(inactiveRemoteScreenParticipantIds(in: remoteSdp, connection: connection))
        let advertisedCameraParticipants = Set(stableRemoteCameraParticipantIds(in: remoteSdp, connection: connection))

        var didUpdate = false
        for uuidKey in connection.remoteScreenTracksByParticipantId.keys where !Self.isPlausibleConferenceScreenShareParticipantId(uuidKey) {
            connection.remoteScreenTracksByParticipantId.removeValue(forKey: uuidKey)
            connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: uuidKey)
            connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: uuidKey)
            didUpdate = true
            logger.log(
                level: .info,
                message: "Removed UUID-alias remote screen-share mapping during SDP reconcile participant=\(uuidKey) connection=\(connection.id)"
            )
        }

        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) {
            guard let track = connection.remoteScreenTracksByParticipantId[participantId],
                  Self.isSfuCameraMediaId(track.trackId)
            else { continue }

            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            let staleScreenKeys = connection.remoteScreenTracksByParticipantId.keys.filter { key in
                Self.conferenceParticipantIdentityKey(key) == participantKey
                    || connection.remoteScreenTracksByParticipantId[key]?.trackId == track.trackId
            }
            for staleKey in staleScreenKeys {
                connection.remoteScreenTracksByParticipantId.removeValue(forKey: staleKey)
                if let cryptor = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: staleKey) {
                    cryptor.enabled = false
                    cryptor.delegate = nil
                }
                connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: staleKey)
            }
            let reclaimedCameraTrack = !participantKey.isEmpty
                && !connection.remoteVideoTracksByParticipantId.keys.contains(where: {
                    Self.conferenceParticipantIdentityKey($0) == participantKey
                })
                && Self.claimRemoteCameraTrack(track, participantId: participantId, in: &connection)
            didUpdate = true
            logger.log(
                level: .info,
                message: "Reclaimed SFU camera-labelled track from remote screen-share mapping participant=\(participantId) trackId=\(track.trackId) connection=\(connection.id)"
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
            )
            if reclaimedCameraTrack {
                notifyRemoteParticipantTrackChanged(
                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: true)
                )
            } else {
                logger.log(
                    level: .warning,
                    message: "Rejected duplicate SFU camera reclaim from screen mapping participant=\(participantId) trackId=\(track.trackId) connection=\(connection.id)"
                )
            }
        }

        func isStillAdvertised(_ participantId: String) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            return advertisedParticipants.contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        }

        func isExplicitlyInactive(_ participantId: String) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            return explicitlyInactiveParticipants.contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        }

        func hasAdvertisedCamera(_ participantId: String) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            return advertisedCameraParticipants.contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        }

        func existingScreenTrack(for participantId: String, in connection: RTCConnection) -> RTCVideoTrack? {
            if let exact = connection.remoteScreenTracksByParticipantId[participantId],
               exact.readyState != .ended {
                return exact
            }
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            guard !participantKey.isEmpty else { return nil }
            return connection.remoteScreenTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key) == participantKey
            }?.value
        }

        func hasKnownRemoteCamera(_ participantId: String, in connection: RTCConnection) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            if connection.remoteVideoTracksByParticipantId.keys.contains(where: {
                Self.conferenceParticipantIdentityKey($0) == participantKey
            }) {
                return true
            }
            return hasAdvertisedCamera(participantId)
        }

        func hasLiveScreenReceiver(for participantId: String, in connection: RTCConnection) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            let cameraTrackIds = Set(connection.remoteVideoTracksByParticipantId.compactMap { key, track -> String? in
                guard Self.conferenceParticipantIdentityKey(key) == participantKey else { return nil }
                return track.trackId
            })
            let relayMids = activeIncomingScreenShareVideoMids(in: remoteSdp, connection: connection)

            return connection.peerConnection.transceivers.contains { transceiver in
                guard transceiver.mediaType == .video,
                      let track = transceiver.receiver.track as? RTCVideoTrack,
                      track.readyState != .ended
                else { return false }
                if cameraTrackIds.contains(track.trackId) { return false }

                let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
                if !relayMids.isEmpty, mid.isEmpty || !relayMids.contains(mid) {
                    return false
                }
                if !mid.isEmpty,
                   relayMids.contains(mid),
                   isStillAdvertised(participantId) {
                    return true
                }

                guard shouldTreatAppleVideoTrackAsRemoteScreenShare(
                    trackId: track.trackId,
                    streamIds: [],
                    transceiver: transceiver,
                    connection: connection
                ) else { return false }

                if let mappedId = normalizedKnownRemoteScreenParticipantId(track.trackId, connection: connection) {
                    return Self.conferenceParticipantIdentityKey(mappedId) == participantKey
                }
                if let relayId = resolvedAppleRelayScreenShareParticipantId(
                    streamIds: [],
                    trackId: track.trackId,
                    connection: connection
                ) {
                    return Self.conferenceParticipantIdentityKey(relayId) == participantKey
                }
                if let existing = existingScreenTrack(for: participantId, in: connection) {
                    return existing.trackId == track.trackId
                }
                return false
            }
        }

        var removedScreenParticipants = Set<String>()
        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) {
            let forceRemoveAfterStopRequest = await shouldForceRemoveRemoteScreenShareAfterStopRequest(
                participantId: participantId,
                in: connection,
                remoteSdp: remoteSdp,
                connectionId: connectionId
            )
            let shouldReconcileRemoval = !isStillAdvertised(participantId)
                || isExplicitlyInactive(participantId)
                || forceRemoveAfterStopRequest
            guard shouldReconcileRemoval else { continue }

            let stopForwarded = isRemoteScreenShareStopForwardedInSdp(
                participantId: participantId,
                remoteSdp: remoteSdp,
                connection: connection
            )
            if !forceRemoveAfterStopRequest,
               !isExplicitlyInactive(participantId),
               !stopForwarded,
               hasLiveScreenReceiver(for: participantId, in: connection) {
                let mappingMidActive = mappedScreenReceiverMidIsActiveInSdp(
                    participantId: participantId,
                    connection: connection,
                    remoteSdp: remoteSdp
                )
                let placeholderOnlySdp = Self.isSfuRecvonlyPlaceholderOnlyRemoteSdp(remoteSdp)
                let hasExplicitScreenTrack = existingScreenTrack(for: participantId, in: connection)
                    .map { RTCSession.isScreenShareId($0.trackId) } ?? false
                let shouldKeep = isStillAdvertised(participantId)
                    || mappingMidActive
                    || (placeholderOnlySdp && hasExplicitScreenTrack)
                if shouldKeep {
                    logger.log(
                        level: .info,
                        message: "Keeping live remote screen-share receiver during SDP reconcile participant=\(participantId) connection=\(connection.id)"
                    )
                    if placeholderOnlySdp && hasExplicitScreenTrack {
                        notifyRemoteScreenTrackChanged(
                            RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: true)
                        )
                    }
                    continue
                }
            }
            if forceRemoveAfterStopRequest {
                logger.log(
                    level: .info,
                    message: "Clearing remote screen-share mapping after preempt stop for participant=\(participantId) connection=\(connection.id)"
                )
            }
            removedScreenParticipants.insert(participantId)
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            let staleScreenKeys = connection.remoteScreenTracksByParticipantId.keys.filter {
                Self.conferenceParticipantIdentityKey($0) == participantKey
            }
            let removedTrackIds = Set(staleScreenKeys.compactMap {
                connection.remoteScreenTracksByParticipantId[$0]?.trackId
            })
            let keysToRemove = connection.remoteScreenTracksByParticipantId.keys.filter { key in
                staleScreenKeys.contains(key)
                    || removedTrackIds.contains(connection.remoteScreenTracksByParticipantId[key]?.trackId ?? "")
            }
            for staleKey in keysToRemove {
                connection.remoteScreenTracksByParticipantId.removeValue(forKey: staleKey)
                if let cryptor = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: staleKey) {
                    cryptor.enabled = false
                    cryptor.delegate = nil
                }
                connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: staleKey)
            }
            let suppressedKey = Self.conferenceParticipantIdentityKey(participantId)
            if !suppressedKey.isEmpty {
                connection.suppressedRemoteScreenShareParticipantIds.insert(suppressedKey)
                connection.remoteScreenShareStopRequestedParticipantKeys.remove(suppressedKey)
                clearRemoteScreenIngressFlatObservation(
                    connectionId: connection.id,
                    participantKey: suppressedKey
                )
            }
            didUpdate = true
            logger.log(
                level: .info,
                message: "Removed stale remote screen-share track after SDP reconcile participant=\(participantId) connection=\(connection.id)"
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
            )
        }

        if didUpdate {
            await connectionManager.updateConnection(id: connection.id, with: connection)
        }

        if !advertisedParticipantList.isEmpty {
        let explicitScreenReceivers = liveScreenReceiverCandidates(in: connection)

        var updated = connection
        var consumedTrackIds = Set(updated.remoteScreenTracksByParticipantId.values.map(\.trackId))

        for label in advertisedLabels {
            let participantId = label.participantId
            let advertisedParticipantKey = Self.conferenceParticipantIdentityKey(participantId)
            if !advertisedParticipantKey.isEmpty,
               removedScreenParticipants.contains(where: {
                   Self.conferenceParticipantIdentityKey($0) == advertisedParticipantKey
               }) {
                continue
            }
            if shouldSkipRemoteScreenShareMapping(
                participantId: participantId,
                connection: updated,
                remoteSdp: remoteSdp
            ) {
                continue
            }
            if let existing = existingScreenTrack(for: participantId, in: updated) {
                let reclaimedPair = reclaimWronglyMappedCameraAsScreen(participantId: participantId, connection: updated)
                let slotPair = liveScreenReceiverCandidates(in: updated, excludingTrackIds: consumedTrackIds).first
                let relayPair = relayScreenReceiverPair(
                    for: participantId,
                    connection: updated,
                    remoteSdp: remoteSdp,
                    excludingTrackIds: consumedTrackIds
                )
                if let livePair = relayPair ?? slotPair ?? reclaimedPair,
                   livePair.track.trackId != existing.trackId {
                    updated.remoteScreenTracksByParticipantId[participantId] = livePair.track
                    consumedTrackIds.insert(livePair.track.trackId)
                    didUpdate = true
                    await connectionManager.updateConnection(id: updated.id, with: updated)
                    logger.log(
                        level: .info,
                        message: "Rebound SFU relay screen receiver during SDP reconcile participant=\(participantId) oldTrackId=\(existing.trackId) newTrackId=\(livePair.track.trackId) connection=\(updated.id)"
                    )
                    notifyRemoteScreenTrackChanged(
                        RemoteScreenTrackEvent(connectionId: updated.id, participantId: participantId, isActive: true)
                    )
                    if enableEncryption {
                        do {
                            try await createEncryptedFrame(
                                connection: updated,
                                kind: .screenReceiver(livePair.receiver),
                                participantIdOverride: participantId
                            )
                        } catch {
                            logger.log(
                                level: .error,
                                message: "Failed to rebind screen receiver FrameCryptor during relay reconcile participant=\(participantId): \(error)"
                            )
                        }
                        if let refreshed = await connectionManager.findConnection(with: updated.id) {
                            updated = refreshed
                        }
                    }
                } else {
                    consumedTrackIds.insert(existing.trackId)
                }
                let mappedKey = Self.conferenceParticipantIdentityKey(participantId)
                if !mappedKey.isEmpty, updated.suppressedRemoteScreenShareParticipantIds.remove(mappedKey) != nil {
                    didUpdate = true
                }
                continue
            }

            let trackIdMatch: (receiver: RTCRtpReceiver, track: RTCVideoTrack)? = {
                guard let trackId = label.trackId?.trimmingCharacters(in: .whitespacesAndNewlines), !trackId.isEmpty else {
                    return nil
                }
                return updated.peerConnection.receivers.compactMap { receiver -> (RTCRtpReceiver, RTCVideoTrack)? in
                    guard let track = receiver.track as? RTCVideoTrack,
                          track.trackId == trackId,
                          track.readyState != .ended
                    else { return nil }
                    return (receiver, track)
                }.first
            }()
            let reclaimedPair = reclaimWronglyMappedCameraAsScreen(participantId: participantId, connection: updated)
            let relayPair = relayScreenReceiverPair(
                for: participantId,
                connection: updated,
                remoteSdp: remoteSdp,
                excludingTrackIds: consumedTrackIds
            )
            let slotPair = liveScreenReceiverCandidates(in: updated, excludingTrackIds: consumedTrackIds).first
            guard let pair = trackIdMatch
                ?? relayPair
                ?? slotPair
                ?? explicitScreenReceivers.first(where: { !consumedTrackIds.contains($0.track.trackId) })
                ?? reclaimedPair
            else {
                logger.log(
                    level: .warning,
                    message: "SFU SDP advertised screen msid for participant=\(participantId) but no live screen receiver exists connection=\(updated.id)"
                )
                continue
            }

            if let reclaimedPair, pair.track === reclaimedPair.track || pair.track.trackId == reclaimedPair.track.trackId {
                clearRemoteCameraMapping(for: participantId, on: &updated, track: reclaimedPair.track)
                logger.log(
                    level: .info,
                    message: "Reclaimed camera-mapped screen-slot receiver for participant=\(participantId) trackId=\(pair.track.trackId) connection=\(updated.id)"
                )
            }

            updated.remoteScreenTracksByParticipantId[participantId] = pair.track
            consumedTrackIds.insert(pair.track.trackId)
            let mappedKey = Self.conferenceParticipantIdentityKey(participantId)
            if !mappedKey.isEmpty {
                updated.suppressedRemoteScreenShareParticipantIds.remove(mappedKey)
            }
            didUpdate = true
            await connectionManager.updateConnection(id: updated.id, with: updated)

            logger.log(
                level: .info,
                message: "Mapped SFU renegotiated screen receiver to participant=\(participantId) trackId=\(pair.track.trackId) connection=\(updated.id)"
            )

            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: updated.id, participantId: participantId, isActive: true)
            )

            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: updated.id,
                    participantId: participantId,
                    kind: "screen",
                    trackId: pair.track.trackId
                )
            }

            if enableEncryption {
                do {
                    try await createEncryptedFrame(
                        connection: updated,
                        kind: .screenReceiver(pair.receiver),
                        participantIdOverride: participantId
                    )
                } catch {
                    logger.log(
                        level: .error,
                        message: "Failed to bind screen receiver FrameCryptor for SFU participant=\(participantId): \(error)"
                    )
                }
                if let refreshed = await connectionManager.findConnection(with: updated.id) {
                    updated = refreshed
                }
            }
        }

        if didUpdate {
            await connectionManager.updateConnection(id: updated.id, with: updated)
        }
        }

        if let latest = await connectionManager.findConnection(with: connectionId) {
            await discoverUnmappedLiveAppleScreenReceivers(
                connection: latest,
                remoteSdp: remoteSdp,
                removedScreenParticipants: removedScreenParticipants,
                explicitlyInactiveParticipants: explicitlyInactiveParticipants,
                activelyAdvertisedParticipantKeys: Set(
                    advertisedParticipantList.map { Self.conferenceParticipantIdentityKey($0) }.filter { !$0.isEmpty }
                )
            )
        }
    }

    /// Surfaces remote screen shares when SFU SDP uses recvonly/inactive placeholders without `screen_`
    /// msids. WebRTC often reuses the recv transceiver and does not emit another `didAddReceiver`.
    private func discoverUnmappedLiveAppleScreenReceivers(
        connection: RTCConnection,
        remoteSdp: String,
        removedScreenParticipants: Set<String>,
        explicitlyInactiveParticipants: Set<String>,
        activelyAdvertisedParticipantKeys: Set<String> = []
    ) async {
        var updated = connection
        var didUpdate = false

        func participantKey(_ participantId: String) -> String {
            Self.conferenceParticipantIdentityKey(participantId)
        }

        func isMappedParticipant(_ participantId: String) -> Bool {
            let key = participantKey(participantId)
            return updated.remoteScreenTracksByParticipantId.keys.contains { participantKey($0) == key }
        }

        func wasRemovedThisReconcile(_ participantId: String) -> Bool {
            let key = participantKey(participantId)
            return removedScreenParticipants.contains { participantKey($0) == key }
        }

        func isExplicitlyInactiveParticipant(_ participantId: String) -> Bool {
            let key = participantKey(participantId)
            return explicitlyInactiveParticipants.contains { participantKey($0) == key }
        }

        func shouldSkipDiscovery(for participantId: String) -> Bool {
            if wasRemovedThisReconcile(participantId) || isExplicitlyInactiveParticipant(participantId) {
                return true
            }
            if shouldSkipRemoteScreenShareMapping(
                participantId: participantId,
                connection: updated,
                remoteSdp: remoteSdp
            ) {
                return true
            }
            let key = participantKey(participantId)
            if !key.isEmpty, updated.suppressedRemoteScreenShareParticipantIds.contains(key) {
                guard activelyAdvertisedParticipantKeys.contains(key) else { return true }
                updated.suppressedRemoteScreenShareParticipantIds.remove(key)
                didUpdate = true
            }
            let local = updated.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
            return !local.isEmpty && participantId.caseInsensitiveCompare(local) == .orderedSame
        }

        func transceiverHasActiveLocalScreenSender(_ transceiver: RTCRtpTransceiver) -> Bool {
            guard let track = transceiver.sender.track as? RTCVideoTrack else { return false }
            return track.readyState != .ended && RTCSession.isScreenShareId(track.trackId)
        }

        func mappedTrackIds() -> Set<String> {
            Set(updated.remoteScreenTracksByParticipantId.values.map(\.trackId))
        }

        var consumedTrackIds = mappedTrackIds()

        for transceiver in updated.peerConnection.transceivers {
            guard transceiver.mediaType == .video,
                  let track = transceiver.receiver.track as? RTCVideoTrack,
                  track.readyState != .ended,
                  !consumedTrackIds.contains(track.trackId),
                  shouldTreatAppleVideoTrackAsRemoteScreenShare(
                      trackId: track.trackId,
                      streamIds: [],
                      transceiver: transceiver,
                      connection: updated
                  )
            else { continue }

            guard let participantId = resolvedAppleRelayScreenShareParticipantId(
                streamIds: [],
                trackId: track.trackId,
                connection: updated
            ) ?? normalizedKnownRemoteScreenParticipantId(track.trackId, connection: updated),
                  !shouldSkipDiscovery(for: participantId),
                  !isMappedParticipant(participantId),
                  !transceiverHasActiveLocalScreenSender(transceiver)
            else { continue }

            if isGroupCallConnection(updated.id) {
                let participantIdentityKey = participantKey(participantId)
                let activeRelayMids = activeIncomingScreenShareVideoMids(in: remoteSdp, connection: updated)
                guard !activeRelayMids.isEmpty else { continue }
                let transceiverMid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
                let onRelayMid = !transceiverMid.isEmpty && activeRelayMids.contains(transceiverMid)
                let advertisedOnActiveRelay = activelyAdvertisedParticipantKeys.contains(participantIdentityKey)
                    && onRelayMid
                guard onRelayMid || advertisedOnActiveRelay else { continue }
            }

            consumedTrackIds.insert(track.trackId)
            updated.remoteScreenTracksByParticipantId[participantId] = track
            let mappedKey = participantKey(participantId)
            if !mappedKey.isEmpty {
                updated.suppressedRemoteScreenShareParticipantIds.remove(mappedKey)
            }
            didUpdate = true
            await connectionManager.updateConnection(id: updated.id, with: updated)
            logger.log(
                level: .info,
                message: "Discovered unmapped live screen-share receiver participant=\(participantId) trackId=\(track.trackId) connection=\(updated.id)"
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: updated.id, participantId: participantId, isActive: true)
            )
            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: updated.id,
                    participantId: participantId,
                    kind: "screen",
                    trackId: track.trackId
                )
            }
            if enableEncryption {
                do {
                    try await createEncryptedFrame(
                        connection: updated,
                        kind: .screenReceiver(transceiver.receiver),
                        participantIdOverride: participantId
                    )
                } catch {
                    logger.log(
                        level: .error,
                        message: "Failed to bind discovered screen receiver FrameCryptor for participant=\(participantId): \(error)"
                    )
                }
            }
            if let refreshed = await connectionManager.findConnection(with: updated.id) {
                updated = refreshed
            }
        }

        if didUpdate {
            await connectionManager.updateConnection(id: updated.id, with: updated)
        }
    }
    #endif

    private func stableRemoteCameraParticipantIds(
        in sdp: String,
        connection: RTCConnection
    ) -> [String] {
        var participantIds: [String] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == "video" else { return }
            let ids = cameraParticipantIds(inVideoSectionLines: currentSectionLines, connection: connection)
            for id in ids where !seen.contains(id) {
                seen.insert(id)
                participantIds.append(id)
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                if line.hasPrefix("m=video") {
                    currentMediaKind = "video"
                } else if line.hasPrefix("m=audio") {
                    currentMediaKind = "audio"
                } else {
                    currentMediaKind = nil
                }
            } else {
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return participantIds
    }

#if canImport(WebRTC) && !os(Android)
    private func appleStableRemoteCameraTrackLabels(
        in sdp: String,
        connection: RTCConnection
    ) -> [(participantId: String, trackId: String?, mid: String?)] {
        var labels: [(participantId: String, trackId: String?, mid: String?)] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentMid: String?
        var currentSectionLines: [String] = []

        func appendLabel(from remainder: String) {
            let parts = remainder
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let streamLabel = parts.first else { return }
            let participantId = normalizedRemoteParticipantIdFromSfuStreamLabel(streamLabel, connection: connection)
                ?? (parts.count > 1
                    ? normalizedRemoteParticipantIdFromSfuStreamLabel(parts[1], connection: connection)
                    : nil)
            guard let participantId else { return }
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            guard !participantKey.isEmpty, seen.insert(participantKey).inserted else { return }
            labels.append((participantId: participantId, trackId: parts.dropFirst().first, mid: currentMid))
        }

        func flushCurrentSection() {
            guard currentMediaKind == "video" else { return }
            guard !currentSectionLines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
                return
            }
            for line in currentSectionLines {
                if line.hasPrefix("a=msid:") {
                    appendLabel(from: String(line.dropFirst("a=msid:".count)))
                } else if let range = line.range(of: " msid:") {
                    appendLabel(from: String(line[range.upperBound...]))
                }
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                currentMediaKind = line.hasPrefix("m=video") ? "video" : nil
                currentMid = nil
            } else {
                if line.hasPrefix("a=mid:") {
                    currentMid = String(line.dropFirst("a=mid:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return labels
    }

    private func appleStableRemoteAudioTrackLabels(
        in sdp: String,
        connection: RTCConnection
    ) -> [(participantId: String, trackId: String?, mid: String?)] {
        var labels: [(participantId: String, trackId: String?, mid: String?)] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentMid: String?
        var currentSectionLines: [String] = []

        func appendLabel(from remainder: String) {
            let parts = remainder
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let streamLabel = parts.first else { return }
            let participantId = normalizedRemoteParticipantIdFromSfuStreamLabel(streamLabel, connection: connection)
                ?? (parts.count > 1
                    ? normalizedRemoteParticipantIdFromSfuStreamLabel(parts[1], connection: connection)
                    : nil)
            guard let participantId else { return }
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            guard !participantKey.isEmpty, seen.insert(participantKey).inserted else { return }
            labels.append((participantId: participantId, trackId: parts.dropFirst().first, mid: currentMid))
        }

        func flushCurrentSection() {
            guard currentMediaKind == "audio" else { return }
            guard !currentSectionLines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
                return
            }
            for line in currentSectionLines {
                if line.hasPrefix("a=msid:") {
                    appendLabel(from: String(line.dropFirst("a=msid:".count)))
                } else if let range = line.range(of: " msid:") {
                    appendLabel(from: String(line[range.upperBound...]))
                }
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                currentMediaKind = line.hasPrefix("m=audio") ? "audio" : nil
                currentMid = nil
            } else {
                if line.hasPrefix("a=mid:") {
                    currentMid = String(line.dropFirst("a=mid:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return labels
    }
#endif

    private func stableRemoteAudioParticipantIds(
        in sdp: String,
        connection: RTCConnection
    ) -> [String] {
        var participantIds: [String] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == "audio" else { return }
            let ids = audioParticipantIds(inAudioSectionLines: currentSectionLines, connection: connection)
            for id in ids where !seen.contains(id) {
                seen.insert(id)
                participantIds.append(id)
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                if line.hasPrefix("m=audio") {
                    currentMediaKind = "audio"
                } else if line.hasPrefix("m=video") {
                    currentMediaKind = "video"
                } else {
                    currentMediaKind = nil
                }
            } else {
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return participantIds
    }

    private func stableRemoteScreenParticipantIds(
        in sdp: String,
        connection: RTCConnection
    ) -> [String] {
        mergeUniqueParticipantIds(
            screenParticipantIds(in: sdp, connection: connection),
            relayStyleScreenParticipantIds(in: sdp, connection: connection)
        )
    }

    private func stableRemoteScreenTrackLabels(
        in sdp: String,
        connection: RTCConnection
    ) -> [(participantId: String, trackId: String?)] {
        var labels: [(participantId: String, trackId: String?)] = []
        var seen = Set<String>()

        func append(_ participantId: String, trackId: String?) {
            guard !seen.contains(participantId) else { return }
            seen.insert(participantId)
            labels.append((participantId, trackId))
        }

        for participantId in screenParticipantIds(in: sdp, connection: connection) {
            append(participantId, trackId: nil)
        }
        for share in relayStyleScreenShareAdvertisements(in: sdp, connection: connection) {
            append(share.participantId, trackId: share.trackId)
        }
        if labels.isEmpty,
           connection.localScreenTrack == nil,
           connection.remoteScreenShareStopRequestedParticipantKeys.isEmpty,
           !Self.oneToOneSfuIncomingScreenShareVideoMids(in: sdp).isEmpty,
           let participantId = oneToOneSfuRemoteScreenParticipantId(in: connection),
           Self.isPlausibleConferenceScreenShareParticipantId(participantId) {
            append(participantId, trackId: nil)
        }
        if labels.isEmpty,
           connection.localScreenTrack == nil,
           connection.remoteScreenShareStopRequestedParticipantKeys.isEmpty,
           !activeIncomingScreenShareVideoMids(in: sdp, connection: connection).isEmpty,
           let relayParticipant = ambiguousRelayScreenParticipantId(in: connection),
           Self.isPlausibleConferenceScreenShareParticipantId(relayParticipant) {
            let relayKey = Self.conferenceParticipantIdentityKey(relayParticipant)
            if !connection.remoteScreenShareStopRequestedParticipantKeys.contains(relayKey) {
#if os(Android)
                let hasLiveScreenReceiver = rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection) != nil
#elseif canImport(WebRTC)
                let hasLiveScreenReceiver = !liveScreenReceiverCandidates(in: connection).isEmpty
#else
                let hasLiveScreenReceiver = false
#endif
                if hasLiveScreenReceiver {
                    append(relayParticipant, trackId: nil)
                }
            }
        }
        return labels
    }

    func isRemoteScreenShareExplicitlyAdvertisedInSDP(
        participantId: String,
        remoteSdp: String,
        connection: RTCConnection
    ) -> Bool {
        remoteScreenShareExplicitlyAdvertised(
            participantId: participantId,
            in: remoteSdp,
            connection: connection
        )
    }

    func isRemoteScreenShareExplicitlyStoppedInSDP(
        participantId: String,
        remoteSdp: String,
        connection: RTCConnection,
        screenIngressCeased: Bool = false
    ) -> Bool {
        ScreenShareGroupCallSDPPolicy.shouldTreatRemoteSharerAsStoppedAfterPreempt(
            participantId: participantId,
            stopWasRequested: true,
            explicitInactiveParticipantIds: inactiveRemoteScreenParticipantIds(
                in: remoteSdp,
                connection: connection
            ),
            screenIngressCeased: screenIngressCeased
        )
    }

    private func remoteScreenShareExplicitlyAdvertised(
        participantId: String,
        in sdp: String,
        connection: RTCConnection
    ) -> Bool {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }
        let explicit = screenParticipantIds(in: sdp, connection: connection)
        if explicit.contains(where: { Self.conferenceParticipantIdentityKey($0) == participantKey }) {
            return true
        }
        return relayStyleScreenShareAdvertisements(in: sdp, connection: connection).contains {
            Self.conferenceParticipantIdentityKey($0.participantId) == participantKey
        }
    }

    private func shouldForceRemoveRemoteScreenShareAfterStopRequest(
        participantId: String,
        in connection: RTCConnection,
        remoteSdp: String,
        connectionId: String
    ) async -> Bool {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty,
              connection.remoteScreenShareStopRequestedParticipantKeys.contains(participantKey)
        else { return false }

        let ingressCeased = await remoteScreenIngressCeasedIndicatingStop(
            connectionId: connectionId,
            participantKey: participantKey
        )
        let explicitScreenAdvertisement = screenParticipantIds(in: remoteSdp, connection: connection).contains {
            Self.conferenceParticipantIdentityKey($0) == participantKey
        }
        let flatObservationKey = remoteScreenIngressFlatObservationKey(
            connectionId: connectionId,
            participantKey: participantKey
        )
#if canImport(WebRTC)
        let sustainedFlatObservation = remoteScreenIngressFlatSinceByKey[flatObservationKey].map {
            Date().timeIntervalSince($0) >= ScreenShareGroupCallContract.preemptWaitIngressCeasedMinimumFlatSeconds
        } ?? false
#else
        let sustainedFlatObservation = false
#endif
        let effectiveIngressCeased = ingressCeased || (!explicitScreenAdvertisement && sustainedFlatObservation)
        return isRemoteScreenShareExplicitlyStoppedInSDP(
            participantId: participantId,
            remoteSdp: remoteSdp,
            connection: connection,
            screenIngressCeased: effectiveIngressCeased
        )
    }

    private func shouldSkipRemoteScreenShareMapping(
        participantId: String,
        connection: RTCConnection,
        remoteSdp: String
    ) -> Bool {
        if connection.localScreenTrack != nil {
            return true
        }
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }
        if connection.remoteScreenShareStopRequestedParticipantKeys.contains(participantKey) {
            return true
        }
        if connection.suppressedRemoteScreenShareParticipantIds.contains(participantKey) {
            return !remoteScreenShareExplicitlyAdvertised(
                participantId: participantId,
                in: remoteSdp,
                connection: connection
            )
        }
        return false
    }

    /// True when the remote SDP still forwards camera for `participantId` but no longer forwards
    /// active screen-share media (SFU stop-forward often uses `recvonly` on mid=2 without `screen_` msid).
    private func isRemoteScreenShareStopForwardedInSdp(
        participantId: String,
        remoteSdp: String,
        connection: RTCConnection
    ) -> Bool {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }

        let hasActiveCamera = stableRemoteCameraParticipantIds(in: remoteSdp, connection: connection)
            .contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        guard hasActiveCamera else { return false }

        let stillAdvertised = stableRemoteScreenTrackLabels(in: remoteSdp, connection: connection)
            .contains { Self.conferenceParticipantIdentityKey($0.participantId) == participantKey }
        guard !stillAdvertised else { return false }

        return activeIncomingScreenShareVideoMids(in: remoteSdp, connection: connection).isEmpty
    }

    private func inactiveRemoteScreenParticipantIds(
        in sdp: String,
        connection: RTCConnection
    ) -> [String] {
        var participantIds: [String] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == "video",
                  currentSectionLines.contains(where: { $0 == "a=inactive" })
            else { return }
            let ids = screenParticipantIdsIgnoringDirection(
                inVideoSectionLines: currentSectionLines,
                connection: connection
            )
            for id in ids where !seen.contains(id) {
                seen.insert(id)
                participantIds.append(id)
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                currentMediaKind = line.hasPrefix("m=video") ? "video" : nil
            } else {
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        for participantId in stableRemoteCameraParticipantIds(in: sdp, connection: connection) where !seen.contains(participantId) {
            if isRemoteScreenShareStopForwardedInSdp(
                participantId: participantId,
                remoteSdp: sdp,
                connection: connection
            ) {
                seen.insert(participantId)
                participantIds.append(participantId)
            }
        }

        return participantIds
    }

    private func screenParticipantIds(
        in sdp: String,
        connection: RTCConnection
    ) -> [String] {
        var participantIds: [String] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == "video" else { return }
            let ids = screenParticipantIds(inVideoSectionLines: currentSectionLines, connection: connection)
            for id in ids where !seen.contains(id) {
                seen.insert(id)
                participantIds.append(id)
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                if line.hasPrefix("m=video") {
                    currentMediaKind = "video"
                } else if line.hasPrefix("m=audio") {
                    currentMediaKind = "audio"
                } else {
                    currentMediaKind = nil
                }
            } else {
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return participantIds
    }

    private func relayStyleScreenShareAdvertisements(
        in sdp: String,
        connection: RTCConnection
    ) -> [RTCSession.AdvertisedRemoteScreenShare] {
        RTCSession.advertisedRelayStyleRemoteScreenShares(
            in: sdp,
            localParticipantId: connection.localParticipantId
        ) { rawLabel in
            normalizedRemoteParticipantIdFromSfuStreamLabel(rawLabel, connection: connection)
        }
    }

    private func relayStyleScreenParticipantIds(
        in sdp: String,
        connection: RTCConnection
    ) -> [String] {
        relayStyleScreenShareAdvertisements(in: sdp, connection: connection).map(\.participantId)
    }

    private func mergeUniqueParticipantIds(_ first: [String], _ second: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        for id in first + second where !seen.contains(id) {
            seen.insert(id)
            merged.append(id)
        }
        return merged
    }

    private func cameraParticipantIds(
        inVideoSectionLines lines: [String],
        connection: RTCConnection
    ) -> [String] {
        guard !lines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
            return []
        }

        var ids: [String] = []
        var seen = Set<String>()

        func appendStreamLabel(_ rawLabel: String) {
            guard let participantId = normalizedRemoteParticipantIdFromSfuStreamLabel(rawLabel, connection: connection) else { return }
            guard !seen.contains(participantId) else { return }
            seen.insert(participantId)
            ids.append(participantId)
        }

        for line in lines {
            if line.hasPrefix("a=msid:") {
                let remainder = String(line.dropFirst("a=msid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let streamLabel = parts.first {
                    let before = ids.count
                    appendStreamLabel(streamLabel)
                    if ids.count == before, parts.count > 1 {
                        appendStreamLabel(parts[1])
                    }
                }
            } else if let range = line.range(of: " msid:") {
                let remainder = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let streamLabel = parts.first {
                    let before = ids.count
                    appendStreamLabel(streamLabel)
                    if ids.count == before, parts.count > 1 {
                        appendStreamLabel(parts[1])
                    }
                }
            }
        }

        return ids
    }

    private func audioParticipantIds(
        inAudioSectionLines lines: [String],
        connection: RTCConnection
    ) -> [String] {
        guard !lines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
            return []
        }

        var ids: [String] = []
        var seen = Set<String>()

        func appendStreamLabel(_ rawLabel: String) {
            guard let participantId = normalizedRemoteParticipantIdFromSfuStreamLabel(rawLabel, connection: connection) else { return }
            guard !seen.contains(participantId) else { return }
            seen.insert(participantId)
            ids.append(participantId)
        }

        for line in lines {
            if line.hasPrefix("a=msid:") {
                let remainder = String(line.dropFirst("a=msid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let streamLabel = parts.first {
                    let before = ids.count
                    appendStreamLabel(streamLabel)
                    if ids.count == before, parts.count > 1 {
                        appendStreamLabel(parts[1])
                    }
                }
            } else if let range = line.range(of: " msid:") {
                let remainder = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let streamLabel = parts.first {
                    let before = ids.count
                    appendStreamLabel(streamLabel)
                    if ids.count == before, parts.count > 1 {
                        appendStreamLabel(parts[1])
                    }
                }
            }
        }

        return ids
    }

    private func screenParticipantIds(
        inVideoSectionLines lines: [String],
        connection: RTCConnection
    ) -> [String] {
        guard !lines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
            return []
        }
        return screenParticipantIdsIgnoringDirection(inVideoSectionLines: lines, connection: connection)
    }

    private func screenParticipantIdsIgnoringDirection(
        inVideoSectionLines lines: [String],
        connection: RTCConnection
    ) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()

        func appendScreenLabel(_ rawLabel: String) {
            guard let participantId = normalizedRemoteScreenParticipantIdFromSfuLabel(rawLabel, connection: connection) else { return }
            guard !seen.contains(participantId) else { return }
            seen.insert(participantId)
            ids.append(participantId)
        }

        func appendScreenLabels(from remainder: String) {
            let parts = remainder
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let streamLabel = parts.first else { return }
            let before = ids.count
            appendScreenLabel(streamLabel)
            if ids.count == before, parts.count > 1 {
                appendScreenLabel(parts[1])
            }
        }

        for line in lines {
            if line.hasPrefix("a=msid:") {
                let remainder = String(line.dropFirst("a=msid:".count))
                appendScreenLabels(from: remainder)
            } else if let range = line.range(of: " msid:") {
                let remainder = String(line[range.upperBound...])
                appendScreenLabels(from: remainder)
            }
        }

        return ids
    }

    private func normalizedRemoteParticipantIdFromSfuStreamLabel(
        _ rawLabel: String,
        connection: RTCConnection
    ) -> String? {
        Self.normalizedRemoteParticipantIdFromSfuMediaLabel(
            rawLabel,
            connectionId: connection.id,
            localParticipantId: connection.localParticipantId
        )
    }

    #if canImport(WebRTC) && !os(Android)
    private func appleSfuReceiverTrackMatchesProvisionedParticipant(
        receiver: RTCRtpReceiver,
        track: RTCVideoTrack,
        provisioned: String,
        connection: RTCConnection
    ) -> Bool {
        _ = receiver
        let provisionedKey = Self.conferenceParticipantIdentityKey(provisioned)
        guard !provisionedKey.isEmpty else { return false }

        guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp else { return false }

        let owners = Self.advertisedRemoteCameraOwnersByTrackId(in: remoteSdp)
        if let owner = owners[track.trackId],
           Self.conferenceParticipantIdentityKey(owner) == provisionedKey {
            return true
        }

        let advertised = advertisedSfuRemoteMediaTrackIds(
            mediaKind: "video",
            participantId: provisioned,
            connection: connection
        )
        if !advertised.isEmpty {
            return advertised.contains(track.trackId)
        }

        let cameraLabels = appleStableRemoteCameraTrackLabels(in: remoteSdp, connection: connection)
        if let label = cameraLabels.first(where: {
            $0.trackId?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == track.trackId
        }) {
            return Self.conferenceParticipantIdentityKey(label.participantId) == provisionedKey
        }

        let trackId = track.trackId
        guard let transceiver = connection.peerConnection.transceivers.first(where: {
            $0.receiver.track?.trackId == trackId
        }) else {
            return false
        }
        let mid = transceiver.mid.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !mid.isEmpty else { return false }
        return cameraLabels.contains {
            Self.conferenceParticipantIdentityKey($0.participantId) == provisionedKey
                && $0.mid?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == mid
        }
    }
    #endif

    private func normalizedRemoteScreenParticipantIdFromSfuLabel(
        _ rawLabel: String,
        connection: RTCConnection
    ) -> String? {
        let id = normalizedKnownRemoteScreenParticipantId(rawLabel, connection: connection)
        guard rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(RTCSession.screenTrackPrefix) ||
                rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("streamId_\(RTCSession.screenTrackPrefix)")
        else { return nil }
        return id
    }

    private func normalizedKnownRemoteScreenParticipantId(
        _ rawLabel: String,
        connection: RTCConnection
    ) -> String? {
        var id = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if id.hasPrefix("streamId_") {
            id = String(id.dropFirst("streamId_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let participant = RTCSession.participantIdFromScreenShareId(id) {
            id = participant.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let connectionSuffixes = [
            "_\(connection.id)",
            "_\(connection.id.normalizedConnectionId)",
            "_\(connection.id.ensureIRCChannel)"
        ]
        for suffix in connectionSuffixes where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if id.hasSuffix("_") {
            id = String(id.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !id.isEmpty else { return nil }
        guard UUID(uuidString: id) == nil else { return nil }

        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty, id.caseInsensitiveCompare(local) == .orderedSame {
            return nil
        }

        return id
    }

    #if canImport(WebRTC) && !os(Android)
    private func resolvedAppleRemoteScreenParticipantId(
        streamIds: [String],
        trackId: String,
        fallback: String,
        connection: RTCConnection
    ) -> String {
        for label in streamIds + [trackId] {
            if let participantId = normalizedRemoteScreenParticipantIdFromSfuLabel(label, connection: connection) {
                return participantId
            }
        }

        let resolved = RTCSession.resolvedScreenShareParticipantId(
            streamIds: streamIds,
            trackId: trackId,
            fallback: fallback
        )
        if Self.isTrueOneToOneSfuRoom(call: connection.call),
           UUID(uuidString: resolved.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
           let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !owner.isEmpty {
            return owner
        }
        if let known = normalizedKnownRemoteScreenParticipantId(resolved, connection: connection) {
            return known
        }
        if let relay = resolvedAppleRelayScreenShareParticipantId(
            streamIds: streamIds,
            trackId: trackId,
            connection: connection
        ) {
            return relay
        }
        return ""
    }
    #endif

#if os(Android)
    private func androidNormalizedRemoteParticipantIdFromSfuStreamLabel(
        _ rawLabel: String,
        connection: RTCConnection
    ) -> String? {
        Self.normalizedRemoteParticipantIdFromSfuMediaLabel(
            rawLabel,
            connectionId: connection.id,
            localParticipantId: connection.localParticipantId
        )
    }

    private func stableRemoteCameraTrackLabels(
        in sdp: String,
        connection: RTCConnection
    ) -> [(participantId: String, trackId: String?, mid: String?)] {
        var labels: [(participantId: String, trackId: String?, mid: String?)] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentMid: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == "video" else { return }
            guard !currentSectionLines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
                return
            }

            for line in currentSectionLines {
                let remainder: String
                if line.hasPrefix("a=msid:") {
                    remainder = String(line.dropFirst("a=msid:".count))
                } else if let range = line.range(of: " msid:") {
                    remainder = String(line[range.upperBound...])
                } else {
                    continue
                }

                let parts = remainder
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                guard let streamLabel = parts.first else {
                    continue
                }
                let participantId = androidNormalizedRemoteParticipantIdFromSfuStreamLabel(streamLabel, connection: connection)
                    ?? (parts.count > 1
                        ? androidNormalizedRemoteParticipantIdFromSfuStreamLabel(parts[1], connection: connection)
                        : nil)
                guard let participantId else { continue }
                guard seen.insert(participantId.lowercased()).inserted else { continue }
                labels.append((participantId: participantId, trackId: parts.dropFirst().first, mid: currentMid))
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                currentMediaKind = line.hasPrefix("m=video") ? "video" : nil
                currentMid = nil
            } else {
                if line.hasPrefix("a=mid:") {
                    currentMid = String(line.dropFirst("a=mid:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return labels
    }

    private func stableRemoteAudioTrackLabels(
        in sdp: String,
        connection: RTCConnection
    ) -> [(participantId: String, trackId: String?, mid: String?)] {
        var labels: [(participantId: String, trackId: String?, mid: String?)] = []
        var seen = Set<String>()
        var currentMediaKind: String?
        var currentMid: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == "audio" else { return }
            guard !currentSectionLines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
                return
            }

            for line in currentSectionLines {
                let remainder: String
                if line.hasPrefix("a=msid:") {
                    remainder = String(line.dropFirst("a=msid:".count))
                } else if let range = line.range(of: " msid:") {
                    remainder = String(line[range.upperBound...])
                } else {
                    continue
                }

                let parts = remainder
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                guard let streamLabel = parts.first else {
                    continue
                }
                let participantId = androidNormalizedRemoteParticipantIdFromSfuStreamLabel(streamLabel, connection: connection)
                    ?? (parts.count > 1
                        ? androidNormalizedRemoteParticipantIdFromSfuStreamLabel(parts[1], connection: connection)
                        : nil)
                guard let participantId else { continue }
                let participantKey = Self.conferenceParticipantIdentityKey(participantId)
                guard !participantKey.isEmpty, seen.insert(participantKey).inserted else { continue }
                labels.append((participantId: participantId, trackId: parts.dropFirst().first, mid: currentMid))
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                currentMediaKind = line.hasPrefix("m=audio") ? "audio" : nil
                currentMid = nil
            } else {
                if line.hasPrefix("a=mid:") {
                    currentMid = String(line.dropFirst("a=mid:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return labels
    }

    func androidResolvedRemoteCameraTrackId(
        participantId: String,
        in connection: RTCConnection
    ) -> String? {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        if let exact = connection.androidRemoteCameraResolvedTrackIdsByParticipantId[participantId] {
            return exact
        }
        return connection.androidRemoteCameraResolvedTrackIdsByParticipantId.first { key, _ in
            Self.conferenceParticipantIdentityKey(key) == participantKey
        }?.value
    }

    func androidResolvedRemoteCameraMid(
        participantId: String,
        in connection: RTCConnection
    ) -> String? {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        if let exact = connection.androidRemoteCameraResolvedMidsByParticipantId[participantId] {
            return exact
        }
        return connection.androidRemoteCameraResolvedMidsByParticipantId.first { key, _ in
            Self.conferenceParticipantIdentityKey(key) == participantKey
        }?.value
    }

    func androidRemoteVideoTracksShareNativeSource(_ lhs: RTCVideoTrack, _ rhs: RTCVideoTrack) -> Bool {
        AndroidRemoteVideoTrackAttachPolicy.tracksShareEffectiveNativeSource(
            lhsTrackId: lhs.trackIdIfAvailable,
            rhsTrackId: rhs.trackIdIfAvailable,
            lhsIsLive: lhs.isLiveVideoTrack,
            rhsIsLive: rhs.isLiveVideoTrack,
            platformTracksIdentical: lhs.platformTrack === rhs.platformTrack
        )
    }

    func androidResolveLiveRemoteCameraTrackFromAdvertisedMedia(
        advertisedTrackId: String?,
        advertisedMid: String?,
        connection: RTCConnection
    ) -> RTCVideoTrack? {
        if let advertisedMid = advertisedMid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !advertisedMid.isEmpty,
           let midTrack = rtcClient.getRemoteVideoTrackByMid(
            peerConnection: connection.peerConnection,
            mid: advertisedMid
           ),
           midTrack.isLiveVideoTrack {
            return midTrack
        }
        if let advertisedTrackId = advertisedTrackId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !advertisedTrackId.isEmpty {
            let exactTrack = rtcClient.getRemoteVideoTrackById(
                peerConnection: connection.peerConnection,
                trackId: advertisedTrackId
            )
            if let exactTrack,
               exactTrack.trackIdIfAvailable != nil,
               exactTrack.isLiveVideoTrack {
                return exactTrack
            }
            return nil
        }
        return nil
    }

    func androidResolveLiveRemoteCameraTrack(
        participantId: String,
        connection: inout RTCConnection,
        remoteSdp: String? = nil,
        preferFreshFromPeerConnection: Bool = false
    ) -> RTCVideoTrack? {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return nil }

        if let remoteSdp = remoteSdp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteSdp.isEmpty {
            let labels = stableRemoteCameraTrackLabels(in: remoteSdp, connection: connection)
            if let label = labels.first(where: { Self.conferenceParticipantIdentityKey($0.participantId) == participantKey }),
               let liveTrack = androidResolveLiveRemoteCameraTrackFromAdvertisedMedia(
                advertisedTrackId: label.trackId,
                advertisedMid: label.mid,
                connection: connection
               ),
               liveTrack.isLiveVideoTrack {
                let resolvedTrackId = liveTrack.trackIdIfAvailable ?? label.trackId
                if let resolvedTrackId, !resolvedTrackId.isEmpty {
                    rememberAndroidResolvedRemoteCameraMedia(
                        participantId: label.participantId,
                        trackId: resolvedTrackId,
                        mid: label.mid,
                        in: &connection
                    )
                }
                return liveTrack
            }
        }

        if let storedTrackId = androidResolvedRemoteCameraTrackId(participantId: participantId, in: connection),
           let exactTrack = rtcClient.getRemoteVideoTrackById(
            peerConnection: connection.peerConnection,
            trackId: storedTrackId
           ),
           exactTrack.isLiveVideoTrack {
            return exactTrack
        }

        if let storedMid = androidResolvedRemoteCameraMid(participantId: participantId, in: connection),
           let midTrack = rtcClient.getRemoteVideoTrackByMid(
            peerConnection: connection.peerConnection,
            mid: storedMid
           ),
           midTrack.isLiveVideoTrack {
            return midTrack
        }

        return nil
    }

    func rememberAndroidResolvedRemoteCameraMedia(
        participantId: String,
        trackId: String,
        mid: String?,
        in connection: inout RTCConnection
    ) {
        connection.androidRemoteCameraResolvedTrackIdsByParticipantId[participantId] = trackId
        if let mid = mid?.trimmingCharacters(in: .whitespacesAndNewlines), !mid.isEmpty {
            connection.androidRemoteCameraResolvedMidsByParticipantId[participantId] = mid
        }
    }

    func clearAndroidResolvedRemoteCameraMedia(
        participantId: String,
        in connection: inout RTCConnection
    ) {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        for key in connection.androidRemoteCameraResolvedTrackIdsByParticipantId.keys
        where key == participantId || Self.conferenceParticipantIdentityKey(key) == participantKey {
            connection.androidRemoteCameraResolvedTrackIdsByParticipantId.removeValue(forKey: key)
        }
        for key in connection.androidRemoteCameraResolvedMidsByParticipantId.keys
        where key == participantId || Self.conferenceParticipantIdentityKey(key) == participantKey {
            connection.androidRemoteCameraResolvedMidsByParticipantId.removeValue(forKey: key)
        }
    }

    func installAndroidGroupReceiverVideoCryptorIfReady(
        participantId: String,
        connection: RTCConnection,
        trackId: String
    ) {
        guard enableEncryption else { return }
        let normId = connection.id.normalizedConnectionId
        guard !sfuRenegotiationInFlightConnectionIds.contains(normId) else { return }
        rtcClient.createReceiverEncryptedFrame(
            participant: participantId,
            connectionId: connection.id,
            trackKind: "video",
            trackId: trackId
        )
    }

    func reconcileAndroidReceiverFrameCryptorsAfterSfuRenegotiation(connectionId: String) async {
        guard enableEncryption else { return }
        guard let connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        for (participantId, track) in connection.remoteVideoTracksByParticipantId {
            let trackId = track.trackIdIfAvailable
                ?? androidResolvedRemoteCameraTrackId(participantId: participantId, in: connection)
            guard let trackId, !trackId.isEmpty else { continue }
            rtcClient.createReceiverEncryptedFrame(
                participant: participantId,
                connectionId: connection.id,
                trackKind: "video",
                trackId: trackId
            )
        }

        for (participantId, track) in connection.remoteAudioTracksByParticipantId {
            guard let trackId = track.trackIdIfAvailable, !trackId.isEmpty else { continue }
            rtcClient.createReceiverEncryptedFrame(
                participant: participantId,
                connectionId: connection.id,
                trackKind: "audio",
                trackId: trackId
            )
        }

        for (participantId, track) in connection.remoteScreenTracksByParticipantId {
            guard let trackId = track.trackIdIfAvailable, !trackId.isEmpty else { continue }
            rtcClient.createReceiverEncryptedFrame(
                participant: participantId,
                connectionId: connection.id,
                trackKind: "screen",
                trackId: trackId
            )
        }
    }

    func reconcileAndroidRemoteParticipantCameraTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        let labels = stableRemoteCameraTrackLabels(in: remoteSdp, connection: connection)
        guard !labels.isEmpty else { return }

        for label in labels {
            guard shouldSurfaceRemoteParticipantCameraTrack(connection: connection, participantId: label.participantId) else {
                continue
            }
            let videoTrack: RTCVideoTrack?
            let resolutionSource: String
            let advertisedTrackId = label.trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let advertisedMid = label.mid?.trimmingCharacters(in: .whitespacesAndNewlines)
            if advertisedTrackId != nil || advertisedMid != nil {
                videoTrack = androidResolveLiveRemoteCameraTrackFromAdvertisedMedia(
                    advertisedTrackId: advertisedTrackId,
                    advertisedMid: advertisedMid,
                    connection: connection
                )
                if videoTrack?.trackIdIfAvailable != nil,
                   advertisedTrackId != nil,
                   !advertisedTrackId!.isEmpty {
                    resolutionSource = "trackId"
                } else if videoTrack != nil, advertisedMid != nil, !advertisedMid!.isEmpty {
                    resolutionSource = advertisedTrackId?.isEmpty == false ? "midAfterTrackIdMiss" : "mid"
                } else {
                    resolutionSource = "unresolved"
                }
            } else {
                videoTrack = nil
                resolutionSource = "unresolved"
            }
            logger.log(
                level: videoTrack?.trackIdIfAvailable == nil ? .warning : .info,
                message: "Android SFU camera label resolution participant=\(label.participantId) advertisedTrackId=\(advertisedTrackId ?? "<nil>") advertisedMid=\(advertisedMid ?? "<nil>") resolution=\(resolutionSource) resolvedTrackId=\(videoTrack?.trackIdIfAvailable ?? "<nil>") connection=\(connection.id)"
            )
            guard let videoTrack,
                  let videoTrackId = videoTrack.trackIdIfAvailable else {
                logger.log(
                    level: .warning,
                    message: "SFU SDP advertised Android camera msid for participant=\(label.participantId) but no live video receiver exists for connection=\(connection.id)"
                )
                continue
            }

            if let existing = connection.remoteVideoTracksByParticipantId[label.participantId] {
                let existingTrackId = existing.trackIdIfAvailable
                if existing.platformTrack === videoTrack.platformTrack, existingTrackId != nil {
                    rememberAndroidResolvedRemoteCameraMedia(
                        participantId: label.participantId,
                        trackId: videoTrackId,
                        mid: advertisedMid,
                        in: &connection
                    )
                    installAndroidGroupReceiverVideoCryptorIfReady(
                        participantId: label.participantId,
                        connection: connection,
                        trackId: videoTrackId
                    )
                    continue
                }
                if existingTrackId == videoTrackId {
                    logger.log(
                        level: .info,
                        message: "Replacing stale Android SFU camera wrapper participant=\(label.participantId) trackId=\(videoTrackId) connection=\(connection.id)"
                    )
                }
            }

            let placeholderParticipants = connection.remoteVideoTracksByParticipantId.compactMap { participantId, existingTrack -> String? in
                guard participantId != label.participantId else { return nil }
                let participantKey = participantId.normalizedConnectionId.lowercased()
                let isPlaceholder = UUID(uuidString: participantId.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
                    || participantKey == connection.id.normalizedConnectionId.lowercased()
                    || participantKey == connection.remoteParticipantId.normalizedConnectionId.lowercased()
                guard isPlaceholder else { return nil }
                guard let existingTrackId = existingTrack.trackIdIfAvailable else { return participantId }
                guard existingTrackId == videoTrackId else { return nil }
                return participantId
            }

            for participantId in placeholderParticipants {
                connection.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
                notifyRemoteParticipantTrackChanged(
                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
                )
                logger.log(
                    level: .info,
                    message: "Removed Android SFU placeholder camera participant=\(participantId) after resolving stable participant=\(label.participantId)"
                )
            }

            let claimSucceeded = Self.claimRemoteCameraTrack(
                videoTrack,
                participantId: label.participantId,
                in: &connection
            )
            guard claimSucceeded else {
                await connectionManager.updateConnection(id: connection.id, with: connection)
                logger.log(
                    level: .warning,
                    message: "Rejected duplicate Android SFU camera receiver claim participant=\(label.participantId) trackId=\(videoTrackId) connection=\(connection.id)"
                )
                continue
            }
            rememberAndroidResolvedRemoteCameraMedia(
                participantId: label.participantId,
                trackId: videoTrackId,
                mid: advertisedMid,
                in: &connection
            )
            if connection.remoteVideoTracksByParticipantId.count == 1 {
                connection.remoteVideoTrack = videoTrack
            }
            await connectionManager.updateConnection(id: connection.id, with: connection)

            logger.log(
                level: .info,
                message: "Mapped Android SFU camera receiver to participant=\(label.participantId) trackId=\(videoTrackId) connection=\(connection.id)"
            )
            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(connectionId: connection.id, participantId: label.participantId, kind: "video", isActive: true)
            )
            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: connection.id,
                    participantId: label.participantId,
                    kind: "video",
                    trackId: videoTrackId
                )
            }
            if enableEncryption {
                installAndroidGroupReceiverVideoCryptorIfReady(
                    participantId: label.participantId,
                    connection: connection,
                    trackId: videoTrackId
                )
            }
        }
    }

    func reconcileAndroidRemoteParticipantAudioTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        let labels = stableRemoteAudioTrackLabels(in: remoteSdp, connection: connection)
        guard !labels.isEmpty else { return }

        for label in labels {
            let audioTrack: RTCAudioTrack?
            if let advertisedTrackId = label.trackId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !advertisedTrackId.isEmpty {
                let exactTrack = rtcClient.getRemoteAudioTrackById(
                    peerConnection: connection.peerConnection,
                    trackId: advertisedTrackId
                )
                if let exactTrack, exactTrack.trackIdIfAvailable != nil {
                    audioTrack = exactTrack
                } else if let advertisedMid = label.mid?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !advertisedMid.isEmpty {
                    audioTrack = rtcClient.getRemoteAudioTrackByMid(
                        peerConnection: connection.peerConnection,
                        mid: advertisedMid
                    )
                } else {
                    audioTrack = nil
                }
            } else if let advertisedMid = label.mid?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !advertisedMid.isEmpty {
                audioTrack = rtcClient.getRemoteAudioTrackByMid(
                    peerConnection: connection.peerConnection,
                    mid: advertisedMid
                )
            } else {
                audioTrack = nil
            }

            guard let audioTrack,
                  let audioTrackId = audioTrack.trackIdIfAvailable else {
                logger.log(
                    level: .warning,
                    message: "SFU SDP advertised Android audio msid for participant=\(label.participantId) but no live audio receiver exists for connection=\(connection.id)"
                )
                continue
            }

            audioTrack._isEnabled = false
            if let existing = connection.remoteAudioTracksByParticipantId[label.participantId] {
                let existingTrackId = existing.trackIdIfAvailable
                if existing === audioTrack, existingTrackId != nil {
                    if enableEncryption {
                        rtcClient.createReceiverEncryptedFrame(
                            participant: label.participantId,
                            connectionId: connection.id,
                            trackKind: "audio",
                            trackId: audioTrackId
                        )
                    } else {
                        audioTrack._isEnabled = true
                    }
                    continue
                }
                if existingTrackId == audioTrackId {
                    logger.log(
                        level: .info,
                        message: "Replacing stale Android SFU audio wrapper participant=\(label.participantId) trackId=\(audioTrackId) connection=\(connection.id)"
                    )
                }
            }

            connection.remoteAudioTracksByParticipantId[label.participantId] = audioTrack
            await connectionManager.updateConnection(id: connection.id, with: connection)

            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: connection.id,
                    participantId: label.participantId,
                    kind: "audio",
                    trackId: audioTrackId
                )
            }
            if enableEncryption {
                rtcClient.createReceiverEncryptedFrame(
                    participant: label.participantId,
                    connectionId: connection.id,
                    trackKind: "audio",
                    trackId: audioTrackId
                )
            }
            logger.log(
                level: .info,
                message: "Mapped Android SFU audio receiver to participant=\(label.participantId) trackId=\(audioTrackId) connection=\(connection.id)"
            )
        }
    }

    func reconcileAndroidRemoteScreenTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        let advertisedLabels = androidStableRemoteScreenTrackLabels(in: remoteSdp, connection: connection)
        let advertisedParticipants = Set(advertisedLabels.map(\.participantId))
        let explicitlyInactiveParticipants = Set(inactiveRemoteScreenParticipantIds(in: remoteSdp, connection: connection))

        func isStillAdvertised(_ participantId: String) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            return advertisedParticipants.contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        }

        func isExplicitlyInactive(_ participantId: String) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            return explicitlyInactiveParticipants.contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        }

        func existingScreenTrack(for participantId: String, in connection: RTCConnection) -> RTCVideoTrack? {
            if let exact = connection.remoteScreenTracksByParticipantId[participantId] {
                return exact
            }
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            guard !participantKey.isEmpty else { return nil }
            return connection.remoteScreenTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key) == participantKey
            }?.value
        }

        func androidHasLiveScreenReceiver(for participantId: String, in connection: RTCConnection) -> Bool {
            guard existingScreenTrack(for: participantId, in: connection) != nil else { return false }
            let cameraTrackId = connection.remoteVideoTracksByParticipantId[participantId]?.trackId
            guard let screenTrack = rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection) else {
                return false
            }
            if RTCSession.isScreenShareId(screenTrack.trackId) { return true }
            guard let cameraTrackId else { return false }
            return screenTrack.trackId != cameraTrackId
        }

        var removedScreenParticipants = Set<String>()
        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) {
            let shouldReconcileRemoval = !isStillAdvertised(participantId) || isExplicitlyInactive(participantId)
            guard shouldReconcileRemoval else { continue }

            let stopForwarded = isRemoteScreenShareStopForwardedInSdp(
                participantId: participantId,
                remoteSdp: remoteSdp,
                connection: connection
            )
            if !isExplicitlyInactive(participantId),
               !stopForwarded,
               androidHasLiveScreenReceiver(for: participantId, in: connection) {
                logger.log(
                    level: .info,
                    message: "Keeping live Android remote screen-share receiver during SDP reconcile participant=\(participantId) connection=\(connection.id)"
                )
                continue
            }

            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            let staleScreenKeys = connection.remoteScreenTracksByParticipantId.keys.filter {
                Self.conferenceParticipantIdentityKey($0) == participantKey
            }
            for staleKey in staleScreenKeys {
                connection.remoteScreenTracksByParticipantId.removeValue(forKey: staleKey)
            }
            connection.remoteScreenTrack = nil
            if !participantKey.isEmpty {
                connection.suppressedRemoteScreenShareParticipantIds.insert(participantKey)
                connection.remoteScreenShareStopRequestedParticipantKeys.remove(participantKey)
                clearRemoteScreenIngressFlatObservation(
                    connectionId: connection.id,
                    participantKey: participantKey
                )
            }
            removedScreenParticipants.insert(participantId)
            await connectionManager.updateConnection(id: connection.id, with: connection)
            logger.log(
                level: .info,
                message: "Removed stale Android remote screen-share track after SDP reconcile participant=\(participantId) connection=\(connection.id)"
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
            )
        }

        guard !advertisedLabels.isEmpty else { return }

        var consumedTrackIds = Set(connection.remoteScreenTracksByParticipantId.values.map(\.trackId))

        for label in advertisedLabels {
            let participantId = label.participantId
            let advertisedParticipantKey = Self.conferenceParticipantIdentityKey(participantId)
            if !advertisedParticipantKey.isEmpty,
               removedScreenParticipants.contains(where: {
                   Self.conferenceParticipantIdentityKey($0) == advertisedParticipantKey
               }) {
                continue
            }
            if shouldSkipRemoteScreenShareMapping(
                participantId: participantId,
                connection: connection,
                remoteSdp: remoteSdp
            ) {
                continue
            }
            if let existing = existingScreenTrack(for: participantId, in: connection) {
                consumedTrackIds.insert(existing.trackId)
                notifyRemoteScreenTrackChanged(
                    RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: true)
                )
                continue
            }

            let screenTrack = label.trackId.flatMap {
                rtcClient.getRemoteScreenVideoTrackById(peerConnection: connection.peerConnection, trackId: $0)
            } ?? rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection)
            guard let screenTrack, !consumedTrackIds.contains(screenTrack.trackId) else {
                logger.log(
                    level: .warning,
                    message: "SFU SDP advertised Android screen msid for participant=\(participantId) but no live screen receiver exists connection=\(connection.id)"
                )
                continue
            }

            connection.remoteScreenTrack = screenTrack
            connection.remoteScreenTracksByParticipantId[participantId] = screenTrack
            consumedTrackIds.insert(screenTrack.trackId)
            await connectionManager.updateConnection(id: connection.id, with: connection)

            logger.log(
                level: .info,
                message: "Mapped Android SFU screen receiver to participant=\(participantId) trackId=\(screenTrack.trackId) connection=\(connection.id)"
            )
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: true)
            )
            if let mediaDelegate {
                await mediaDelegate.didAddRemoteTrack(
                    connectionId: connection.id,
                    participantId: participantId,
                    kind: "screen",
                    trackId: screenTrack.trackId
                )
            }
            if enableEncryption {
                rtcClient.createReceiverEncryptedFrame(
                    participant: participantId,
                    connectionId: connection.id,
                    trackKind: "screen",
                    trackId: screenTrack.trackId
                )
            }
        }
    }

    private func androidStableRemoteScreenTrackLabels(
        in sdp: String,
        connection: RTCConnection
    ) -> [(participantId: String, trackId: String?)] {
        var labels: [(participantId: String, trackId: String?)] = []
        var seen = Set<String>()

        func append(_ participantId: String, trackId: String?) {
            guard !seen.contains(participantId) else { return }
            seen.insert(participantId)
            labels.append((participantId, trackId))
        }

        let screenShares = RTCSession.advertisedRemoteScreenShares(
            in: sdp,
            localParticipantId: connection.localParticipantId,
            resolveParticipantId: { rawLabel in
                var label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.hasPrefix(RTCSession.screenTrackPrefix)
                    || label.hasPrefix("streamId_\(RTCSession.screenTrackPrefix)")
                else { return nil }

                if label.hasPrefix("streamId_") {
                    label = String(label.dropFirst("streamId_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let participant = RTCSession.participantIdFromScreenShareId(label) {
                    label = participant.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !label.isEmpty else { return nil }
                return label
            }
        )
        for share in screenShares {
            append(share.participantId, trackId: share.trackId)
        }

        let relayStyleShares = RTCSession.advertisedRelayStyleRemoteScreenShares(
            in: sdp,
            localParticipantId: connection.localParticipantId,
            participantFromStreamLabel: { rawLabel in
                androidNormalizedRemoteParticipantIdFromSfuStreamLabel(rawLabel, connection: connection)
            }
        )
        for share in relayStyleShares {
            append(share.participantId, trackId: share.trackId)
        }
        if labels.isEmpty,
           connection.localScreenTrack == nil,
           connection.remoteScreenShareStopRequestedParticipantKeys.isEmpty,
           !Self.oneToOneSfuIncomingScreenShareVideoMids(in: sdp).isEmpty,
           let participantId = oneToOneSfuRemoteScreenParticipantId(in: connection),
           Self.isPlausibleConferenceScreenShareParticipantId(participantId) {
            append(participantId, trackId: nil)
        }

        return labels
    }
#endif

    #if canImport(WebRTC)
    /// Disables and clears any *UUID-aliased* receiver FrameCryptors before we rebind a stable
    /// participant id to the same `RTPReceiver`. Two cryptors attached to one receiver in
    /// libwebrtc is undefined behavior, and a stale alias entry would otherwise linger in the
    /// per-participant maps after the rebind.
    ///
    /// - Returns: An updated `RTCConnection` value (caller must persist via `connectionManager`).
    private func clearUuidAliasedReceiverCryptors(
        on connection: RTCConnection,
        keepingParticipantId stable: String?
    ) -> RTCConnection {
        var updated = connection
        let stableNorm = stable?.trimmingCharacters(in: .whitespacesAndNewlines)

        func isUuidAliasedSlot(_ cryptor: RTCFrameCryptor?, entries: [String: RTCFrameCryptor]) -> Bool {
            guard let cryptor else { return false }
            return entries.contains { key, candidate in
                guard candidate === cryptor else { return false }
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard UUID(uuidString: trimmed) != nil else { return false }
                if let stableNorm, trimmed.caseInsensitiveCompare(stableNorm) == .orderedSame {
                    return false
                }
                return true
            }
        }

        let videoSlotIsUuidAlias = isUuidAliasedSlot(
            updated.videoFrameCryptor,
            entries: updated.videoReceiverCryptorsByParticipantId)
        let audioSlotIsUuidAlias = isUuidAliasedSlot(
            updated.audioFrameCryptor,
            entries: updated.audioReceiverCryptorsByParticipantId)

        func dropUuidEntries(_ dict: inout [String: RTCFrameCryptor]) {
            for (key, cryptor) in dict {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard UUID(uuidString: trimmed) != nil else { continue }
                if let stableNorm, trimmed.caseInsensitiveCompare(stableNorm) == .orderedSame {
                    continue
                }
                cryptor.enabled = false
                dict.removeValue(forKey: key)
            }
        }

        dropUuidEntries(&updated.videoReceiverCryptorsByParticipantId)
        dropUuidEntries(&updated.audioReceiverCryptorsByParticipantId)
        dropUuidEntries(&updated.screenReceiverCryptorsByParticipantId)

        // The legacy "single" receiver-cryptor slots can also hold a UUID-bound cryptor that
        // shares the underlying RTPReceiver. Replacing the slot without disabling first would
        // leak a still-active cryptor on that receiver.
        if videoSlotIsUuidAlias, let existingVideo = updated.videoFrameCryptor {
            existingVideo.enabled = false
            updated.videoFrameCryptor = nil
        }
        if audioSlotIsUuidAlias, let existingAudio = updated.audioFrameCryptor {
            existingAudio.enabled = false
            updated.audioFrameCryptor = nil
        }
        updated.screenReceiverCryptorBindingsByParticipantId = updated.screenReceiverCryptorBindingsByParticipantId.filter { key, _ in
            guard UUID(uuidString: key.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return true }
            if let stableNorm, key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(stableNorm) == .orderedSame {
                return true
            }
            return false
        }
        return updated
    }
    #endif

    /// When SFU surfaces UUID-like placeholder stream ids, provision an alias key for that UUID
    /// from the *only* unambiguous remote candidate (true 1:1 SFU rooms) so receiver FrameCryptor
    /// can start immediately. We deliberately refuse to guess in multi-party calls — picking the
    /// wrong peer's key would silently bind the cryptor to garbage and produce no decoded frames.
    ///
    /// - Returns: `true` only when an alias key was actually provisioned (or already existed).
    private func tryProvisionUuidAliasFrameKeyIfPossible(
        for participantId: String,
        connection: RTCConnection
    ) async -> Bool {
        guard enableEncryption else { return false }
        guard frameEncryptionKeyMode == .perParticipant else { return false }
        let target = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: target) != nil else { return false }
        if lastFrameKeyIndexByParticipantId[target] != nil {
            return true
        }

        let localNorm = connection.localParticipantId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Build a set of *non-local*, *non-target* candidates that already have a provisioned key.
        // We never alias from the local slot — that's our own send key and cannot decrypt remote
        // media regardless of how the SFU labels the stream.
        var seen: Set<String> = []
        var candidates: [String] = []
        let raw = [connection.remoteParticipantId]
            + connection.call.recipients.map(\.secretName)
            + Array(lastFrameKeyIndexByParticipantId.keys)
        for r in raw {
            let id = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  id.lowercased() != localNorm,
                  id.caseInsensitiveCompare(target) != .orderedSame,
                  lastFrameKeyIndexByParticipantId[id] != nil
            else { continue }
            if seen.insert(id.lowercased()).inserted {
                candidates.append(id)
            }
        }

        // Only alias when there is a single, unambiguous remote candidate. With more than one
        // remote we cannot tell which peer the UUID stream belongs to; defer to the
        // `addedStream` rebind path once the SFU publishes the stable participant id.
        guard candidates.count == 1, let source = candidates.first,
              let sourceIndex = lastFrameKeyIndexByParticipantId[source], sourceIndex >= 0
        else {
            return false
        }

        let sourceKey = await exportFrameEncryptionKey(index: sourceIndex, for: source)
        guard !sourceKey.isEmpty else { return false }
        await setFrameEncryptionKey(sourceKey, index: sourceIndex, for: target)
        logger.log(
            level: .info,
            message: "Provisioned UUID alias frame key participantId='\(target)' from sourceParticipantId='\(source)' index=\(sourceIndex) connId=\(connection.id)"
        )
        return true
    }

    /// Remote track owner id for 1:1 SFU renderer/track resolution — maps room-routed
    /// `remoteParticipantId` to the peer's secretName (same rules as frame-key provisioning).
    func oneToOneSfuRemoteTrackOwnerId(connection: RTCConnection) -> String {
        if let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !owner.isEmpty {
            return owner
        }
        return connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

#if canImport(WebRTC) && !os(Android)
    /// Rebinds receiver FrameCryptors to live RTP receivers after SFU renegotiation completes.
    ///
    /// Receiver cryptors are often created during `setRemoteDescription` (inside reconcile) before
    /// the answering side applies its local description. WebRTC can swap the active `RTCRtpReceiver`
    /// when the answer is applied, leaving decrypt on a stale receiver while RTP keeps flowing.
    func reconcileAppleReceiverFrameCryptorsAfterSfuRenegotiation(connectionId: String) async {
        guard enableEncryption else { return }
        guard frameEncryptionKeyMode == .perParticipant else { return }
        guard let connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        let localParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteParticipantIds = lastFrameKeyIndexByParticipantId.keys.filter { participantId in
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard UUID(uuidString: trimmed) == nil else { return false }
            return trimmed.caseInsensitiveCompare(localParticipantId) != .orderedSame
        }
        guard !remoteParticipantIds.isEmpty else { return }

        for participantId in remoteParticipantIds {
            guard appleGroupParticipantReceiverCryptorsNeedRebind(
                connection: connection,
                participantId: participantId
            ) else {
                continue
            }
            do {
                try await appleReattachReceiverFrameCryptorsAfterFrameKeyInstall(
                    connection: connection,
                    provisionedRemoteTrackOwnerId: participantId)
                logger.log(
                    level: .info,
                    message: "Rebound SFU receiver FrameCryptors after renegotiation participantId='\(participantId)' connection=\(connectionId)")
            } catch {
                logger.log(
                    level: .warning,
                    message: "Failed to rebind SFU receiver FrameCryptors after renegotiation participantId='\(participantId)' connection=\(connectionId): \(error)")
            }
        }
    }

    private func advertisedSfuRemoteMediaTrackIds(
        mediaKind: String,
        participantId: String,
        connection: RTCConnection
    ) -> Set<String> {
        guard let sdp = connection.peerConnection.remoteDescription?.sdp else { return [] }

        var result: Set<String> = []
        var currentMediaKind: String?
        var currentSectionLines: [String] = []

        func flushCurrentSection() {
            guard currentMediaKind == mediaKind else { return }
            guard !currentSectionLines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
                return
            }

            for entry in Self.sfuSdpMsidEntries(inSectionLines: currentSectionLines) {
                guard let owner = normalizedRemoteParticipantIdFromSfuStreamLabel(entry.streamLabel, connection: connection),
                      owner.caseInsensitiveCompare(participantId) == .orderedSame,
                      let trackId = entry.trackId
                else {
                    continue
                }
                result.insert(trackId)
            }
        }

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("m=") {
                flushCurrentSection()
                currentSectionLines = [line]
                if line.hasPrefix("m=audio") {
                    currentMediaKind = "audio"
                } else if line.hasPrefix("m=video") {
                    currentMediaKind = "video"
                } else {
                    currentMediaKind = nil
                }
            } else {
                currentSectionLines.append(line)
            }
        }
        flushCurrentSection()

        return result
    }

    /// Resolves the live inbound remote camera track for a 1:1 SFU room using the same SDP/map
    /// rules as receiver FrameCryptor binding — never the first video transceiver placeholder.
    ///
    /// The participant id must be the actual remote track owner (peer secretName), not
    /// `connection.remoteParticipantId`: in 1:1 SFU rooms that property is the **room id**
    /// (signaling routing), while the SDP advertises msid owners like `echo`/`nudge`. Matching
    /// against the room id makes the owner lookup miss and callers fall back to the positional
    /// resolver, which returns the placeholder receive half of our own send m-line.
    func resolveOneToOneSfuInboundRemoteCameraVideoTrack(
        connection: RTCConnection
    ) -> RTCVideoTrack? {
        let remotePid = oneToOneSfuRemoteTrackOwnerId(connection: connection)
        guard !remotePid.isEmpty else { return nil }
        return appleResolveLiveVideoReceiver(for: remotePid, connection: connection)?.track
    }

    private func appleResolveLiveVideoReceiver(
        for participantId: String,
        connection: RTCConnection
    ) -> (receiver: RTCRtpReceiver, track: RTCVideoTrack)? {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let advertised = advertisedSfuRemoteMediaTrackIds(
            mediaKind: "video",
            participantId: trimmed,
            connection: connection
        )

        let participantKey = Self.conferenceParticipantIdentityKey(trimmed)
        let mappedTrack = connection.remoteVideoTracksByParticipantId[trimmed]
            ?? connection.remoteVideoTracksByParticipantId.first(where: {
                Self.conferenceParticipantIdentityKey($0.key) == participantKey
            })?.value

        // Trust the participant map only while it agrees with what the SDP advertises for this
        // participant. A stale map entry (e.g. the placeholder receive track of our own send
        // m-line in 1:1 SFU) would otherwise mask the receiver that actually carries their RTP.
        if let mappedTrack,
           advertised.isEmpty || advertised.contains(mappedTrack.trackId),
           let receiver = connection.peerConnection.receivers.first(where: {
               guard let track = $0.track as? RTCVideoTrack,
                     track.readyState != .ended,
                     !RTCSession.isScreenShareId(track.trackId)
               else { return false }
               return track === mappedTrack || track.trackId == mappedTrack.trackId
           }),
           let track = receiver.track as? RTCVideoTrack {
            return (receiver, track)
        }

        guard !advertised.isEmpty else { return nil }

        let matches: [(receiver: RTCRtpReceiver, track: RTCVideoTrack)] = connection.peerConnection.receivers.compactMap { receiver in
            guard let track = receiver.track as? RTCVideoTrack,
                  track.readyState != .ended,
                  !RTCSession.isScreenShareId(track.trackId),
                  advertised.contains(track.trackId)
            else {
                return nil
            }
            return (receiver, track)
        }
        if matches.count == 1, let match = matches.first { return match }
        if matches.count > 1 {
            let namedPrefix = "video_\(participantKey)".lowercased()
            if let named = matches.first(where: { $0.track.trackId.lowercased().hasPrefix(namedPrefix) }) {
                return named
            }
        }
        return nil
    }

    private func appleResolveLiveAudioReceiver(
        for participantId: String,
        connection: RTCConnection
    ) -> (receiver: RTCRtpReceiver, track: RTCAudioTrack)? {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let advertised = advertisedSfuRemoteMediaTrackIds(
            mediaKind: "audio",
            participantId: trimmed,
            connection: connection
        )

        // See appleResolveLiveVideoReceiver: only trust the map while it matches advertised ids.
        if let mappedTrack = connection.remoteAudioTracksByParticipantId[trimmed],
           advertised.isEmpty || advertised.contains(mappedTrack.trackId),
           let receiver = connection.peerConnection.receivers.first(where: {
               guard let track = $0.track as? RTCAudioTrack,
                     track.readyState != .ended
               else { return false }
               return track === mappedTrack || track.trackId == mappedTrack.trackId
           }),
           let track = receiver.track as? RTCAudioTrack {
            return (receiver, track)
        }

        guard !advertised.isEmpty else { return nil }

        let matches: [(receiver: RTCRtpReceiver, track: RTCAudioTrack)] = connection.peerConnection.receivers.compactMap { receiver in
            guard let track = receiver.track as? RTCAudioTrack,
                  track.readyState != .ended,
                  advertised.contains(track.trackId)
            else {
                return nil
            }
            return (receiver, track)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return match
    }

    private func appleResolveLiveScreenReceiver(
        for participantId: String,
        connection: RTCConnection
    ) -> (receiver: RTCRtpReceiver, track: RTCVideoTrack)? {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func receiver(matching liveTrack: RTCVideoTrack) -> RTCRtpReceiver? {
            connection.peerConnection.receivers.first {
                guard let track = $0.track as? RTCVideoTrack,
                      track.readyState != .ended
                else { return false }
                return track === liveTrack || track.trackId == liveTrack.trackId
            }
        }

        let mappedTrack = connection.remoteScreenTracksByParticipantId[trimmed]
            ?? connection.remoteScreenTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key) == Self.conferenceParticipantIdentityKey(trimmed)
            }?.value

        let remoteSdp = connection.peerConnection.remoteDescription?.sdp ?? ""
        var activeScreenMids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
            .union(Self.sfuRelayIncomingScreenShareVideoMids(in: remoteSdp))
        if Self.isTrueOneToOneSfuRoom(call: connection.call) {
            activeScreenMids.formUnion(Self.oneToOneSfuIncomingScreenShareVideoMids(in: remoteSdp))
        }

        if let mappedTrack,
           let liveTrack = Self.resolveLiveGroupParticipantScreenTrack(
            storedTrackId: mappedTrack.trackId,
            participantId: trimmed,
            in: connection.peerConnection,
            cameraTrackIds: Set(connection.remoteVideoTracksByParticipantId.values.map(\.trackId)),
            activeIncomingScreenMids: activeScreenMids
           ),
           let liveReceiver = receiver(matching: liveTrack) {
            return (liveReceiver, liveTrack)
        }

        if let mappedTrack,
           mappedTrack.readyState != .ended,
           let mappedReceiver = receiver(matching: mappedTrack) {
            return (mappedReceiver, mappedTrack)
        }

        let advertisedTrackIds = Set(
            stableRemoteScreenTrackLabels(in: remoteSdp, connection: connection)
                .filter {
                    Self.conferenceParticipantIdentityKey($0.participantId)
                        == Self.conferenceParticipantIdentityKey(trimmed)
                }
                .compactMap { $0.trackId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !advertisedTrackIds.isEmpty else { return nil }
        let matches: [(receiver: RTCRtpReceiver, track: RTCVideoTrack)] = connection.peerConnection.receivers.compactMap { candidate in
            guard let track = candidate.track as? RTCVideoTrack,
                  track.readyState != .ended,
                  advertisedTrackIds.contains(track.trackId)
            else { return nil }
            return (candidate, track)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return match
    }

    private func appleGroupParticipantReceiverCryptorsNeedRebind(
        connection: RTCConnection,
        participantId: String
    ) -> Bool {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let audioBinding = connection.audioReceiverCryptorBindingsByParticipantId[trimmed],
           connection.audioReceiverCryptorsByParticipantId[trimmed] != nil,
           let audioMatch = appleResolveLiveAudioReceiver(for: trimmed, connection: connection) {
            let liveReceiverId = String(describing: ObjectIdentifier(audioMatch.receiver))
            if audioBinding.trackId != audioMatch.track.trackId || audioBinding.receiverId != liveReceiverId {
                return true
            }
        } else if connection.remoteAudioTracksByParticipantId[trimmed] != nil
            || !advertisedSfuRemoteMediaTrackIds(mediaKind: "audio", participantId: trimmed, connection: connection).isEmpty {
            return true
        }

        if connection.remoteVideoTracksByParticipantId[trimmed] != nil {
            if let videoBinding = connection.videoReceiverCryptorBindingsByParticipantId[trimmed],
               connection.videoReceiverCryptorsByParticipantId[trimmed] != nil,
               let videoMatch = appleResolveLiveVideoReceiver(for: trimmed, connection: connection) {
                let liveReceiverId = String(describing: ObjectIdentifier(videoMatch.receiver))
                if videoBinding.trackId != videoMatch.track.trackId || videoBinding.receiverId != liveReceiverId {
                    return true
                }
            } else {
                return true
            }
        }

        let mappedScreenTrack = connection.remoteScreenTracksByParticipantId[trimmed]
            ?? connection.remoteScreenTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key) == Self.conferenceParticipantIdentityKey(trimmed)
            }?.value
        if mappedScreenTrack != nil {
            if let screenBinding = connection.screenReceiverCryptorBindingsByParticipantId[trimmed],
               connection.screenReceiverCryptorsByParticipantId[trimmed] != nil,
               let screenMatch = appleResolveLiveScreenReceiver(for: trimmed, connection: connection) {
                let receiverId = String(describing: ObjectIdentifier(screenMatch.receiver))
                if screenBinding.trackId != screenMatch.track.trackId || screenBinding.receiverId != receiverId {
                    return true
                }
            } else {
                return true
            }
        }

        return false
    }

    private func appleBindGroupAudioReceiverCryptorFromAdvertisedMsidIfNeeded(
        conn: inout RTCConnection,
        participantId: String
    ) async throws {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Self.usesApplicationInjectedGroupFrameKeys(call: conn.call),
              isGroupCallConnection(conn.id),
              !Self.isTrueOneToOneSfuRoom(call: conn.call),
              frameEncryptionKeyMode == .perParticipant else {
            return
        }

        guard let match = appleResolveLiveAudioReceiver(for: trimmed, connection: conn) else {
            let advertisedCount = advertisedSfuRemoteMediaTrackIds(
                mediaKind: "audio",
                participantId: trimmed,
                connection: conn
            ).count
            if advertisedCount > 1 {
                logger.log(
                    level: .warning,
                    message: "Skipped SFU audio receiver FrameCryptor bind for participant=\(trimmed): SDP advertised \(advertisedCount) audio tracks but no unique live receiver connection=\(conn.id)"
                )
            }
            return
        }

        if let existingBinding = conn.audioReceiverCryptorBindingsByParticipantId[trimmed],
           conn.audioReceiverCryptorsByParticipantId[trimmed] != nil {
            // trackId alone is not proof of a live bind: SFU renegotiation rotates the
            // RTCRtpReceiver while trackId stays stable, leaving the cryptor on a dead receiver
            // (audio then plays as ciphertext). Only skip when the receiver also matches.
            if existingBinding.trackId == match.track.trackId,
               existingBinding.receiverId == String(describing: ObjectIdentifier(match.receiver)) {
                return
            }
        }

        conn.remoteAudioTracksByParticipantId[trimmed] = match.track
        await connectionManager.updateConnection(id: conn.id, with: conn)

        if let mediaDelegate {
            await mediaDelegate.didAddRemoteTrack(
                connectionId: conn.id,
                participantId: trimmed,
                kind: "audio",
                trackId: match.track.trackId
            )
        }

        if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: trimmed),
           !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
            connection: conn,
            participantIdOverride: trimmed) {
            try await createEncryptedFrame(
                connection: conn,
                kind: .audioReceiver(match.receiver),
                participantIdOverride: trimmed
            )
            if let latest = await connectionManager.findConnection(with: conn.id) {
                conn = latest
            }
            logger.log(
                level: .info,
                message: "Bound SFU audio receiver FrameCryptor from advertised msid participant=\(trimmed) trackId=\(match.track.trackId) connection=\(conn.id)"
            )
        }
    }
#endif

#if canImport(WebRTC)
    /// Re-binds Apple WebRTC receiver `RTCFrameCryptor`s after a frame key is installed.
    ///
    /// Android calls `createReceiverEncryptedFrame` from its key-install paths; Apple historically
    /// only updated the key provider. When `didAddReceiver` runs before the key arrives, initial
    /// cryptors may never observe keys (ICE connected, tracks attached, zero decoded frames).
    ///
    /// For true 1:1 SFU this rebinds UUID/self-labeled placeholders to the remote peer. For group
    /// SFU it only rebinds tracks whose resolved owner matches the newly provisioned sender key,
    /// preserving the per-participant receiver cryptor maps used by multi-party layouts.
    internal func appleReattachReceiverFrameCryptorsAfterFrameKeyInstall(
        connection: RTCConnection,
        provisionedRemoteTrackOwnerId: String
    ) async throws {
        guard enableEncryption else { return }
        let provisioned = provisionedRemoteTrackOwnerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provisioned.isEmpty else { return }

        guard var conn = await connectionManager.findConnection(with: connection.id) else { return }

        if Self.isTrueOneToOneSfuRoom(call: conn.call) {
            conn = clearUuidAliasedReceiverCryptors(on: conn, keepingParticipantId: provisioned)
        } else {
            appleDropUuidAliasedReceiverCryptorMapEntries(&conn, keepingParticipantId: provisioned)
        }
        await connectionManager.updateConnection(id: conn.id, with: conn)

        guard var connAfterClear = await connectionManager.findConnection(with: connection.id) else { return }

        try await appleRebindAppleReceiverCryptorsFromTrackMaps(
            conn: &connAfterClear,
            provisionedRemoteTrackOwnerId: provisioned)
        await connectionManager.updateConnection(id: connAfterClear.id, with: connAfterClear)
    }

    private func appleDropUuidAliasedReceiverCryptorMapEntries(
        _ conn: inout RTCConnection,
        keepingParticipantId: String?
    ) {
        let stableNorm = keepingParticipantId?.trimmingCharacters(in: .whitespacesAndNewlines)
        func dropUuidEntries(_ dict: inout [String: RTCFrameCryptor]) {
            for (key, cryptor) in dict {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard UUID(uuidString: trimmed) != nil else { continue }
                if let stableNorm, trimmed.caseInsensitiveCompare(stableNorm) == .orderedSame {
                    continue
                }
                cryptor.enabled = false
                cryptor.delegate = nil
                dict.removeValue(forKey: key)
            }
        }
        dropUuidEntries(&conn.videoReceiverCryptorsByParticipantId)
        dropUuidEntries(&conn.audioReceiverCryptorsByParticipantId)
        dropUuidEntries(&conn.screenReceiverCryptorsByParticipantId)
        conn.videoReceiverCryptorBindingsByParticipantId = conn.videoReceiverCryptorBindingsByParticipantId.filter { key, _ in
            guard UUID(uuidString: key.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return true }
            if let stableNorm, key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(stableNorm) == .orderedSame {
                return true
            }
            return false
        }
        conn.audioReceiverCryptorBindingsByParticipantId = conn.audioReceiverCryptorBindingsByParticipantId.filter { key, _ in
            guard UUID(uuidString: key.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return true }
            if let stableNorm, key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(stableNorm) == .orderedSame {
                return true
            }
            return false
        }
        conn.screenReceiverCryptorBindingsByParticipantId = conn.screenReceiverCryptorBindingsByParticipantId.filter { key, _ in
            guard UUID(uuidString: key.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return true }
            if let stableNorm, key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(stableNorm) == .orderedSame {
                return true
            }
            return false
        }
    }

    private func appleRebindAppleReceiverCryptorsFromTrackMaps(
        conn: inout RTCConnection,
        provisionedRemoteTrackOwnerId: String
    ) async throws {
        let provisioned = provisionedRemoteTrackOwnerId.trimmingCharacters(in: .whitespacesAndNewlines)

        func matchesProvisioned(effectiveReceiverId: String?) -> Bool {
            if frameEncryptionKeyMode == .shared { return true }
            let eff = (effectiveReceiverId ?? conn.remoteParticipantId).trimmingCharacters(in: .whitespacesAndNewlines)
            return eff.caseInsensitiveCompare(provisioned) == .orderedSame
        }

        func refreshConn() async {
            if let latest = await connectionManager.findConnection(with: conn.id) {
                conn = latest
            }
        }

        func isMappedToStableParticipant(_ track: RTCMediaStreamTrack) -> Bool {
            let videoMapped = conn.remoteVideoTracksByParticipantId.contains { participantId, mappedTrack in
                UUID(uuidString: participantId.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
                    && (mappedTrack === track || mappedTrack.trackId == track.trackId)
            }
            let audioMapped = conn.remoteAudioTracksByParticipantId.contains { participantId, mappedTrack in
                UUID(uuidString: participantId.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
                    && (mappedTrack === track || mappedTrack.trackId == track.trackId)
            }
            return videoMapped || audioMapped
        }

        func mapSingleUnresolvedGroupReceiverIfNeeded() async throws {
            guard Self.usesApplicationInjectedGroupFrameKeys(call: conn.call),
                  isGroupCallConnection(conn.id),
                  !Self.isTrueOneToOneSfuRoom(call: conn.call),
                  frameEncryptionKeyMode == .perParticipant,
                  !provisioned.isEmpty else {
                return
            }

            await refreshConn()

            if conn.videoReceiverCryptorsByParticipantId[provisioned] == nil,
               conn.remoteVideoTracksByParticipantId[provisioned] == nil {
                let advertisedVideoIds = advertisedSfuRemoteMediaTrackIds(
                    mediaKind: "video",
                    participantId: provisioned,
                    connection: conn
                )
                let sdpVideoTrackIds: Set<String>
                if let remoteSdp = conn.peerConnection.remoteDescription?.sdp {
                    sdpVideoTrackIds = Set(
                        appleStableRemoteCameraTrackLabels(in: remoteSdp, connection: conn)
                            .filter { $0.participantId.caseInsensitiveCompare(provisioned) == .orderedSame }
                            .compactMap { $0.trackId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                } else {
                    sdpVideoTrackIds = []
                }
                let videoCandidates: [(receiver: RTCRtpReceiver, track: RTCVideoTrack)] = conn.peerConnection.transceivers.compactMap { transceiver in
                    guard transceiver.mediaType == .video,
                          let track = transceiver.receiver.track as? RTCVideoTrack,
                          track.readyState != .ended,
                          !RTCSession.isScreenShareId(track.trackId),
                          !isAppleDedicatedScreenShareTransceiver(transceiver, connection: conn),
                          !isMappedToStableParticipant(track)
                    else {
                        return nil
                    }
                    if !advertisedVideoIds.isEmpty, !advertisedVideoIds.contains(track.trackId) {
                        return nil
                    }
                    return (transceiver.receiver, track)
                }

                let resolvedVideoCandidate: (receiver: RTCRtpReceiver, track: RTCVideoTrack)? = {
                    func candidateMatchesProvisioned(_ candidate: (receiver: RTCRtpReceiver, track: RTCVideoTrack)) -> Bool {
                        if !advertisedVideoIds.isEmpty {
                            return advertisedVideoIds.contains(candidate.track.trackId)
                        }
                        if !sdpVideoTrackIds.isEmpty {
                            return sdpVideoTrackIds.contains(candidate.track.trackId)
                        }
                        return appleSfuReceiverTrackMatchesProvisionedParticipant(
                            receiver: candidate.receiver,
                            track: candidate.track,
                            provisioned: provisioned,
                            connection: conn
                        )
                    }

                    let matching = videoCandidates.filter { candidateMatchesProvisioned($0) }
                    return GroupSfuVideoAttachPolicy.resolvedUnresolvedSfuReceiverCandidate(
                        candidates: videoCandidates,
                        matchingCandidates: matching,
                        advertisedTrackIds: advertisedVideoIds,
                        sdpTrackIds: sdpVideoTrackIds,
                        trackId: { $0.track.trackId }
                    )
                }()

                if let candidate = resolvedVideoCandidate {
                    guard Self.claimRemoteCameraTrack(
                        candidate.track,
                        participantId: provisioned,
                        in: &conn,
                        allowReplacingExistingStableOwner: appleSfuReceiverTrackMatchesProvisionedParticipant(
                            receiver: candidate.receiver,
                            track: candidate.track,
                            provisioned: provisioned,
                            connection: conn
                        )
                    ) else {
                        logger.log(
                            level: .warning,
                            message: "Rejected unresolved SFU video receiver fallback for participant=\(provisioned): track \(candidate.track.trackId) already has a stable owner"
                        )
                        return
                    }
                    conn.remoteVideoTrack = candidate.track
                    await connectionManager.updateConnection(id: conn.id, with: conn)

                    notifyRemoteParticipantTrackChanged(
                        RemoteParticipantTrackEvent(connectionId: conn.id, participantId: provisioned, kind: "video", isActive: true)
                    )
                    if let mediaDelegate {
                        await mediaDelegate.didAddRemoteTrack(
                            connectionId: conn.id,
                            participantId: provisioned,
                            kind: "video",
                            trackId: candidate.track.trackId)
                    }

                    if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: provisioned),
                       !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                        connection: conn,
                        participantIdOverride: provisioned) {
                        try await createEncryptedFrame(
                            connection: conn,
                            kind: .videoReceiver(candidate.receiver),
                            participantIdOverride: provisioned)
                        await refreshConn()
                        logger.log(
                            level: .info,
                            message: "Mapped unresolved SFU video receiver to provisioned participant=\(provisioned) trackId=\(candidate.track.trackId) connection=\(conn.id)")
                    }
                } else if !videoCandidates.isEmpty {
                    logger.log(
                        level: .warning,
                        message: "Skipped unresolved SFU video receiver fallback for participant=\(provisioned): \(videoCandidates.count) possible receivers")
                }
            }

            if conn.audioReceiverCryptorsByParticipantId[provisioned] == nil,
               conn.remoteAudioTracksByParticipantId[provisioned] == nil {
                let advertisedAudioIds = advertisedSfuRemoteMediaTrackIds(
                    mediaKind: "audio",
                    participantId: provisioned,
                    connection: conn
                )
                let sdpAudioTrackIds: Set<String>
                if let remoteSdp = conn.peerConnection.remoteDescription?.sdp {
                    sdpAudioTrackIds = Set(
                        appleStableRemoteAudioTrackLabels(in: remoteSdp, connection: conn)
                            .filter { $0.participantId.caseInsensitiveCompare(provisioned) == .orderedSame }
                            .compactMap { $0.trackId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    )
                } else {
                    sdpAudioTrackIds = []
                }
                let audioCandidates: [(receiver: RTCRtpReceiver, track: RTCAudioTrack)] = conn.peerConnection.transceivers.compactMap { transceiver in
                    guard transceiver.mediaType == .audio,
                          // Never map a remote participant onto the local publish m-line's
                          // receiver: it has no FrameCryptor and plays ciphertext (garbled).
                          transceiver.sender.track == nil,
                          let track = transceiver.receiver.track as? RTCAudioTrack,
                          track.readyState != .ended,
                          !isMappedToStableParticipant(track)
                    else {
                        return nil
                    }
                    if !advertisedAudioIds.isEmpty, !advertisedAudioIds.contains(track.trackId) {
                        return nil
                    }
                    return (transceiver.receiver, track)
                }

                let resolvedAudioCandidate: (receiver: RTCRtpReceiver, track: RTCAudioTrack)? = {
                    return GroupSfuVideoAttachPolicy.resolvedUnresolvedSfuReceiverCandidate(
                        candidates: audioCandidates,
                        matchingCandidates: [],
                        advertisedTrackIds: advertisedAudioIds,
                        sdpTrackIds: sdpAudioTrackIds,
                        trackId: { $0.track.trackId }
                    )
                }()

                if let candidate = resolvedAudioCandidate {
                    conn.remoteAudioTracksByParticipantId[provisioned] = candidate.track
                    syncAppleRemoteSfuAudioTrackPlayback(
                        connection: conn,
                        participantId: provisioned,
                        track: candidate.track
                    )
                    await connectionManager.updateConnection(id: conn.id, with: conn)

                    if let mediaDelegate {
                        await mediaDelegate.didAddRemoteTrack(
                            connectionId: conn.id,
                            participantId: provisioned,
                            kind: "audio",
                            trackId: candidate.track.trackId)
                    }

                    if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: provisioned),
                       !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                        connection: conn,
                        participantIdOverride: provisioned) {
                        try await createEncryptedFrame(
                            connection: conn,
                            kind: .audioReceiver(candidate.receiver),
                            participantIdOverride: provisioned)
                        await refreshConn()
                        logger.log(
                            level: .info,
                            message: "Mapped unresolved SFU audio receiver to provisioned participant=\(provisioned) trackId=\(candidate.track.trackId) connection=\(conn.id)")
                    }
                } else if !audioCandidates.isEmpty {
                    logger.log(
                        level: .warning,
                        message: "Skipped unresolved SFU audio receiver fallback for participant=\(provisioned): \(audioCandidates.count) possible receivers")
                }
            }
        }

        try await mapSingleUnresolvedGroupReceiverIfNeeded()

        for (streamPid, videoTrack) in conn.remoteVideoTracksByParticipantId {
            let isScreenTrack =
                RTCSession.isScreenShareId(videoTrack.trackId) || RTCSession.isScreenShareId(streamPid)
            if isScreenTrack {
                guard let receiver = conn.peerConnection.receivers.first(where: { $0.track?.trackId == videoTrack.trackId })
                else { continue }
                let resolved = receiverParticipantIdOverrideForE2EE(
                    connection: conn,
                    participantIdFromStreamIds: streamPid
                )
                let receiverPid = resolved.override
                guard matchesProvisioned(effectiveReceiverId: receiverPid) else { continue }
                if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: receiverPid) {
                    try await createEncryptedFrame(
                        connection: conn,
                        kind: .screenReceiver(receiver),
                        participantIdOverride: receiverPid)
                        await refreshConn()
                }
            } else {
                guard let receiver = conn.peerConnection.receivers.first(where: { $0.track?.trackId == videoTrack.trackId })
                else { continue }
                let resolved = receiverParticipantIdOverrideForE2EE(
                    connection: conn,
                    participantIdFromStreamIds: streamPid
                )
                let receiverPid = resolved.override
                guard matchesProvisioned(effectiveReceiverId: receiverPid) else { continue }

                // 1:1 SFU: a stale map entry can still point at the placeholder receive track of
                // our own send m-line after renegotiation. Binding the cryptor there would strand
                // the peer's advertised receiver undecrypted; appleEnsureOneToOneSfuReceiverCryptors
                // (below) binds the advertised receiver instead.
                if Self.isTrueOneToOneSfuRoom(call: conn.call) {
                    let advertised = advertisedSfuRemoteMediaTrackIds(
                        mediaKind: "video",
                        participantId: receiverPid ?? streamPid,
                        connection: conn
                    )
                    if !advertised.isEmpty, !advertised.contains(videoTrack.trackId) {
                        logger.log(
                            level: .info,
                            message: "Skipping stale 1:1 SFU mapped video track for receiver cryptor rebind participantId=\(receiverPid ?? streamPid) trackId=\(videoTrack.trackId); SDP advertises a different remote-owned track connId=\(conn.id)")
                        continue
                    }
                }

                if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: receiverPid),
                   !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                    connection: conn,
                    participantIdOverride: receiverPid) {
                    try await createEncryptedFrame(
                        connection: conn,
                        kind: .videoReceiver(receiver),
                        participantIdOverride: receiverPid)
                    await refreshConn()
                } else if shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                    connection: conn,
                    participantIdOverride: receiverPid) {
                    let aliasProvisioned = await tryProvisionUuidAliasFrameKeyIfPossible(
                        for: receiverPid ?? "",
                        connection: conn
                    )
                    if aliasProvisioned {
                        try await createEncryptedFrame(
                            connection: conn,
                            kind: .videoReceiver(receiver),
                            participantIdOverride: receiverPid)
                        await refreshConn()
                    }
                }
            }
        }

        if let vt = conn.remoteVideoTrack, conn.remoteVideoTracksByParticipantId.isEmpty {
            let fallbackPid =
                remoteTrackOwnerParticipantId(connection: conn, call: conn.call)
                ?? conn.remoteParticipantId
            let isScreenTrack =
                RTCSession.isScreenShareId(vt.trackId) || RTCSession.isScreenShareId(fallbackPid)
            if isScreenTrack {
                if let receiver = conn.peerConnection.receivers.first(where: { $0.track?.trackId == vt.trackId }) {
                    let resolved = receiverParticipantIdOverrideForE2EE(
                        connection: conn,
                        participantIdFromStreamIds: fallbackPid
                    )
                    let receiverPid = resolved.override
                    if matchesProvisioned(effectiveReceiverId: receiverPid),
                       !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: receiverPid) {
                        try await createEncryptedFrame(
                            connection: conn,
                            kind: .screenReceiver(receiver),
                            participantIdOverride: receiverPid)
                        await refreshConn()
                    }
                }
            } else if let receiver = conn.peerConnection.receivers.first(where: { $0.track?.trackId == vt.trackId }) {
                let resolved = receiverParticipantIdOverrideForE2EE(
                    connection: conn,
                    participantIdFromStreamIds: fallbackPid
                )
                let receiverPid = resolved.override
                if matchesProvisioned(effectiveReceiverId: receiverPid) {
                    if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: receiverPid),
                       !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                        connection: conn,
                        participantIdOverride: receiverPid) {
                        try await createEncryptedFrame(
                            connection: conn,
                            kind: .videoReceiver(receiver),
                            participantIdOverride: receiverPid)
                        await refreshConn()
                    } else if shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                        connection: conn,
                        participantIdOverride: receiverPid) {
                        let aliasProvisioned = await tryProvisionUuidAliasFrameKeyIfPossible(
                            for: receiverPid ?? "",
                            connection: conn
                        )
                        if aliasProvisioned {
                            try await createEncryptedFrame(
                                connection: conn,
                                kind: .videoReceiver(receiver),
                                participantIdOverride: receiverPid)
                            await refreshConn()
                        }
                    }
                }
            }
        }

#if !os(Android)
        try await appleBindGroupAudioReceiverCryptorFromAdvertisedMsidIfNeeded(
            conn: &conn,
            participantId: provisioned)
#endif

        for (streamPid, screenTrack) in conn.remoteScreenTracksByParticipantId {
            guard let receiver = conn.peerConnection.receivers.first(where: { $0.track?.trackId == screenTrack.trackId })
            else { continue }
            let resolved = receiverParticipantIdOverrideForE2EE(
                connection: conn,
                participantIdFromStreamIds: streamPid
            )
            let receiverPid = resolved.override
            guard matchesProvisioned(effectiveReceiverId: receiverPid) else { continue }
            if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: receiverPid) {
                try await createEncryptedFrame(
                    connection: conn,
                    kind: .screenReceiver(receiver),
                    participantIdOverride: receiverPid)
                await refreshConn()
            }
        }

        if Self.isTrueOneToOneSfuRoom(call: conn.call) {
            try await appleEnsureOneToOneSfuReceiverCryptors(
                conn: &conn,
                provisionedRemoteTrackOwnerId: provisioned)
        }

        logger.log(
            level: .info,
            message: "Apple receiver FrameCryptor reattach finished after frame key install connId=\(conn.id) provisionedRemoteTrackOwner='\(provisioned)'"
        )
    }

    private func appleEnsureOneToOneSfuReceiverCryptors(
        conn: inout RTCConnection,
        provisionedRemoteTrackOwnerId: String
    ) async throws {
        let participantId = provisionedRemoteTrackOwnerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantId.isEmpty else { return }

        func receiver(matching track: RTCMediaStreamTrack?) -> RTCRtpReceiver? {
            guard let track else { return nil }
            return conn.peerConnection.receivers.first {
                guard let receiverTrack = $0.track,
                      receiverTrack.readyState != .ended
                else { return false }
                return receiverTrack === track || receiverTrack.trackId == track.trackId
            }
        }

        func singleLiveReceiver(kind: String, allowScreenShare: Bool = false) -> RTCRtpReceiver? {
            let candidates = conn.peerConnection.receivers.filter { candidate in
                guard let track = candidate.track,
                      track.kind == kind,
                      track.readyState != .ended
                else { return false }
                if kind == kRTCMediaStreamTrackKindVideo,
                   !allowScreenShare,
                   RTCSession.isScreenShareId(track.trackId) {
                    return false
                }
                return true
            }
            return candidates.count == 1 ? candidates[0] : nil
        }

        // Receiver whose live track the remote SDP advertises for this participant (msid stream
        // label). This is the receiver that actually carries the peer's RTP after the SFU
        // renegotiates their published tracks into the room; mapped/single fallbacks can point at
        // the placeholder receive half of our own send m-line. When the SFU advertises multiple
        // tracks of the same kind for the peer (observed: duplicated audio m-lines across
        // renegotiations), prefer the deterministically named `<kind>_<peer>…` track — every
        // advertised track is encrypted with the same per-participant sender key, so decrypting
        // the named one is sufficient.
        func advertisedReceiver(kind: String) -> RTCRtpReceiver? {
            let mediaKind = kind == kRTCMediaStreamTrackKindVideo ? "video" : "audio"
            let advertisedIds = advertisedSfuRemoteMediaTrackIds(
                mediaKind: mediaKind,
                participantId: participantId,
                connection: conn
            )
            guard !advertisedIds.isEmpty else { return nil }
            let matches = conn.peerConnection.receivers.filter { candidate in
                guard let track = candidate.track,
                      track.kind == kind,
                      track.readyState != .ended,
                      advertisedIds.contains(track.trackId)
                else { return false }
                if kind == kRTCMediaStreamTrackKindVideo,
                   RTCSession.isScreenShareId(track.trackId) {
                    return false
                }
                return true
            }
            if matches.count <= 1 { return matches.first }
            let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
            let namedPrefix = "\(mediaKind)_\(participantKey)"
            return matches.first { candidate in
                (candidate.track?.trackId.lowercased() ?? "").hasPrefix(namedPrefix)
            } ?? matches.first
        }

        // A cryptor entry in the map is only "bound" if it still points at the receiver we want
        // media decrypted on. After SFU renegotiation the map can hold a cryptor attached to a
        // dead placeholder receiver while the peer's frames arrive (encrypted) on the advertised
        // receiver — createEncryptedFrame rebinds when the binding differs.
        func bindingIsCurrent(_ binding: RTCReceiverCryptorBinding?, receiver: RTCRtpReceiver) -> Bool {
            guard let binding, let track = receiver.track else { return false }
            return binding.trackId == track.trackId
                && binding.receiverId == String(describing: ObjectIdentifier(receiver))
        }

        var didBindAudio = conn.audioReceiverCryptorsByParticipantId[participantId] != nil
        var didBindVideo = conn.videoReceiverCryptorsByParticipantId[participantId] != nil
        var didBindScreen = conn.screenReceiverCryptorsByParticipantId[participantId] != nil

        let mappedAudioReceiver = advertisedReceiver(kind: kRTCMediaStreamTrackKindAudio)
            ?? receiver(matching: conn.remoteAudioTracksByParticipantId[participantId])
            ?? singleLiveReceiver(kind: kRTCMediaStreamTrackKindAudio)
        if let audioReceiver = mappedAudioReceiver,
           !didBindAudio || !bindingIsCurrent(
            conn.audioReceiverCryptorBindingsByParticipantId[participantId],
            receiver: audioReceiver
           ) {
            try await createEncryptedFrame(
                connection: conn,
                kind: .audioReceiver(audioReceiver),
                participantIdOverride: participantId)
            if let latest = await connectionManager.findConnection(with: conn.id) {
                conn = latest
            }
            if let audioTrack = audioReceiver.track as? RTCAudioTrack {
                conn.remoteAudioTracksByParticipantId[participantId] = audioTrack
            }
            didBindAudio = conn.audioReceiverCryptorsByParticipantId[participantId] != nil
        }

        let mappedVideoTrack = conn.remoteVideoTracksByParticipantId[participantId] ?? conn.remoteVideoTrack
        let mappedVideoReceiver = advertisedReceiver(kind: kRTCMediaStreamTrackKindVideo)
            ?? receiver(matching: mappedVideoTrack)
            ?? singleLiveReceiver(kind: kRTCMediaStreamTrackKindVideo)
        if let videoReceiver = mappedVideoReceiver,
           !didBindVideo || !bindingIsCurrent(
            conn.videoReceiverCryptorBindingsByParticipantId[participantId],
            receiver: videoReceiver
           ) {
            try await createEncryptedFrame(
                connection: conn,
                kind: .videoReceiver(videoReceiver),
                participantIdOverride: participantId)
            if let latest = await connectionManager.findConnection(with: conn.id) {
                conn = latest
            }
            if let videoTrack = videoReceiver.track as? RTCVideoTrack {
                conn.remoteVideoTracksByParticipantId[participantId] = videoTrack
            }
            didBindVideo = conn.videoReceiverCryptorsByParticipantId[participantId] != nil
        }

        let mappedScreenTrack = conn.remoteScreenTracksByParticipantId[participantId]
            ?? conn.remoteScreenTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key) == Self.conferenceParticipantIdentityKey(participantId)
            }?.value
        let mappedScreenReceiver = receiver(matching: mappedScreenTrack)
            ?? conn.peerConnection.receivers.first {
                guard let track = $0.track,
                      track.kind == kRTCMediaStreamTrackKindVideo,
                      track.readyState != .ended
                else { return false }
                return RTCSession.isScreenShareId(track.trackId)
            }
        if !didBindScreen,
           let screenReceiver = mappedScreenReceiver {
            try await createEncryptedFrame(
                connection: conn,
                kind: .screenReceiver(screenReceiver),
                participantIdOverride: participantId)
            if let latest = await connectionManager.findConnection(with: conn.id) {
                conn = latest
            }
            didBindScreen = conn.screenReceiverCryptorsByParticipantId[participantId] != nil
        }

        let receiverSummary = conn.peerConnection.receivers.map { receiver in
            let kind = receiver.track?.kind ?? "<nil>"
            let trackId = receiver.track?.trackId ?? "<nil>"
            return "\(kind):\(trackId)"
        }.joined(separator: ",")
        logger.log(
            level: (didBindAudio && didBindVideo) ? .info : .warning,
            message: "1:1 SFU receiver FrameCryptor bind check participantId='\(participantId)' connId=\(conn.id) audioBound=\(didBindAudio) videoBound=\(didBindVideo) screenBound=\(didBindScreen) receivers=[\(receiverSummary)]")
    }
#endif

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
            case .signalingStateDidChange(let connectionId, let stateChanged):
                self.logger.log(level: .info, message: "peerConnection new signaling state: \(stateChanged.description)")
                let norm = connectionId.normalizedConnectionId
                if self.isGroupCallConnection(norm) || self.groupCalls[norm] != nil {
                    self.noteSfuGroupSignalingStability(
                        for: connectionId,
                        isStable: stateChanged.description == "stable"
                    )
                }
            case .addedStream(_, let streamId):
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

                // SFU renegotiation can replace Android receiver objects without another
                // `didAddReceiver` callback. Re-resolve the stable 1:1 owner, refresh the track
                // map used by the call UI, and bind decryptors to the current receivers.
                if Self.isTrueOneToOneSfuRoom(call: connection.call),
                   let remoteTrackOwner = remoteTrackOwnerParticipantId(
                    connection: connection,
                    call: connection.call
                   )?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !remoteTrackOwner.isEmpty {
                    var updated = await connectionManager.findConnection(with: connection.id) ?? connection
                    if let videoTrack = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: &updated),
                       videoTrack.isLiveVideoTrack {
                        let resolvedId = videoTrack.trackIdIfAvailable
                        let cachedTrack = updated.remoteVideoTrack
                        let cachedId = cachedTrack?.isLiveVideoTrack == true ? cachedTrack?.trackIdIfAvailable : nil
                        if !Self.oneToOneSfuRemoteTrackWouldDowngradeRelayToPlaceholder(
                            previousTrackId: cachedId,
                            resolvedTrackId: resolvedId
                        ) {
                            updated.remoteVideoTrack = videoTrack
                            updated.remoteVideoTracksByParticipantId[remoteTrackOwner] = videoTrack
                        }
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                        notifyRemoteParticipantTrackChanged(
                            RemoteParticipantTrackEvent(
                                connectionId: updated.id,
                                participantId: remoteTrackOwner,
                                kind: "video",
                                isActive: true)
                        )
                    }
                    if enableEncryption,
                       oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(updated.id)),
                       let trackId = updated.remoteVideoTracksByParticipantId[remoteTrackOwner]?.trackIdIfAvailable
                        ?? updated.remoteVideoTrack?.trackIdIfAvailable {
                        rtcClient.createReceiverEncryptedFrame(
                            participant: remoteTrackOwner,
                            connectionId: updated.id,
                            trackKind: "video",
                            trackId: trackId)
                        logger.log(
                            level: .info,
                            message: "Android 1:1 SFU renegotiation: rebound current receiver FrameCryptors for participantId='\(remoteTrackOwner)' trackId=\(trackId) connId=\(updated.id)")
                    } else if enableEncryption,
                              oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(updated.id)) {
                        rtcClient.createReceiverEncryptedFrame(
                            participant: remoteTrackOwner,
                            connectionId: updated.id)
                        logger.log(
                            level: .info,
                            message: "Android 1:1 SFU renegotiation: rebound current receiver FrameCryptors for participantId='\(remoteTrackOwner)' connId=\(updated.id)")
                    }
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
                            let isOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: connection.call)
                            let cfg = sfuAdaptiveConfig(for: connection.call)
                            if encoding.maxBitrateBps == nil { encoding.maxBitrateBps = NSNumber(value: cfg.startingBitrateBps) }
                            if encoding.maxFramerate == nil { encoding.maxFramerate = NSNumber(value: cfg.startingFramerate) }
                            encoding.scaleResolutionDownBy = NSNumber(
                                value: RTCVideoQualityProfile.resolutionScaleDownBy(
                                    for: cfg.startingBitrateBps,
                                    isOneToOneSfu: isOneToOneSfu
                                )
                            )
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

                // For SFU/group calls, the first remote stream id can be UUID-like placeholder.
                // When a later renegotiation publishes a stable participant id, proactively
                // rebind receiver cryptors to that id so key lookup aligns.
                if enableEncryption,
                   isGroupCallConnection(connection.id),
                   frameEncryptionKeyMode == .perParticipant {
                    let trimmedStreamId = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (e2eeParticipantId, _, _) = receiverParticipantIdOverrideForE2EE(
                        connection: connection,
                        participantIdFromStreamIds: trimmedStreamId
                    )
                    var stableParticipantId = e2eeParticipantId ?? trimmedStreamId
                    if UUID(uuidString: stableParticipantId) != nil,
                       isGroupCallConnection(connection.id),
                       !Self.isTrueOneToOneSfuRoom(call: connection.call),
                       let relayParticipant = resolvedAppleRelayScreenShareParticipantId(
                           streamIds: [trimmedStreamId],
                           trackId: "",
                           connection: connection
                       ) ?? ambiguousRelayScreenParticipantId(in: connection) {
                        stableParticipantId = relayParticipant
                    }
                    let localParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let shouldDelayReceiverCryptorUntilReceiveKey =
                        lastFrameKeyIndexByParticipantId[stableParticipantId] == nil &&
                        (
                            Self.isTrueOneToOneSfuRoom(call: connection.call) ||
                            isGroupCallConnection(connection.id)
                        )
                    if !stableParticipantId.isEmpty,
                       UUID(uuidString: stableParticipantId) == nil,
                       stableParticipantId.caseInsensitiveCompare(localParticipantId) != .orderedSame,
                        !shouldDelayReceiverCryptorUntilReceiveKey,
                        !sfuRenegotiationReceiverCryptorRebindIsDeferred(for: connection.id) {
                        let currentConnection = await connectionManager.findConnection(with: connection.id) ?? connection
                        if appleGroupParticipantReceiverCryptorsNeedRebind(
                            connection: currentConnection,
                            participantId: stableParticipantId
                        ) {
                        do {
                            // Disable any prior UUID-aliased cryptors on the same receivers before
                            // rebinding to the stable id; otherwise libwebrtc has two cryptors on
                            // the same RTPReceiver and the alias map keeps stale entries.
                            var cleaned = clearUuidAliasedReceiverCryptors(
                                on: currentConnection,
                                keepingParticipantId: stableParticipantId
                            )
                            await connectionManager.updateConnection(id: cleaned.id, with: cleaned)

                            if let videoMatch = appleResolveLiveVideoReceiver(
                                for: stableParticipantId,
                                connection: cleaned
                            ) {
                                let videoReceiver = videoMatch.receiver
                                let videoTrack = videoMatch.track
                                if cleaned.remoteVideoTracksByParticipantId[stableParticipantId] == nil {
                                    let didClaimCameraTrack = Self.claimRemoteCameraTrack(
                                        videoTrack,
                                        participantId: stableParticipantId,
                                        in: &cleaned
                                    )
                                    if didClaimCameraTrack {
                                        cleaned.remoteVideoTrack = videoTrack
                                    }
                                    await connectionManager.updateConnection(id: cleaned.id, with: cleaned)
                                    if didClaimCameraTrack {
                                        notifyRemoteParticipantTrackChanged(
                                            RemoteParticipantTrackEvent(connectionId: cleaned.id, participantId: stableParticipantId, kind: "video", isActive: true)
                                        )
                                    } else {
                                        logger.log(
                                            level: .warning,
                                            message: "Rejected duplicate stable camera receiver claim during cryptor rebind participant=\(stableParticipantId) trackId=\(videoTrack.trackId) connection=\(cleaned.id)"
                                        )
                                    }
                                }
                                try await self.createEncryptedFrame(
                                    connection: cleaned,
                                    kind: .videoReceiver(videoReceiver),
                                    participantIdOverride: stableParticipantId
                                )
                            }
                            if let audioMatch = appleResolveLiveAudioReceiver(
                                for: stableParticipantId,
                                connection: cleaned
                            ) {
                                let audioReceiver = audioMatch.receiver
                                let audioTrack = audioMatch.track
                                if cleaned.remoteAudioTracksByParticipantId[stableParticipantId] == nil {
                                    cleaned.remoteAudioTracksByParticipantId[stableParticipantId] = audioTrack
                                    await connectionManager.updateConnection(id: cleaned.id, with: cleaned)
                                    if let mediaDelegate {
                                        await mediaDelegate.didAddRemoteTrack(
                                            connectionId: cleaned.id,
                                            participantId: stableParticipantId,
                                            kind: "audio",
                                            trackId: audioTrack.trackId)
                                    }
                                }
                                try await self.createEncryptedFrame(
                                    connection: cleaned,
                                    kind: .audioReceiver(audioReceiver),
                                    participantIdOverride: stableParticipantId
                                )
                            }
                            logger.log(level: .info, message: "Rebound SFU receiver FrameCryptors to stable participantId='\(stableParticipantId)' for connection=\(connection.id)")
                        } catch {
                            logger.log(level: .error, message: "Failed to rebind SFU receiver FrameCryptors for participantId='\(stableParticipantId)': \(error)")
                        }
                        }
                    } else if shouldDelayReceiverCryptorUntilReceiveKey {
                        let scope = isGroupCallConnection(connection.id) ? "group/conference SFU" : "1:1 SFU"
                        logger.log(
                            level: .info,
                            message: "\(scope) receive-key guard: delaying stable receiver FrameCryptor rebind until receive key is installed participantId='\(stableParticipantId)' connId=\(connection.id)")
                    }
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
                        updated.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                    }
                    notifyRemoteScreenTrackChanged(
                        RemoteScreenTrackEvent(connectionId: connection.id, participantId: participantId, isActive: false)
                    )
                } else {
                    let rawParticipantId = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let participantId = isGroupCallConnection(connection.id)
                        ? (normalizedRemoteParticipantIdFromSfuStreamLabel(rawParticipantId, connection: connection) ?? rawParticipantId)
                        : rawParticipantId
                    if !participantId.isEmpty {
                        if var updated = await connectionManager.findConnection(with: connection.id) {
                            updated.remoteAudioTracksByParticipantId.removeValue(forKey: participantId)
                            if let cryptor = updated.audioReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                                cryptor.enabled = false
                                cryptor.delegate = nil
                                if updated.audioFrameCryptor === cryptor {
                                    updated.audioFrameCryptor = nil
                                }
                            }
                            updated.audioReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
                            updated.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
                            if let cryptor = updated.videoReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                                cryptor.enabled = false
                                cryptor.delegate = nil
                                if updated.videoFrameCryptor === cryptor {
                                    updated.videoFrameCryptor = nil
                                }
                            }
                            updated.videoReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
                            await connectionManager.updateConnection(id: updated.id, with: updated)
                        }
                        if shouldSurfaceRemoteParticipantCameraTrack(connection: connection, participantId: participantId) {
                            notifyRemoteParticipantTrackChanged(
                                RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
                            )
                        }
                    }
                }
#elseif os(Android)
                let rawParticipantId = RTCSession.participantIdFromScreenShareId(streamId) ?? streamId
                let participantId = isGroupCallConnection(connection.id)
                    ? (androidNormalizedRemoteParticipantIdFromSfuStreamLabel(rawParticipantId, connection: connection) ?? rawParticipantId)
                    : rawParticipantId
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
                    if shouldSurfaceRemoteParticipantCameraTrack(connection: connection, participantId: participantId) {
                        notifyRemoteParticipantTrackChanged(
                            RemoteParticipantTrackEvent(connectionId: connection.id, participantId: participantId, kind: "video", isActive: false)
                        )
                    }
                }
#endif
            case .didAddReceiver(_, let trackKind, let streamIds, let trackId):
                self.logger.log(level: .info, message: "peerConnection did add receiver kind=\(trackKind) trackId=\(trackId) streamIds=\(streamIds)")
                // Convention for SFU-style calls: streamId identifies the remote participant.
                // If your SFU uses a different mapping, configure `setRemoteParticipantIdResolver`.
                let participantId = remoteParticipantIdResolver?(streamIds, trackId, trackKind) ?? (streamIds.first ?? "")
#if os(Android)
                    let androidRenegotiationNormId = connection.id.normalizedConnectionId
                    if isGroupCallConnection(connection.id),
                       sfuRenegotiationInFlightConnectionIds.contains(androidRenegotiationNormId) {
                        logger.log(
                            level: .info,
                            message: "Deferring Android didAddReceiver until setRemoteSDP completes kind=\(trackKind) trackId=\(trackId) connection=\(connection.id)"
                        )
                        continue
                    }
                    let isScreenTrack = RTCSession.isScreenShareId(trackId) || streamIds.contains(where: { RTCSession.isScreenShareId($0) })
                    let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: connection.call)
                    let oneToOneRemoteTrackOwner = isOneToOneSfuRoom
                        ? remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                    let androidResolvedMediaParticipantId: String = {
                        guard self.isGroupCallConnection(connection.id) else {
                            return participantId
                        }
                        for label in streamIds + [trackId, participantId] {
                            if let normalized = androidNormalizedRemoteParticipantIdFromSfuStreamLabel(
                                label,
                                connection: connection
                            ) {
                                return normalized
                            }
                        }
                        return participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                    }()
                    var androidDelegateParticipantId = androidResolvedMediaParticipantId

                    if trackKind == "video" {
                        var updated = connection
                        if isScreenTrack {
                            let fallbackScreenParticipant = participantId.isEmpty ? connection.id : participantId
                            let resolvedScreenParticipant = RTCSession.resolvedScreenShareParticipantId(
                                streamIds: streamIds,
                                trackId: trackId,
                                fallback: fallbackScreenParticipant
                            )
                            androidDelegateParticipantId = resolvedScreenParticipant
                            let screenTrack = rtcClient.getRemoteScreenVideoTrackById(peerConnection: connection.peerConnection, trackId: trackId)
                                ?? rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection)
                            if let screenTrack {
                                updated.remoteScreenTrack = screenTrack
                                updated.remoteScreenTracksByParticipantId[resolvedScreenParticipant] = screenTrack
                                await connectionManager.updateConnection(id: updated.id, with: updated)
                            }
                        } else {
                            let videoTrack = rtcClient.getRemoteVideoTrackById(peerConnection: connection.peerConnection, trackId: trackId)
                            if let videoTrack {
                                let resolvedParticipant: String
                                if let oneToOneRemoteTrackOwner,
                                   !oneToOneRemoteTrackOwner.isEmpty {
                                    resolvedParticipant = oneToOneRemoteTrackOwner
                                } else if self.isGroupCallConnection(connection.id) {
                                    let trimmedParticipant = androidResolvedMediaParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmedParticipant.isEmpty else {
                                        logger.log(
                                            level: .warning,
                                            message: "Ignoring Android group camera receiver with empty participant id trackId=\(trackId) streamIds=\(streamIds)"
                                        )
                                        break
                                    }
                                    resolvedParticipant = trimmedParticipant
                                } else {
                                    resolvedParticipant = participantId.isEmpty
                                        ? (connection.remoteParticipantId.isEmpty ? connection.id : connection.remoteParticipantId)
                                        : participantId
                                }
                                androidDelegateParticipantId = resolvedParticipant
                                if shouldSurfaceRemoteParticipantCameraTrack(connection: connection, participantId: resolvedParticipant) {
                                    let claimSucceeded: Bool
                                    if self.isGroupCallConnection(connection.id) {
                                        claimSucceeded = Self.claimRemoteCameraTrack(
                                            videoTrack,
                                            participantId: resolvedParticipant,
                                            in: &updated
                                        )
                                    } else {
                                        if !resolvedParticipant.isEmpty {
                                            updated.remoteVideoTracksByParticipantId[resolvedParticipant] = videoTrack
                                        }
                                        claimSucceeded = true
                                    }
                                    guard claimSucceeded else {
                                        await connectionManager.updateConnection(id: updated.id, with: updated)
                                        logger.log(
                                            level: .warning,
                                            message: "Rejected duplicate Android remote camera receiver claim participant=\(resolvedParticipant) trackId=\(trackId) connection=\(connection.id)"
                                        )
                                        break
                                    }
                                    if !self.isGroupCallConnection(connection.id) || updated.remoteVideoTracksByParticipantId.count <= 1 {
                                        updated.remoteVideoTrack = videoTrack
                                    }
                                    await connectionManager.updateConnection(id: updated.id, with: updated)

                                    if let pendingRenderer = pendingRemoteVideoRenderersByConnectionId[updated.id.normalizedConnectionId] as? AndroidSampleCaptureView {
                                        let normalizedConnectionId = updated.id.normalizedConnectionId
                                        let receiveKeyReady = oneToOneSfuReceiveKeyReadyConnectionIds.contains(
                                            teardownConnectionIdKey(normalizedConnectionId))
                                        if Self.isTrueOneToOneSfuRoom(call: updated.call),
                                           Self.shouldDeferOneToOneSfuRemoteRendererAttach(
                                            isOneToOneSfuRoom: true,
                                            frameEncryptionEnabled: enableEncryption,
                                            receiveKeyReady: receiveKeyReady
                                           ) {
                                            logger.log(
                                                level: .info,
                                                message: "Deferring buffered remote renderer for 1:1 call until receive key is installed (trackId=\(trackId))"
                                            )
                                        } else if Self.isTrueOneToOneSfuRoom(call: updated.call),
                                                  sfuRenegotiationReceiverCryptorRebindIsDeferred(for: updated.id) {
                                            logger.log(
                                                level: .info,
                                                message: "Deferring buffered remote renderer for 1:1 call until SFU renegotiation answer completes (trackId=\(trackId))"
                                            )
                                        } else {
                                            logger.log(level: .info, message: "Attaching buffered remote renderer for 1:1 call (trackId=\(trackId))")
                                            _ = pendingRenderer.attach(videoTrack)
                                            pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedConnectionId)
                                        }
                                    }

                                    notifyRemoteParticipantTrackChanged(
                                        RemoteParticipantTrackEvent(connectionId: connection.id, participantId: resolvedParticipant, kind: "video", isActive: true)
                                    )
                                }
                            }
                        }
                    }

                    let reportedKind = isScreenTrack ? "screen" : trackKind
                    if isScreenTrack {
                        let fallbackScreenParticipant = participantId.isEmpty ? connection.id : participantId
                        let resolvedScreenParticipant = RTCSession.resolvedScreenShareParticipantId(
                            streamIds: streamIds,
                            trackId: trackId,
                            fallback: fallbackScreenParticipant
                        )
                        notifyRemoteScreenTrackChanged(
                            RemoteScreenTrackEvent(connectionId: connection.id, participantId: resolvedScreenParticipant, isActive: true)
                        )
                    }
                    if let mediaDelegate, !androidDelegateParticipantId.isEmpty {
                        await mediaDelegate.didAddRemoteTrack(connectionId: connection.id, participantId: androidDelegateParticipantId, kind: reportedKind, trackId: trackId)
                    }

                    let receiverParticipantId: String
                    let shouldSkipAndroidGroupReceiverCryptor: Bool
                    if let remoteTrackOwner = oneToOneRemoteTrackOwner,
                       !remoteTrackOwner.isEmpty {
                        receiverParticipantId = remoteTrackOwner
                        shouldSkipAndroidGroupReceiverCryptor = false
                    } else if self.isGroupCallConnection(connection.id) {
                        let groupParticipant = (isScreenTrack ? androidDelegateParticipantId : androidResolvedMediaParticipantId)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        receiverParticipantId = groupParticipant
                        shouldSkipAndroidGroupReceiverCryptor =
                            groupParticipant.isEmpty
                            || shouldSkipGroupReceiverFrameCryptor(
                                connection: connection,
                                participantIdOverride: groupParticipant
                            )
                            || shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                                connection: connection,
                                participantIdOverride: groupParticipant
                            )
                    } else {
                        receiverParticipantId = connection.remoteParticipantId
                        shouldSkipAndroidGroupReceiverCryptor = false
                    }

                    let shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey =
                        enableEncryption &&
                        self.frameEncryptionKeyMode == .perParticipant &&
                        isOneToOneSfuRoom &&
                        !oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(connection.id))
                    let receiverTrackKind = isScreenTrack ? "screen" : trackKind

                    if shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey {
                        self.logger.log(
                            level: .info,
                            message: "Android 1:1 SFU receive-key guard: delaying \(receiverTrackKind) receiver FrameCryptor until receive key is installed participantId='\(receiverParticipantId)' connId=\(connection.id)")
                    } else if shouldSkipAndroidGroupReceiverCryptor {
                        self.logger.log(
                            level: .info,
                            message: "Skipping Android group \(receiverTrackKind) receiver FrameCryptor until stable participant id is known trackId=\(trackId) participantId='\(receiverParticipantId)' connId=\(connection.id)"
                        )
                    } else if enableEncryption, !receiverParticipantId.isEmpty {
                        rtcClient.createReceiverEncryptedFrame(
                            participant: receiverParticipantId,
                            connectionId: connection.id,
                            trackKind: receiverTrackKind,
                            trackId: trackId
                        )
                    }
#elseif canImport(WebRTC)
                do {
                    await tryCompleteAppleDeferredReceivingMessageKey(connectionId: connection.id)

                    var isScreenTrack = RTCSession.isScreenShareId(trackId) || streamIds.contains(where: { RTCSession.isScreenShareId($0) })
                    if !isScreenTrack,
                       trackKind == kRTCMediaStreamTrackKindVideo,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let transceiver = appleTransceiver(for: receiver, in: connection.peerConnection) {
                        isScreenTrack = shouldTreatAppleVideoTrackAsRemoteScreenShare(
                            trackId: trackId,
                            streamIds: streamIds,
                            transceiver: transceiver,
                            connection: connection
                        )
                    }
                    if !isScreenTrack,
                       trackKind == kRTCMediaStreamTrackKindVideo,
                       isGroupCallConnection(connection.id),
                       Self.isTrueOneToOneSfuRoom(call: connection.call),
                       let latestConnection = await connectionManager.findConnection(with: connection.id) {
                        let stableParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                        // A receiver whose msid stream is the participant's *plain* id is that
                        // participant's camera (screen legs advertise `screen_<participant>`).
                        // SFU renegotiation republished cameras arrive with a new trackId while the
                        // stale camera mapping is still present — that must never flip to screen.
                        let carriesPlainCameraStreamId = streamIds.contains {
                            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !trimmed.isEmpty
                                && Self.conferenceParticipantIdentityKey(trimmed)
                                    == Self.conferenceParticipantIdentityKey(stableParticipantId)
                        }
                        if !stableParticipantId.isEmpty,
                           Self.isPlausibleConferenceScreenShareParticipantId(stableParticipantId),
                           !carriesPlainCameraStreamId,
                           let existingCamera = latestConnection.remoteVideoTracksByParticipantId[stableParticipantId],
                           existingCamera.trackId != trackId {
                            // True 1:1 SFU relay SDP can lose the original `screen_` msid. Multi-party
                            // rooms add one camera video receiver per participant, so they must not use
                            // this receiver-count heuristic.
                            isScreenTrack = true
                        } else if UUID(uuidString: stableParticipantId) != nil,
                                  let relayParticipant = ambiguousRelayScreenParticipantId(in: latestConnection),
                                  !streamIds.contains(where: {
                                      Self.conferenceParticipantIdentityKey($0.trimmingCharacters(in: .whitespacesAndNewlines))
                                          == Self.conferenceParticipantIdentityKey(relayParticipant)
                                  }),
                                  let existingCamera = latestConnection.remoteVideoTracksByParticipantId[relayParticipant],
                                  existingCamera.trackId != trackId {
                            isScreenTrack = true
                        }
                    }

                    if trackKind == kRTCMediaStreamTrackKindVideo, isScreenTrack {
                        let streamFallback = participantId.isEmpty ? connection.id : participantId
                        let relayFallback = ambiguousRelayScreenParticipantId(in: connection) ?? streamFallback
                        let resolvedScreenParticipant = resolvedAppleRemoteScreenParticipantId(
                            streamIds: streamIds,
                            trackId: trackId,
                            fallback: relayFallback,
                            connection: connection
                        )
                        if !Self.isPlausibleConferenceScreenShareParticipantId(resolvedScreenParticipant) {
                            self.logger.log(
                                level: .info,
                                message: "Ignoring remote screen-share receiver with unresolved SFU placeholder participant trackId=\(trackId) streamIds=\(streamIds)"
                            )
                            isScreenTrack = false
                        }
                    }

                    if trackKind == kRTCMediaStreamTrackKindVideo, isScreenTrack,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let videoTrack = receiver.track as? WebRTC.RTCVideoTrack {
                        var updated = connection
                        let streamFallback = participantId.isEmpty ? connection.id : participantId
                        let relayFallback = ambiguousRelayScreenParticipantId(in: updated) ?? streamFallback
                        let resolvedScreenParticipant = resolvedAppleRemoteScreenParticipantId(
                            streamIds: streamIds,
                            trackId: trackId,
                            fallback: relayFallback,
                            connection: connection
                        )
                        let mappedKey = Self.conferenceParticipantIdentityKey(resolvedScreenParticipant)
                        let activeScreenKeys = Set(
                            sdpAdvertisedActiveRemoteScreenShareParticipantIds(connection: updated)
                                .map { Self.conferenceParticipantIdentityKey($0) }
                                .filter { !$0.isEmpty }
                        )
                        if !mappedKey.isEmpty,
                           updated.suppressedRemoteScreenShareParticipantIds.contains(mappedKey),
                           !activeScreenKeys.contains(mappedKey) {
                            logger.log(
                                level: .warning,
                                message: "Ignoring stale remote screen-share receiver after authoritative stop participant=\(resolvedScreenParticipant) trackId=\(trackId) connection=\(updated.id)"
                            )
                        } else {
                            updated.remoteScreenTracksByParticipantId[resolvedScreenParticipant] = videoTrack
                            if !mappedKey.isEmpty {
                                updated.suppressedRemoteScreenShareParticipantIds.remove(mappedKey)
                            }
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
                                    participantIdFromStreamIds: resolvedScreenParticipant
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
                        }
                    } else if trackKind == kRTCMediaStreamTrackKindVideo, !isScreenTrack,
                       let receiver = connection.peerConnection.receivers.first(where: { $0.track?.trackId == trackId }),
                       let videoTrack = receiver.track as? WebRTC.RTCVideoTrack {
                        var updated = connection
                        let cameraParticipantId: String = {
                            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                if isGroupCallConnection(connection.id),
                                   let normalized = normalizedRemoteParticipantIdFromSfuStreamLabel(trimmed, connection: connection) {
                                    return normalized
                                }
                                return trimmed
                            }
                            guard !isGroupCallConnection(connection.id) || Self.isTrueOneToOneSfuRoom(call: connection.call) else {
                                return trimmed
                            }
                            if let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                               !owner.isEmpty {
                                return owner
                            }
                            let remote = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !remote.isEmpty {
                                return remote
                            }
                            return trimmed
                        }()
                        let shouldSurfaceCameraTrack = shouldSurfaceRemoteParticipantCameraTrack(
                            connection: connection,
                            participantId: cameraParticipantId
                        )
                        let shouldStoreLegacyRemoteTrack = !isGroupCallConnection(connection.id) || shouldSurfaceCameraTrack
                        let advertisedCameraOwner = (connection.peerConnection.remoteDescription?.sdp)
                            .flatMap { Self.advertisedRemoteCameraOwnersByTrackId(in: $0)[videoTrack.trackId] }
                        let allowCameraOwnershipTransfer = advertisedCameraOwner == Self.conferenceParticipantIdentityKey(cameraParticipantId)
                        let didClaimCameraTrack = shouldSurfaceCameraTrack
                            ? Self.claimRemoteCameraTrack(
                                videoTrack,
                                participantId: cameraParticipantId,
                                in: &updated,
                                allowReplacingExistingStableOwner: allowCameraOwnershipTransfer
                            )
                            : false
                        if shouldSurfaceCameraTrack, !didClaimCameraTrack {
                            logger.log(
                                level: .warning,
                                message: "Rejected duplicate remote camera receiver claim connection=\(updated.id.normalizedConnectionId) trackId=\(trackId) participantId=\(cameraParticipantId)"
                            )
                        }
                        if shouldStoreLegacyRemoteTrack && (!shouldSurfaceCameraTrack || didClaimCameraTrack) {
                            updated.remoteVideoTrack = videoTrack
                        }
                        await connectionManager.updateConnection(id: updated.id, with: updated)

                        let normalizedConnectionId = updated.id.normalizedConnectionId
                        let hasPendingRenderer = pendingRemoteVideoRenderersByConnectionId[normalizedConnectionId] != nil
                        logger.log(
                            level: .info,
                            message: "Stored remote camera receiver connection=\(normalizedConnectionId) trackId=\(trackId) participantId=\(cameraParticipantId) shouldSurface=\(shouldSurfaceCameraTrack) shouldStoreLegacy=\(shouldStoreLegacyRemoteTrack) hasPendingRenderer=\(hasPendingRenderer) media=\(RTCPeerConnectionMediaDiagnostics.summary(updated.peerConnection))"
                        )
                        if shouldStoreLegacyRemoteTrack && (!shouldSurfaceCameraTrack || didClaimCameraTrack),
                           let pendingRenderer = pendingRemoteVideoRenderersByConnectionId[normalizedConnectionId] {
                            let receiveKeyReady = oneToOneSfuReceiveKeyReadyConnectionIds.contains(
                                teardownConnectionIdKey(normalizedConnectionId))
                            if Self.shouldDeferOneToOneSfuRemoteRendererAttach(
                                isOneToOneSfuRoom: Self.isTrueOneToOneSfuRoom(call: updated.call),
                                frameEncryptionEnabled: enableEncryption,
                                receiveKeyReady: receiveKeyReady
                            ) {
                                logger.log(
                                    level: .info,
                                    message: "Deferring remote renderer rebind until 1:1 SFU receive key is installed (trackId=\(trackId))"
                                )
                            } else if sfuRenegotiationReceiverCryptorRebindIsDeferred(for: updated.id) {
                                logger.log(
                                    level: .info,
                                    message: "Deferring remote renderer rebind until SFU renegotiation answer completes (trackId=\(trackId))"
                                )
                            } else {
                                logger.log(level: .info, message: "Rebinding remote renderer now that remote video track is available (trackId=\(trackId))")
                                connection.remoteVideoTrack?.remove(pendingRenderer)
                                videoTrack.add(pendingRenderer)
                                pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedConnectionId)
                                logRtpStatsSnapshotOnce(
                                    connectionId: normalizedConnectionId,
                                    delayNanoseconds: 2_000_000_000,
                                    reason: "afterDidAddReceiverAttachRemoteRenderer"
                                )
                                startInboundVideoFlowProbe(connectionId: normalizedConnectionId)
                            }
                        }

                        if shouldSurfaceCameraTrack && didClaimCameraTrack {
                            notifyRemoteParticipantTrackChanged(
                                RemoteParticipantTrackEvent(connectionId: updated.id, participantId: cameraParticipantId, kind: "video", isActive: true)
                            )
                        }

                        if let mediaDelegate, shouldSurfaceCameraTrack && didClaimCameraTrack {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: cameraParticipantId, kind: "video", trackId: trackId)
                        }

                        // Determine the correct participant ID for the receiver cryptor:
                        // - For group calls: use participantId from streamIds (identifies the track owner)
                        // - For 1:1 calls in perParticipant mode: use connection.remoteParticipantId (matches the key that was set)
                        let resolved = receiverParticipantIdOverrideForE2EE(
                            connection: connection,
                            participantIdFromStreamIds: participantId)

                        let receiverParticipantId = resolved.override
                        if enableEncryption, resolved.didOverrideToRemote {
                            if resolved.isUuidLikeStreamRemap {
                                self.logger.log(
                                    level: .warning,
                                    message: "SFU streamId '\(participantId)' is UUID-shaped in 1:1 room; overriding receiver participantId -> '\(receiverParticipantId ?? "?")' for E2EE key alignment"
                                )
                            } else {
                                self.logger.log(
                                    level: .info,
                                    message: "SFU recv label '\(participantId)' remapped for E2EE (e.g. msid `peer_` vs frame key `peer') -> '\(receiverParticipantId ?? "?")'"
                                )
                            }
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
                                    message: "No frame key provisioned for resolvedParticipantId=\(resolved) yet. If SFU uses streamId UUIDs, expect FrameCryptor missingKey until keys are injected for that exact participantId (or resolver maps to real participant ids).")
                            }
                        }
                        let shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey =
                            enableEncryption &&
                            self.frameEncryptionKeyMode == .perParticipant &&
                            Self.isTrueOneToOneSfuRoom(call: updated.call) &&
                            receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] } == nil
                        if enableEncryption {
                            if shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey {
                                self.logger.log(
                                    level: .info,
                                    message: "1:1 SFU receive-key guard: delaying video receiver FrameCryptor until receive key is installed participantId='\(receiverParticipantId ?? "<nil>")' connId=\(updated.id)")
                            } else if !shouldSkipGroupReceiverFrameCryptor(
                                connection: updated,
                                participantIdOverride: receiverParticipantId),
                               !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                try await self.createEncryptedFrame(
                                    connection: updated,
                                    kind: .videoReceiver(receiver),
                                    participantIdOverride: receiverParticipantId)
                            } else if shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                let aliasProvisioned = await self.tryProvisionUuidAliasFrameKeyIfPossible(
                                    for: receiverParticipantId ?? "",
                                    connection: updated
                                )
                                if aliasProvisioned {
                                    try await self.createEncryptedFrame(
                                        connection: updated,
                                        kind: .videoReceiver(receiver),
                                        participantIdOverride: receiverParticipantId
                                    )
                                    self.logger.log(
                                        level: .info,
                                        message: "Bound video receiver FrameCryptor immediately using UUID alias participantId='\(receiverParticipantId ?? "<nil>")' pending stable SFU id."
                                    )
                                } else {
                                    self.logger.log(
                                        level: .warning,
                                        message: "Delaying video receiver FrameCryptor bind for UUID-like participantId='\(receiverParticipantId ?? "<nil>")' until stable SFU participant id arrives."
                                    )
                                }
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
                        let audioParticipantId: String = {
                            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                if isGroupCallConnection(connection.id),
                                   let normalized = normalizedRemoteParticipantIdFromSfuStreamLabel(trimmed, connection: connection) {
                                    return normalized
                                }
                                return trimmed
                            }
                            guard !isGroupCallConnection(connection.id) || Self.isTrueOneToOneSfuRoom(call: connection.call) else {
                                return trimmed
                            }
                            if let owner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                               !owner.isEmpty {
                                return owner
                            }
                            let remote = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !remote.isEmpty {
                                return remote
                            }
                            return trimmed
                        }()
                        if !audioParticipantId.isEmpty {
                            if let prior = updated.remoteAudioTracksByParticipantId[audioParticipantId],
                               prior !== audioTrack,
                               prior.readyState != .ended {
                                prior.isEnabled = false
                            }
                            updated.remoteAudioTracksByParticipantId[audioParticipantId] = audioTrack
                        }
                        if !audioParticipantId.isEmpty {
                            syncAppleRemoteSfuAudioTrackPlayback(
                                connection: updated,
                                participantId: audioParticipantId,
                                track: audioTrack
                            )
                        }
                        let activeAudioTrackIds = Set(updated.remoteAudioTracksByParticipantId.values.map(\.trackId))
                        _ = disableSupersededAppleInboundAudioReceivers(
                            connection: &updated,
                            keepingActiveTrackIds: activeAudioTrackIds
                        )
                        await connectionManager.updateConnection(id: updated.id, with: updated)

                        if let mediaDelegate, !audioParticipantId.isEmpty {
                            await mediaDelegate.didAddRemoteTrack(connectionId: updated.id, participantId: audioParticipantId, kind: "audio", trackId: trackId)
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
                            if resolved.isUuidLikeStreamRemap {
                                self.logger.log(
                                    level: .warning,
                                    message: "SFU streamId '\(participantId)' is UUID-shaped in 1:1 room; overriding receiver participantId -> '\(receiverParticipantId ?? "?")' for E2EE key alignment")
                            } else {
                                self.logger.log(
                                    level: .info,
                                    message: "SFU recv label '\(participantId)' remapped for E2EE (e.g. msid `peer_` vs frame key `peer') -> '\(receiverParticipantId ?? "?")'")
                            }
                        }

                        // Diagnostics: prove which participantId we bind the receiver FrameCryptor to,
                        // and whether we've ever provisioned a frame key for that participant id.
                        if enableEncryption {
                            let isGroup = self.isGroupCallConnection(connection.id)
                            let resolved = receiverParticipantId ?? "<nil>"
                            let lastIdx = receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] }
                            self.logger.log(
                                level: .debug,
                                message: "🔎 E2EE receiver mapping (audio): connId=\(updated.id) isGroup=\(isGroup) frameKeyMode=\(self.frameEncryptionKeyMode) streamIds=\(streamIds) resolvedParticipantId=\(resolved) connection.remoteParticipantId=\(connection.remoteParticipantId) lastProvisionedKeyIndex=\(lastIdx.map(String.init) ?? "<none>")")
                            if isGroup,
                               self.frameEncryptionKeyMode == .perParticipant,
                               receiverParticipantId != nil,
                               lastIdx == nil,
                               UUID(uuidString: participantId) != nil {
                                self.logger.log(
                                    level: .warning,
                                    message: "No frame key provisioned for resolvedParticipantId=\(resolved) yet. If SFU uses streamId UUIDs, expect FrameCryptor missingKey until keys are injected for that exact participantId (or resolver maps to real participant ids).")
                            }
                        }
                        let shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey =
                            enableEncryption &&
                            self.frameEncryptionKeyMode == .perParticipant &&
                            Self.isTrueOneToOneSfuRoom(call: updated.call) &&
                            receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] } == nil
                        if enableEncryption {
                            if shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey {
                                self.logger.log(
                                    level: .info,
                                    message: "1:1 SFU receive-key guard: delaying audio receiver FrameCryptor until receive key is installed participantId='\(receiverParticipantId ?? "<nil>")' connId=\(updated.id)")
                            } else if !shouldSkipGroupReceiverFrameCryptor(
                                connection: updated,
                                participantIdOverride: receiverParticipantId),
                               !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                try await self.createEncryptedFrame(
                                    connection: updated,
                                    kind: .audioReceiver(receiver),
                                    participantIdOverride: receiverParticipantId)
                            } else if shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                                connection: updated,
                                participantIdOverride: receiverParticipantId) {
                                let aliasProvisioned = await self.tryProvisionUuidAliasFrameKeyIfPossible(
                                    for: receiverParticipantId ?? "",
                                    connection: updated
                                )
                                if aliasProvisioned {
                                    try await self.createEncryptedFrame(
                                        connection: updated,
                                        kind: .audioReceiver(receiver),
                                        participantIdOverride: receiverParticipantId
                                    )
                                    self.logger.log(
                                        level: .info,
                                        message: "Bound audio receiver FrameCryptor immediately using UUID alias participantId='\(receiverParticipantId ?? "<nil>")' pending stable SFU id."
                                    )
                                } else {
                                    self.logger.log(
                                        level: .warning,
                                        message: "Delaying audio receiver FrameCryptor bind for UUID-like participantId='\(receiverParticipantId ?? "<nil>")' until stable SFU participant id arrives."
                                    )
                                }
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
                if newState.state == .connected {
                    let callDirection = await self.callState.callDirection
                        ?? self.inferredCallDirection(for: connection.call)
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
                        rtcClient.startLocalVideoCaptureIfNeeded()
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
#if os(Android)
                    if connection.call.supportsVideo {
                        rtcClient.startLocalVideoCaptureIfNeeded()
                        await startAdaptiveVideoSendIfNeeded(connectionId: connection.id)
                    }
#endif
                    let callDirection = await self.callState.callDirection
                        ?? self.inferredCallDirection(for: connection.call)
                    let current = await self.callState.currentState
                    if case .connecting = current {
                        await self.callState.transition(
                            to: .connected(
                                callDirection,
                                connection.call))
                    } else if case .ready = current {
                        // If `setConnectingIfReady` could not run (e.g. state not `.ready` yet) but
                        // the native stack still reaches ICE connected, advance so the UI is not
                        // stuck in "connecting" forever.
                        await self.callState.transition(
                            to: .connected(
                                callDirection,
                                connection.call))
                    }
#if canImport(WebRTC) && !os(Android)
                    await reconcileDeferredAppleRemoteScreenTracksIfNeeded(connectionId: connection.id)
#endif
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
#if os(Android)
                if trackKind == "removed_video" {
                    await handleAndroidRemoteVideoTrackRemoved(connectionId: connection.id)
                    continue
                }
#endif
#if canImport(WebRTC)
                do {
#if !os(Android)
                    if trackKind == "video", isGroupCallConnection(connection.id) {
                        await reconcileDeferredAppleRemoteScreenTracksIfNeeded(connectionId: connection.id)
                    }
#endif
                    await tryCompleteAppleDeferredReceivingMessageKey(connectionId: connection.id)
                    if enableEncryption,
                       self.frameEncryptionKeyMode == .perParticipant,
                       Self.isTrueOneToOneSfuRoom(call: connection.call) {
                        self.logger.log(
                            level: .debug,
                            message: "Skipping startedReceiving receiver FrameCryptor bind for encrypted 1:1 SFU; waiting for exact receiver track/key binding connId=\(connection.id) kind=\(trackKind)")
                        continue
                    }

                    // Determine the correct participant ID for receiver cryptors:
                    // - For group calls: participantIdOverride will be set in didAddReceiver
                    // - For 1:1 calls in perParticipant mode: use remoteParticipantId to match the key
                    let receiverParticipantId: String?
                    if self.isGroupCallConnection(connection.id) {
                        // Group call: participantId must come from didAddReceiver/addStream mapping.
                        // Avoid binding receiver cryptors here to room-id / placeholder ids.
                        if trackKind == "audio" {
                            suppressUnboundAppleRemoteSfuAudioReceivers(connection)
                        }
                        continue
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
                        let shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey =
                            enableEncryption &&
                            self.frameEncryptionKeyMode == .perParticipant &&
                            Self.isTrueOneToOneSfuRoom(call: connection.call) &&
                            receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] } == nil
                        if enableEncryption,
                           !shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey,
                           !shouldSkipGroupReceiverFrameCryptor(
                            connection: connection,
                            participantIdOverride: receiverParticipantId) {
                            try await self.createEncryptedFrame(connection: connection, kind: .videoReceiver(videoReceiver), participantIdOverride: receiverParticipantId)
                        } else if shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey {
                            self.logger.log(
                                level: .info,
                                message: "1:1 SFU receive-key guard: delaying startedReceiving video FrameCryptor until receive key is installed participantId='\(receiverParticipantId ?? "<nil>")' connId=\(connection.id)")
                        }
                    }
                    if trackKind == "audio", let audioReceiver = connection.peerConnection.transceivers.first(where: { $0.mediaType == .audio })?.receiver {
                        let shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey =
                            enableEncryption &&
                            self.frameEncryptionKeyMode == .perParticipant &&
                            Self.isTrueOneToOneSfuRoom(call: connection.call) &&
                            receiverParticipantId.flatMap { self.lastFrameKeyIndexByParticipantId[$0] } == nil
                        if enableEncryption,
                           !shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey,
                           !shouldSkipGroupReceiverFrameCryptor(
                            connection: connection,
                            participantIdOverride: receiverParticipantId) {
                            try await self.createEncryptedFrame(connection: connection, kind: .audioReceiver(audioReceiver), participantIdOverride: receiverParticipantId)
                        } else if shouldDelayOneToOneSfuReceiverCryptorUntilReceiveKey {
                            self.logger.log(
                                level: .info,
                                message: "1:1 SFU receive-key guard: delaying startedReceiving audio FrameCryptor until receive key is installed participantId='\(receiverParticipantId ?? "<nil>")' connId=\(connection.id)")
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
                let normId = teardownConnectionIdKey(connection.id)
                let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: connection.call)
                if pendingInitialSfuGroupOfferConnectionIds.contains(normId) {
                    self.logger.log(
                        level: .debug,
                        message: "Skipping shouldNegotiate SFU offer during initial group bootstrap for connection=\(connection.id)")
                } else if isOneToOneSfuRoom {
                    // 1:1-over-SFU behaves like direct 1:1 signaling role-wise. Auto-offering here
                    // causes glare when the answerer has already decided not to offer.
                    self.logger.log(
                        level: .debug,
                        message: "Ignoring shouldNegotiate SFU auto-offer for 1:1 room connection=\(connection.id)")
                } else if isGroupCallConnection(connection.id) {
                    // Group/conference SFU offers are explicit:
                    // - initial media starts in beginGroupCallMediaAfterSfuRegistrationIfNeeded
                    // - local screen-share changes call sendGroupCallOffer directly
                    // - remote/new-track changes are server-offer driven
                    //
                    // WebRTC also emits negotiationNeeded after applying SFU offers. Sending a
                    // client offer from this callback creates offer glare on rejoin and can reflect
                    // already-forwarded remote tracks back to the SFU as new local source tracks.
                    self.logger.log(
                        level: .debug,
                        message: "Ignoring automatic shouldNegotiate for SFU group/conference connection=\(connection.id); SFU offers are explicit/server-driven")
                } else {
                    self.logger.log(level: .debug, message: "Ignoring shouldNegotiate for non-group connection=\(connection.id)")
                }
            }
        }
    }
}
