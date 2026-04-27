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

    /// WebRTC/msid recv stream labels often use `secretName_` while `setMessageKey` uses `secretName`.
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
    ///   - production fallback (1:1 SFU rooms): if the SFU emits a UUID-like streamId, remap to the
    ///     **remote peer's** frame id (same as ``remoteTrackOwnerParticipantId`` / sender `localParticipantId`),
    ///     not the room id in `connection.recipient`, so FrameCryptor key lookup matches `setMessageKey`.
    ///     This guards a historical outage where remote tracks attached successfully but rendered
    ///     zero decrypted frames because receiver cryptors were bound to room/placeholder ids.
    ///   - WebRTC/msid labels often use a trailing underscore (`echo_`, `nudge_`) while frame keys are
    ///     provisioned under the peer ``secretName`` without that suffix — remap so rebinding after
    ///     renegotiation does not attach cryptors to ids with no `setMessageKey` entry (symptom: ICE
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

    /// Whether a camera receiver should be surfaced to multi-participant UI as an actual remote tile.
    ///
    /// Apple Unified Plan can emit a receiver/track for the initial SFU answer even when the SFU has no
    /// remote source to forward yet. In those answers the recv stream label is UUID-shaped and the SDP
    /// carries no remote SSRC/msid, so rendering it creates a black "remote participant" tile forever.
    private func shouldSurfaceRemoteParticipantCameraTrack(
        connection: RTCConnection,
        participantId: String
    ) -> Bool {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
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
        guard isGroupCallConnection(connection.id) else { return }

        let participantIds = stableRemoteCameraParticipantIds(in: remoteSdp, connection: connection)
        guard !participantIds.isEmpty else { return }

        connection = clearUuidAliasedReceiverCryptors(on: connection, keepingParticipantId: nil)

        let cameraReceivers: [(receiver: RTCRtpReceiver, track: RTCVideoTrack)] = connection.peerConnection.transceivers.compactMap { transceiver in
            guard transceiver.mediaType == .video,
                  let track = transceiver.receiver.track as? RTCVideoTrack,
                  !RTCSession.isScreenShareId(track.trackId),
                  track.readyState != .ended
            else { return nil }
            return (transceiver.receiver, track)
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

        for participantId in participantIds {
            guard shouldSurfaceRemoteParticipantCameraTrack(connection: updated, participantId: participantId) else { continue }

            if let existing = updated.remoteVideoTracksByParticipantId[participantId],
               existing.readyState != .ended {
                consumedTrackIds.insert(existing.trackId)
                continue
            }

            guard let pair = cameraReceivers.first(where: { pair in
                guard !consumedTrackIds.contains(pair.track.trackId) else { return false }
                return !updated.remoteVideoTracksByParticipantId.values.contains(where: { $0 === pair.track })
            }) ?? cameraReceivers.first(where: { !consumedTrackIds.contains($0.track.trackId) }) else {
                logger.log(
                    level: .warning,
                    message: "No unmapped camera receiver available for SFU participant=\(participantId) connection=\(updated.id)"
                )
                continue
            }

            updated.remoteVideoTrack = pair.track
            updated.remoteVideoTracksByParticipantId[participantId] = pair.track
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

    /// WebRTC may not emit `didRemoveStream` when the SFU removes only the screen-share sender
    /// during renegotiation. Reconcile the stored screen tracks against the current remote SDP so
    /// the screen-share tile disappears as soon as the server stops advertising it.
    func reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
        _ remoteSdp: String,
        connectionId: String
    ) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        let advertisedParticipants = Set(stableRemoteScreenParticipantIds(in: remoteSdp, connection: connection))

        func isStillAdvertised(_ participantId: String) -> Bool {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            return advertisedParticipants.contains { Self.conferenceParticipantIdentityKey($0) == participantKey }
        }

        var didUpdate = false
        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) where !isStillAdvertised(participantId) {
            connection.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
            if let cryptor = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                cryptor.enabled = false
                cryptor.delegate = nil
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
    }

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

    private func stableRemoteScreenParticipantIds(
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
                if let streamLabel = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
                    appendStreamLabel(String(streamLabel))
                }
            } else if let range = line.range(of: " msid:") {
                let remainder = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let streamLabel = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
                    appendStreamLabel(String(streamLabel))
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

        var ids: [String] = []
        var seen = Set<String>()

        func appendScreenLabel(_ rawLabel: String) {
            guard let participantId = normalizedRemoteScreenParticipantIdFromSfuLabel(rawLabel, connection: connection) else { return }
            guard !seen.contains(participantId) else { return }
            seen.insert(participantId)
            ids.append(participantId)
        }

        for line in lines {
            if line.hasPrefix("a=msid:") {
                let remainder = String(line.dropFirst("a=msid:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                for part in parts {
                    appendScreenLabel(part)
                }
            } else if let range = line.range(of: " msid:") {
                let remainder = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                for part in parts {
                    appendScreenLabel(part)
                }
            }
        }

        return ids
    }

    private func normalizedRemoteParticipantIdFromSfuStreamLabel(
        _ rawLabel: String,
        connection: RTCConnection
    ) -> String? {
        var id = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard !RTCSession.isScreenShareId(id) else { return nil }

        if id.hasPrefix("streamId_") {
            id = String(id.dropFirst("streamId_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if id.hasSuffix("_") {
            id = String(id.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !id.isEmpty else { return nil }
        guard UUID(uuidString: id) == nil else { return nil }
        guard !RTCSession.isScreenShareId(id) else { return nil }

        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty, id.caseInsensitiveCompare(local) == .orderedSame {
            return nil
        }

        return id
    }

    private func normalizedRemoteScreenParticipantIdFromSfuLabel(
        _ rawLabel: String,
        connection: RTCConnection
    ) -> String? {
        var id = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if id.hasPrefix("streamId_") {
            id = String(id.dropFirst("streamId_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let participant = RTCSession.participantIdFromScreenShareId(id) else {
            return nil
        }
        id = participant.trimmingCharacters(in: .whitespacesAndNewlines)

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

        // The legacy "single" receiver-cryptor slots can also hold a UUID-bound cryptor that
        // shares the underlying RTPReceiver. Replacing the slot without disabling first would
        // leak a still-active cryptor on that receiver.
        if let existingVideo = updated.videoFrameCryptor {
            existingVideo.enabled = false
            updated.videoFrameCryptor = nil
        }
        if let existingAudio = updated.audioFrameCryptor {
            existingAudio.enabled = false
            updated.audioFrameCryptor = nil
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

        let sourceKey = exportFrameEncryptionKey(index: sourceIndex, for: source)
        guard !sourceKey.isEmpty else { return false }
        await setFrameEncryptionKey(sourceKey, index: sourceIndex, for: target)
        logger.log(
            level: .info,
            message: "Provisioned UUID alias frame key participantId='\(target)' from sourceParticipantId='\(source)' index=\(sourceIndex) connId=\(connection.id)"
        )
        return true
    }

#if canImport(WebRTC)
    /// Re-binds Apple WebRTC receiver `RTCFrameCryptor`s after receive-side frame keys are injected in
    /// ``RTCSession/setReceivingMessageKey``.
    ///
    /// Android calls `createReceiverEncryptedFrame` from that path; Apple historically only updated the
    /// key provider. When `didAddReceiver` runs before the ciphertext/`setReceivingMessageKey` step,
    /// initial cryptors may never observe keys (ICE connected, tracks attached, zero decoded frames).
    ///
    /// Scoped to true 1:1-over-SFU and non-group peer connections so we do not overwrite shared
    /// `videoFrameCryptor` slots used by multi-party SFU layouts.
    internal func appleReattachReceiverFrameCryptorsAfterReceiveKey(
        connection: RTCConnection,
        provisionedRemoteTrackOwnerId: String
    ) async throws {
        guard enableEncryption else { return }
        let provisioned = provisionedRemoteTrackOwnerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provisioned.isEmpty else { return }

        let allowAggressiveReattach =
            Self.isTrueOneToOneSfuRoom(call: connection.call) || !isGroupCallConnection(connection.id)
        guard allowAggressiveReattach else { return }

        guard var conn = await connectionManager.findConnection(with: connection.id) else { return }

        if Self.isTrueOneToOneSfuRoom(call: conn.call) {
            appleDisableAllAppleReceiverFrameCryptors(&conn)
        } else {
            appleDropUuidAliasedReceiverCryptorMapEntries(&conn, keepingParticipantId: provisioned)
            appleDisableAppleReceiverFrameCryptorsForParticipant(&conn, provisionedParticipantId: provisioned)
        }
        await connectionManager.updateConnection(id: conn.id, with: conn)

        guard var connAfterClear = await connectionManager.findConnection(with: connection.id) else { return }

        try await appleRebindAppleReceiverCryptorsFromTrackMaps(
            conn: &connAfterClear,
            provisionedRemoteTrackOwnerId: provisioned)
        await connectionManager.updateConnection(id: connAfterClear.id, with: connAfterClear)
    }

    private func appleDisableAllAppleReceiverFrameCryptors(_ conn: inout RTCConnection) {
        if let c = conn.videoFrameCryptor {
            c.enabled = false
            c.delegate = nil
        }
        conn.videoFrameCryptor = nil
        if let c = conn.audioFrameCryptor {
            c.enabled = false
            c.delegate = nil
        }
        conn.audioFrameCryptor = nil
        for (_, c) in conn.videoReceiverCryptorsByParticipantId {
            c.enabled = false
            c.delegate = nil
        }
        conn.videoReceiverCryptorsByParticipantId.removeAll()
        for (_, c) in conn.audioReceiverCryptorsByParticipantId {
            c.enabled = false
            c.delegate = nil
        }
        conn.audioReceiverCryptorsByParticipantId.removeAll()
        for (_, c) in conn.screenReceiverCryptorsByParticipantId {
            c.enabled = false
            c.delegate = nil
        }
        conn.screenReceiverCryptorsByParticipantId.removeAll()
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
    }

    private func appleDisableAppleReceiverFrameCryptorsForParticipant(
        _ conn: inout RTCConnection,
        provisionedParticipantId: String
    ) {
        let p = provisionedParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = conn.videoReceiverCryptorsByParticipantId.removeValue(forKey: p) {
            c.enabled = false
            c.delegate = nil
            if conn.videoFrameCryptor === c {
                conn.videoFrameCryptor = nil
            }
        }
        if let c = conn.audioReceiverCryptorsByParticipantId.removeValue(forKey: p) {
            c.enabled = false
            c.delegate = nil
            if conn.audioFrameCryptor === c {
                conn.audioFrameCryptor = nil
            }
        }
        if let c = conn.screenReceiverCryptorsByParticipantId.removeValue(forKey: p) {
            c.enabled = false
            c.delegate = nil
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

        for (streamPid, audioTrack) in conn.remoteAudioTracksByParticipantId {
            guard let receiver = conn.peerConnection.receivers.first(where: { $0.track?.trackId == audioTrack.trackId })
            else { continue }
            let resolved = receiverParticipantIdOverrideForE2EE(
                connection: conn,
                participantIdFromStreamIds: streamPid
            )
            let receiverPid = resolved.override
            guard matchesProvisioned(effectiveReceiverId: receiverPid) else { continue }

            if !shouldSkipGroupReceiverFrameCryptor(connection: conn, participantIdOverride: receiverPid),
               !shouldDelayGroupReceiverFrameCryptorUntilStableParticipantId(
                connection: conn,
                participantIdOverride: receiverPid) {
                try await createEncryptedFrame(
                    connection: conn,
                    kind: .audioReceiver(receiver),
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
                        kind: .audioReceiver(receiver),
                        participantIdOverride: receiverPid)
                    await refreshConn()
                }
            }
        }

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

        logger.log(
            level: .info,
            message: "Apple receiver FrameCryptor reattach finished after setReceivingMessageKey connId=\(conn.id) provisionedRemoteTrackOwner='\(provisioned)'"
        )
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
            case .signalingStateDidChange(_, let stateChanged):
                self.logger.log(level: .info, message: "peerConnection new signaling state: \(stateChanged.description)")
                if stateChanged.description == "stable" {}
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
                    let stableParticipantId = e2eeParticipantId ?? trimmedStreamId
                    let localParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stableParticipantId.isEmpty,
                       UUID(uuidString: stableParticipantId) == nil,
                       stableParticipantId.caseInsensitiveCompare(localParticipantId) != .orderedSame {
                        do {
                            // Disable any prior UUID-aliased cryptors on the same receivers before
                            // rebinding to the stable id; otherwise libwebrtc has two cryptors on
                            // the same RTPReceiver and the alias map keeps stale entries.
                            var cleaned = clearUuidAliasedReceiverCryptors(
                                on: connection,
                                keepingParticipantId: stableParticipantId
                            )
                            await connectionManager.updateConnection(id: cleaned.id, with: cleaned)

                            let mappedCameraTracks = Array(cleaned.remoteVideoTracksByParticipantId.values)
                            let unmappedVideoReceiver = cleaned.peerConnection.transceivers.first(where: {
                                guard $0.mediaType == .video,
                                      !RTCSession.isScreenShareId($0.receiver.track?.trackId ?? ""),
                                      let candidate = $0.receiver.track as? WebRTC.RTCVideoTrack
                                else {
                                    return false
                                }
                                return !mappedCameraTracks.contains(where: { $0 === candidate })
                            })?.receiver
                            let fallbackVideoReceiver = cleaned.peerConnection.transceivers.first(where: {
                                $0.mediaType == .video && !RTCSession.isScreenShareId($0.receiver.track?.trackId ?? "")
                            })?.receiver
                            if let videoReceiver = unmappedVideoReceiver ?? fallbackVideoReceiver {
                                if let videoTrack = videoReceiver.track as? WebRTC.RTCVideoTrack,
                                   cleaned.remoteVideoTracksByParticipantId[stableParticipantId] == nil {
                                    cleaned.remoteVideoTrack = videoTrack
                                    cleaned.remoteVideoTracksByParticipantId[stableParticipantId] = videoTrack
                                    await connectionManager.updateConnection(id: cleaned.id, with: cleaned)
                                    notifyRemoteParticipantTrackChanged(
                                        RemoteParticipantTrackEvent(connectionId: cleaned.id, participantId: stableParticipantId, kind: "video", isActive: true)
                                    )
                                }
                                try await self.createEncryptedFrame(
                                    connection: cleaned,
                                    kind: .videoReceiver(videoReceiver),
                                    participantIdOverride: stableParticipantId
                                )
                            }
                            if let audioReceiver = cleaned.peerConnection.transceivers.first(where: {
                                $0.mediaType == .audio
                            })?.receiver {
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
                } else {
                    let participantId = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !participantId.isEmpty {
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
                            let fallbackScreenParticipant = participantId.isEmpty ? connection.id : participantId
                            let resolvedScreenParticipant = RTCSession.resolvedScreenShareParticipantId(
                                streamIds: streamIds,
                                trackId: trackId,
                                fallback: fallbackScreenParticipant
                            )
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
                        let fallbackScreenParticipant = participantId.isEmpty ? connection.id : participantId
                        let resolvedScreenParticipant = RTCSession.resolvedScreenShareParticipantId(
                            streamIds: streamIds,
                            trackId: trackId,
                            fallback: fallbackScreenParticipant
                        )
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
                        let shouldSurfaceCameraTrack = shouldSurfaceRemoteParticipantCameraTrack(
                            connection: connection,
                            participantId: participantId
                        )
                        let shouldStoreLegacyRemoteTrack = !isGroupCallConnection(connection.id) || shouldSurfaceCameraTrack
                        if shouldSurfaceCameraTrack {
                            updated.remoteVideoTracksByParticipantId[participantId] = videoTrack
                        }
                        if shouldStoreLegacyRemoteTrack {
                            updated.remoteVideoTrack = videoTrack
                        }
                        await connectionManager.updateConnection(id: updated.id, with: updated)
                        
                        let normalizedConnectionId = updated.id.normalizedConnectionId
                        if shouldStoreLegacyRemoteTrack,
                           let pendingRenderer = pendingRemoteVideoRenderersByConnectionId[normalizedConnectionId] {
                            logger.log(level: .info, message: "Rebinding remote renderer now that remote video track is available (trackId=\(trackId))")
                            connection.remoteVideoTrack?.remove(pendingRenderer)
                            videoTrack.add(pendingRenderer)
                        }

                        if shouldSurfaceCameraTrack {
                            notifyRemoteParticipantTrackChanged(
                                RemoteParticipantTrackEvent(connectionId: updated.id, participantId: participantId, kind: "video", isActive: true)
                            )
                        }

                        if let mediaDelegate, shouldSurfaceCameraTrack {
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
                            if resolved.isUuidLikeStreamRemap {
                                self.logger.log(
                                    level: .warning,
                                    message: "⚠️ SFU streamId '\(participantId)' is UUID-shaped in 1:1 room; overriding receiver participantId -> '\(receiverParticipantId ?? "?")' for E2EE key alignment"
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
                                    message: "⚠️ No frame key provisioned for resolvedParticipantId=\(resolved) yet. If SFU uses streamId UUIDs, expect FrameCryptor missingKey until keys are injected for that exact participantId (or resolver maps to real participant ids)."
                                )
                            }
                        }
                        if enableEncryption {
                            if !shouldSkipGroupReceiverFrameCryptor(
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
                            if resolved.isUuidLikeStreamRemap {
                                self.logger.log(
                                    level: .warning,
                                    message: "⚠️ SFU streamId '\(participantId)' is UUID-shaped in 1:1 room; overriding receiver participantId -> '\(receiverParticipantId ?? "?")' for E2EE key alignment"
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
                        // Group call: participantId must come from didAddReceiver/addStream mapping.
                        // Avoid binding receiver cryptors here to room-id / placeholder ids.
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
