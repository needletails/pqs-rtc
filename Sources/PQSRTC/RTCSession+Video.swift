//
//  RTCSession+Video.swift
//  pqs-rtc
//
//  Created by Cole M on 9/11/24.
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
import NeedleTailLogger
#if os(Android)
import BinaryCodable
#endif
#if !os(Android)
import WebRTC
#endif

struct SPTVideoTrack {
#if os(Android)
    let track: RTCVideoTrack
#elseif !os(Android)
    let track: WebRTC.RTCVideoTrack
#endif
}

extension RTCSession {

    func remoteParticipantVideoRendererAttachmentKey(connectionId: String, participantId: String) -> String {
        let normalizedId = connectionId.normalizedConnectionId
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        let stableParticipant = participantKey.isEmpty
            ? participantId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : participantKey
        return "\(normalizedId)|\(stableParticipant)"
    }

    func clearRemoteParticipantVideoRendererAttachments(connectionId: String) {
        let prefix = "\(connectionId.normalizedConnectionId)|"
        remoteParticipantVideoRendererAttachedTrackIdByKey = remoteParticipantVideoRendererAttachedTrackIdByKey.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    func clearRemoteParticipantVideoRendererAttachment(connectionId: String, participantId: String) {
        let key = remoteParticipantVideoRendererAttachmentKey(
            connectionId: connectionId,
            participantId: participantId
        )
        remoteParticipantVideoRendererAttachedTrackIdByKey.removeValue(forKey: key)
    }

    func noteAndroidParticipantSinkRebindNeeded(connectionId: String, participantId: String) {
        let norm = connectionId.normalizedConnectionId
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var rebound = sfuRenegotiationReboundParticipantIdsByConnectionId[norm, default: []]
        rebound.insert(trimmed)
        sfuRenegotiationReboundParticipantIdsByConnectionId[norm] = rebound
    }

    func notifyParticipantCameraRendererSinkRefreshIfNeeded(
        connectionId: String,
        participantIds: [String]
    ) {
        let norm = connectionId.normalizedConnectionId
        var pendingIds: [String] = []
        for participantId in participantIds {
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pendingIds.append(trimmed)
        }
        guard !pendingIds.isEmpty else { return }
        if shouldDeferSfuGroupParticipantVideoAttach(for: norm) {
            var queued = pendingParticipantRendererSinkRefreshByConnectionId[norm, default: []]
            queued.formUnion(pendingIds)
            pendingParticipantRendererSinkRefreshByConnectionId[norm] = queued
            return
        }
        for trimmed in pendingIds {
            clearDeliveredActiveParticipantVideoTrackKey(connectionId: norm, participantId: trimmed)
            notifyRemoteParticipantTrackChanged(
                RemoteParticipantTrackEvent(
                    connectionId: norm,
                    participantId: trimmed,
                    kind: "video",
                    isActive: true
                )
            )
        }
    }

#if os(Android)
    func installAndroidVideoReceiverFrameCryptorReadyHandler() {
        rtcClient.setVideoReceiverFrameCryptorReadyHandler { [weak self] participantId in
            guard let self else { return }
            Task { await self.handleAndroidVideoReceiverFrameCryptorReady(participantId: participantId) }
        }
    }

    private func handleAndroidVideoReceiverFrameCryptorReady(participantId: String) async {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let norm = activeConnectionId?.normalizedConnectionId,
              let connection = await connectionManager.findConnection(with: norm),
              isGroupCallConnection(connection.id) else {
            return
        }
        let mappedParticipant = connection.remoteVideoTracksByParticipantId.keys.first {
            $0 == trimmed
                || RTCSession.conferenceParticipantIdentityKey($0)
                    == RTCSession.conferenceParticipantIdentityKey(trimmed)
        }
        guard mappedParticipant != nil else { return }
        logger.log(
            level: .info,
            message: "Android video FrameCryptor ready; refreshing participant renderer sink participant=\(trimmed) connection=\(norm)"
        )
        await rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(connectionId: norm)
        notifyParticipantCameraRendererSinkRefreshIfNeeded(
            connectionId: norm,
            participantIds: [trimmed]
        )
    }
#endif

#if canImport(WebRTC) && !os(Android)
    func remoteParticipantVideoRendererAttachmentValue(
        track: WebRTC.RTCVideoTrack,
        renderer: RTCVideoRenderWrapper,
        peerConnection: WebRTC.RTCPeerConnection
    ) -> String {
        var receivingMid: String?
        var fallbackMid: String?
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            guard let receiverTrack = transceiver.receiver.track as? WebRTC.RTCVideoTrack else {
                continue
            }
            guard receiverTrack.trackId == track.trackId else { continue }
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty else { continue }
            fallbackMid = mid
            if Self.isAppleTransceiverReceivingRemoteMedia(transceiver) {
                receivingMid = mid
            }
        }
        let source = receivingMid ?? fallbackMid ?? "trackObject:\(ObjectIdentifier(track))"
        return "\(track.trackId)|mid:\(source)|\(ObjectIdentifier(renderer))"
    }

    func refreshGroupParticipantCameraTrackBindingIfNeeded(
        connection: inout RTCConnection,
        participantId: String
    ) -> Bool {
        guard let (_, storedTrack) = remoteCameraTrackBinding(in: connection, participantId: participantId) else {
            return false
        }
        guard let liveTrack = resolvedLiveGroupParticipantCameraTrack(
            in: connection,
            participantId: participantId,
            mappedTrack: storedTrack
        ) else {
            return false
        }
        guard liveTrack !== storedTrack || storedTrack.readyState == .ended else {
            return false
        }
        return Self.claimRemoteCameraTrack(
            liveTrack,
            participantId: participantId,
            in: &connection,
            allowReplacingExistingStableOwner: true
        )
    }

    func resolvedLiveGroupParticipantCameraTrack(
        in connection: RTCConnection,
        participantId: String,
        mappedTrack: WebRTC.RTCVideoTrack
    ) -> WebRTC.RTCVideoTrack? {
        let remoteSdp = connection.peerConnection.remoteDescription?.sdp ?? ""
        let advertisedOwnersByTrackId = Self.advertisedRemoteCameraOwnersByTrackId(in: remoteSdp)
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        let advertisedTrackIds = Set(advertisedOwnersByTrackId.compactMap { trackId, owner -> String? in
            Self.conferenceParticipantIdentityKey(owner) == participantKey ? trackId : nil
        })
        return Self.resolveLiveGroupParticipantCameraTrack(
            storedTrackId: mappedTrack.trackId,
            advertisedTrackIds: advertisedTrackIds,
            in: connection.peerConnection
        )
    }
#endif

#if os(Android)
    /// Claims a remote camera track for one stable Android participant identity.
    ///
    /// Android group/conference callbacks can deliver the same receiver first under a transient
    /// placeholder and later under the stable SFU participant label. Keep exactly one stable owner.
    @discardableResult
    static func claimRemoteCameraTrack(
        _ track: RTCVideoTrack,
        participantId rawParticipantId: String,
        in connection: inout RTCConnection,
        allowReplacingExistingStableOwner: Bool = false
    ) -> Bool {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let participantKey = conferenceParticipantIdentityKey(participantId)
        guard !participantId.isEmpty, !participantKey.isEmpty else { return false }
        let incomingTrackId = track.trackIdIfAvailable

        func isSameTrack(_ existingTrack: RTCVideoTrack) -> Bool {
            if existingTrack === track { return true }
            guard let incomingTrackId else { return false }
            return existingTrack.trackIdIfAvailable == incomingTrackId
        }

        let existingStableOwner = connection.remoteVideoTracksByParticipantId.first { existingParticipantId, existingTrack in
            let existingKey = conferenceParticipantIdentityKey(existingParticipantId)
            guard !existingKey.isEmpty, existingKey != participantKey else { return false }
            guard UUID(uuidString: existingParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)) == nil else {
                return false
            }
            return isSameTrack(existingTrack)
        }
        if let existingStableOwner {
            guard allowReplacingExistingStableOwner else { return false }
            connection.remoteVideoTracksByParticipantId.removeValue(forKey: existingStableOwner.key)
        }

        let keysToRemove = connection.remoteVideoTracksByParticipantId.keys.filter { key in
            let keyParticipant = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let mapped = connection.remoteVideoTracksByParticipantId[key]
            if conferenceParticipantIdentityKey(keyParticipant) == participantKey, keyParticipant != participantId {
                return true
            }
            if UUID(uuidString: keyParticipant) != nil,
               let mapped,
               isSameTrack(mapped) {
                return true
            }
            return false
        }
        for key in keysToRemove {
            connection.remoteVideoTracksByParticipantId.removeValue(forKey: key)
        }

        connection.remoteVideoTracksByParticipantId[participantId] = track
        return true
    }

    static func stableRemoteCameraTrackOwner(
        for track: RTCVideoTrack,
        in connection: RTCConnection
    ) -> String? {
        let incomingTrackId = track.trackIdIfAvailable
        return connection.remoteVideoTracksByParticipantId.first { participantId, mappedTrack in
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !conferenceParticipantIdentityKey(trimmed).isEmpty,
                  UUID(uuidString: trimmed) == nil
            else { return false }
            if mappedTrack === track { return true }
            guard let incomingTrackId else { return false }
            return mappedTrack.trackIdIfAvailable == incomingTrackId
        }?.key
    }

#elseif canImport(WebRTC) && !os(Android)
    /// Claims a remote camera track for one stable participant identity.
    ///
    /// Group/conference SFU receivers can be observed before the SFU has attached stable stream
    /// labels. Those transient UUID placeholders must not let the same live receiver/track become
    /// two visible participant tiles once keys or later SDP arrive.
    @discardableResult
    static func claimRemoteCameraTrack(
        _ track: WebRTC.RTCVideoTrack,
        participantId rawParticipantId: String,
        in connection: inout RTCConnection,
        allowReplacingExistingStableOwner: Bool = false
    ) -> Bool {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let participantKey = conferenceParticipantIdentityKey(participantId)
        guard !participantId.isEmpty, !participantKey.isEmpty else { return false }

        let existingStableOwner = connection.remoteVideoTracksByParticipantId.first { existingParticipantId, existingTrack in
            let existingKey = conferenceParticipantIdentityKey(existingParticipantId)
            guard !existingKey.isEmpty, existingKey != participantKey else { return false }
            guard UUID(uuidString: existingParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)) == nil else {
                return false
            }
            return existingTrack === track || existingTrack.trackId == track.trackId
        }
        if let existingStableOwner {
            guard allowReplacingExistingStableOwner else { return false }
            connection.remoteVideoTracksByParticipantId.removeValue(forKey: existingStableOwner.key)
        }

        let keysToRemove = connection.remoteVideoTracksByParticipantId.keys.filter { key in
            let keyParticipant = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let mapped = connection.remoteVideoTracksByParticipantId[key]
            if conferenceParticipantIdentityKey(keyParticipant) == participantKey, keyParticipant != participantId {
                return true
            }
            if UUID(uuidString: keyParticipant) != nil,
               let mapped,
               mapped === track || mapped.trackId == track.trackId {
                return true
            }
            return false
        }
        for key in keysToRemove {
            connection.remoteVideoTracksByParticipantId.removeValue(forKey: key)
        }

        connection.remoteVideoTracksByParticipantId[participantId] = track
        return true
    }

    static func stableRemoteCameraTrackOwner(
        for track: WebRTC.RTCVideoTrack,
        in connection: RTCConnection
    ) -> String? {
        connection.remoteVideoTracksByParticipantId.first { participantId, mappedTrack in
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !conferenceParticipantIdentityKey(trimmed).isEmpty,
                  UUID(uuidString: trimmed) == nil
            else { return false }
            return mappedTrack === track || mappedTrack.trackId == track.trackId
        }?.key
    }

    static func advertisedRemoteCameraOwnersByTrackId(in sdp: String) -> [String: String] {
        var owners: [String: String] = [:]
        var currentMediaKind: String?
        var currentSectionLines: [String] = []

        func participantId(fromCameraLabel raw: String) -> String? {
            var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !isScreenShareId(label), UUID(uuidString: label) == nil else { return nil }
            if label.hasPrefix("streamId_") {
                label.removeFirst("streamId_".count)
            }
            if label.hasPrefix("video_") {
                label.removeFirst("video_".count)
            } else if label.hasPrefix("audio_") {
                label.removeFirst("audio_".count)
            }

            if let separator = label.lastIndex(of: "_") {
                let suffixStart = label.index(after: separator)
                let suffix = String(label[suffixStart...])
                if UUID(uuidString: suffix) != nil {
                    label = String(label[..<separator])
                }
            }
            guard UUID(uuidString: label) == nil else { return nil }
            let normalized = conferenceParticipantIdentityKey(label)
            return normalized.isEmpty ? nil : normalized
        }

        func flushCurrentSection() {
            guard currentMediaKind == "video" else { return }
            guard !currentSectionLines.contains(where: { $0 == "a=inactive" || $0 == "a=recvonly" }) else {
                return
            }
            for entry in Self.sfuSdpMsidEntries(inSectionLines: currentSectionLines) {
                guard let trackId = entry.trackId,
                      !isScreenShareId(trackId)
                else { continue }
                let participantId = participantId(fromCameraLabel: entry.streamLabel)
                    ?? participantId(fromCameraLabel: trackId)
                guard let participantId else { continue }
                owners[trackId] = participantId
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

        return owners
    }
#endif

    /// True when replacing a live SFU relay camera track with a UUID placeholder would freeze remote video.
    static func oneToOneSfuRemoteTrackWouldDowngradeRelayToPlaceholder(
        previousTrackId: String?,
        resolvedTrackId: String?
    ) -> Bool {
        guard let previousTrackId,
              let resolvedTrackId,
              isSfuCameraMediaId(previousTrackId),
              UUID(uuidString: resolvedTrackId) != nil
        else { return false }
        return true
    }

#if os(Android)
    private func androidRemoteOfferSdp(from connection: RTCConnection) -> String? {
        if let cached = latestAndroidRemoteOfferSdp(connectionId: connection.id),
           !cached.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return cached
        }

        guard let metadata = connection.call.metadata,
              !metadata.isEmpty,
              let description = try? BinaryDecoder().decode(SessionDescription.self, from: metadata),
              description.type == .offer
        else {
            return nil
        }

        let sdp = description.sdp.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return sdp.isEmpty ? nil : description.sdp
    }

    /// Owner-aware 1:1 SFU inbound camera resolution for Android — never the first video
    /// transceiver placeholder (receive half of our own send m-line).
    func resolveOneToOneSfuInboundRemoteCameraVideoTrack(
        connection: inout RTCConnection
    ) -> RTCVideoTrack? {
        guard Self.isTrueOneToOneSfuRoom(call: connection.call) else { return nil }
        let owner = oneToOneSfuRemoteTrackOwnerId(connection: connection)
        guard !owner.isEmpty else { return nil }
        guard let remoteSdp = androidRemoteOfferSdp(from: connection)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !remoteSdp.isEmpty else {
            return nil
        }
        guard let liveTrack = androidResolveLiveRemoteCameraTrack(
            participantId: owner,
            connection: &connection,
            remoteSdp: remoteSdp,
            preferFreshFromPeerConnection: true
        ), liveTrack.isLiveVideoTrack else {
            return nil
        }
        return liveTrack
    }

    /// Render local video to Android view (equivalent to iOS RTCVideoRenderWrapper)
    func renderLocalVideo(to view: AndroidPreviewCaptureView, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering local video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        pendingLocalVideoRenderersByConnectionId[normalizedId] = view
        guard let videoTrack: RTCVideoTrack = await manager.findConnection(with: normalizedId)?.localVideoTrack else {
            logger.log(level: .info, message: "Local video track not ready yet; buffered preview renderer for connection: \(normalizedId)")
            return
        }
        logger.log(level: .info, message: "Attaching Local Track to View - Track: \(videoTrack)")
        view.attach(videoTrack)
        pendingLocalVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
    }
    
    /// Render remote video to Android view for 1:1 calls.
    func renderRemoteVideo(to view: AndroidSampleCaptureView, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        let client: AndroidRTCClient = self.rtcClient
        pendingRemoteVideoRenderersByConnectionId[normalizedId] = view

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "No connection found for ID: \(connectionId) (normalized=\(normalizedId))")
            return
        }

        let cachedTrack = connection.remoteVideoTrack
        let resolvedTrack: RTCVideoTrack?
        if Self.isTrueOneToOneSfuRoom(call: connection.call) {
            resolvedTrack = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: &connection)
        } else {
            resolvedTrack = client.getRemoteVideoTrack(peerConnection: connection.peerConnection)
        }

        if let resolvedTrack {
            let resolvedId = resolvedTrack.trackIdIfAvailable
            let cachedId = cachedTrack?.trackIdIfAvailable
            if Self.oneToOneSfuRemoteTrackWouldDowngradeRelayToPlaceholder(
                previousTrackId: cachedId,
                resolvedTrackId: resolvedId
            ) {
                logger.log(
                    level: .info,
                    message: "renderRemoteVideo keeping SFU relay track over placeholder connection=\(normalizedId) trackId=\(cachedId ?? "nil") placeholderTrackId=\(resolvedId ?? "nil")"
                )
            } else if cachedTrack == nil
                || cachedTrack?.isLiveVideoTrack == false
                || cachedId != resolvedId {
                connection.remoteVideoTrack = resolvedTrack
                let owner = oneToOneSfuRemoteTrackOwnerId(connection: connection)
                if !owner.isEmpty {
                    connection.remoteVideoTracksByParticipantId[owner] = resolvedTrack
                }
                logger.log(
                    level: .info,
                    message: "renderRemoteVideo resolved live inbound camera track connection=\(normalizedId) trackId=\(resolvedId) previousTrackId=\(cachedId ?? "nil")"
                )
            }
        }
        
        if let videoTrack = connection.remoteVideoTrack {
            let receiveKeyReady = oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(normalizedId))
            if Self.shouldDeferOneToOneSfuRemoteRendererAttach(
                isOneToOneSfuRoom: Self.isTrueOneToOneSfuRoom(call: connection.call),
                frameEncryptionEnabled: enableEncryption,
                receiveKeyReady: receiveKeyReady
            ) {
                logger.log(
                    level: .info,
                    message: "Deferring 1:1 SFU remote renderer attach until call_cipher receive key is installed connId=\(normalizedId)"
                )
                await manager.updateConnection(id: normalizedId, with: connection)
                return
            }
            if sfuRenegotiationReceiverCryptorRebindIsDeferred(for: normalizedId) {
                logger.log(
                    level: .info,
                    message: "Deferring 1:1 SFU remote renderer attach until SFU renegotiation answer completes connId=\(normalizedId)"
                )
                await manager.updateConnection(id: normalizedId, with: connection)
                return
            }
            logger.log(level: .info, message: "Found remote video track, attaching renderer - trackId: \(videoTrack.trackId)")
            _ = view.attach(videoTrack)
            if !Self.isTrueOneToOneSfuRoom(call: connection.call) {
                pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
            }
        } else {
            logger.log(level: .info, message: "Remote renderer buffered; will attach when receiver/track is added")
        }
        
        await manager.updateConnection(id: normalizedId, with: connection)
    }

    /// Group/conference SFU: after renegotiation the active receiver can swap while the stored
    /// `RTCVideoTrack` wrapper still points at a disposed sink. Notify participant renderers so
    /// they re-resolve the live receiver and re-attach.
    /// After a view-level sink rebind, persist the live peer-connection wrapper on the connection
    /// map so later probes read the same Java object the tile bound.
    func persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
        connectionId: String,
        participantId: String,
        liveTrack: RTCVideoTrack
    ) async {
        let norm = connectionId.normalizedConnectionId
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, liveTrack.isLiveVideoTrack else { return }
        guard var connection = await connectionManager.findConnection(with: norm) else { return }
        guard isGroupCallConnection(connection.id) else { return }

        let storedTrack = connection.remoteVideoTracksByParticipantId[trimmed]
            ?? connection.remoteVideoTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key)
                    == Self.conferenceParticipantIdentityKey(trimmed)
            }?.value
        if let storedTrack, storedTrack.platformTrack === liveTrack.platformTrack {
            return
        }

        guard Self.claimRemoteCameraTrack(
            liveTrack,
            participantId: trimmed,
            in: &connection,
            allowReplacingExistingStableOwner: true
        ) else {
            return
        }
        if let liveTrackId = liveTrack.trackIdIfAvailable, !liveTrackId.isEmpty {
            rememberAndroidResolvedRemoteCameraMedia(
                participantId: trimmed,
                trackId: liveTrackId,
                mid: androidResolvedRemoteCameraMid(participantId: trimmed, in: connection),
                in: &connection
            )
        }
        if connection.remoteVideoTrack === storedTrack || connection.remoteVideoTrack == nil {
            connection.remoteVideoTrack = liveTrack
        }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }

    func androidMappedLiveRemoteCameraTrack(
        connectionId: String,
        participantId: String,
        preferFreshFromPeerConnection: Bool = true
    ) async -> RTCVideoTrack? {
        let norm = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: norm) else { return nil }
        if !preferFreshFromPeerConnection {
            return androidConnectionStoredLiveRemoteCameraTrack(
                participantId: participantId,
                in: connection
            )
        }
        guard let remoteSdp = androidRemoteOfferSdp(from: connection)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteSdp.isEmpty else {
            return androidConnectionStoredLiveRemoteCameraTrack(
                participantId: participantId,
                in: connection
            )
        }
        let resolved = androidResolveLiveRemoteCameraTrack(
            participantId: participantId,
            connection: &connection,
            remoteSdp: remoteSdp,
            preferFreshFromPeerConnection: true
        )
        if resolved?.isLiveVideoTrack == true {
            await connectionManager.updateConnection(id: connection.id, with: connection)
        }
        return resolved
    }

    /// Live receiver already stored on the connection map, without re-resolving from peer connection.
    func androidConnectionStoredLiveRemoteCameraTrack(
        participantId: String,
        in connection: RTCConnection
    ) -> RTCVideoTrack? {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved: RTCVideoTrack?
        if let exact = connection.remoteVideoTracksByParticipantId[trimmed] {
            resolved = exact
        } else {
            let participantKey = Self.conferenceParticipantIdentityKey(trimmed)
            guard !participantKey.isEmpty else { return nil }
            resolved = connection.remoteVideoTracksByParticipantId.first {
                Self.conferenceParticipantIdentityKey($0.key) == participantKey
            }?.value
        }
        guard let resolved, resolved.isLiveVideoTrack else { return nil }
        return resolved
    }

    func rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(connectionId: String) async {
        let norm = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: norm) else { return }
        guard !Self.isTrueOneToOneSfuRoom(call: connection.call) else { return }
        guard isGroupCallConnection(connection.id) else { return }
        guard let remoteSdp = androidRemoteOfferSdp(from: connection)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteSdp.isEmpty else {
            return
        }

        var didRebindAny = false
        var participantsNeedingSinkRefresh: [String] = []
        let renegotiationInFlight = isSfuGroupRenegotiationInFlight(for: norm)
        for (participantId, storedTrack) in connection.remoteVideoTracksByParticipantId {
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let liveTrack = androidResolveLiveRemoteCameraTrack(
                participantId: trimmed,
                connection: &connection,
                remoteSdp: remoteSdp,
                preferFreshFromPeerConnection: true
            ) else {
                continue
            }

            let storedTrackId = storedTrack.trackIdIfAvailable
            let liveTrackId = liveTrack.trackIdIfAvailable
            let cachedTrackId = androidResolvedRemoteCameraTrackId(participantId: trimmed, in: connection)
            let storedStableTrackId = storedTrackId ?? cachedTrackId
            let liveStableTrackId = liveTrackId ?? cachedTrackId
            let platformTracksIdentical = storedTrack.platformTrack === liveTrack.platformTrack
            let needsMapRefresh = AndroidRemoteVideoTrackAttachPolicy.needsAndroidRemoteCameraConnectionMapRefresh(
                storedTrackId: storedStableTrackId,
                liveTrackId: liveStableTrackId,
                storedIsLive: storedTrack.isLiveVideoTrack,
                platformTracksIdentical: platformTracksIdentical
            )

            if !needsMapRefresh {
                continue
            }

            logger.log(
                level: .info,
                message: "\(renegotiationInFlight ? "SFU group renegotiation" : "Live receiver wrapper sync"): rebinding Android remote camera participant=\(trimmed) oldTrackId=\(storedStableTrackId ?? "<nil>") newTrackId=\(liveStableTrackId ?? "<nil>") connection=\(norm)"
            )

            guard Self.claimRemoteCameraTrack(
                liveTrack,
                participantId: trimmed,
                in: &connection,
                allowReplacingExistingStableOwner: true
            ) else {
                logger.log(
                    level: .warning,
                    message: "Rejected Android SFU group camera rebind participant=\(trimmed) trackId=\(liveTrackId ?? "<nil>") connection=\(norm)"
                )
                continue
            }

            if let liveTrackId, !liveTrackId.isEmpty {
                rememberAndroidResolvedRemoteCameraMedia(
                    participantId: trimmed,
                    trackId: liveTrackId,
                    mid: androidResolvedRemoteCameraMid(participantId: trimmed, in: connection),
                    in: &connection
                )
            }
            if connection.remoteVideoTrack === storedTrack || connection.remoteVideoTrack == nil {
                connection.remoteVideoTrack = liveTrack
            }
            participantsNeedingSinkRefresh.append(trimmed)
            didRebindAny = true
        }

        guard didRebindAny else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
        for trimmed in participantsNeedingSinkRefresh {
            if renegotiationInFlight {
                noteAndroidParticipantSinkRebindNeeded(connectionId: norm, participantId: trimmed)
            } else {
                notifyParticipantCameraRendererSinkRefreshIfNeeded(
                    connectionId: norm,
                    participantIds: [trimmed]
                )
            }
        }
    }

    /// Prunes disposed Android remote camera mappings after WebRTC removes a receiver during SFU
    /// renegotiation. Stale wrappers in ``RTCConnection/remoteVideoTracksByParticipantId`` would
    /// otherwise be re-attached and fail with "MediaStreamTrack has been disposed".
    func handleAndroidRemoteVideoTrackRemoved(connectionId: String) async {
        let norm = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: norm) else { return }

        var didPruneAny = false
        var pendingTrackEvents: [RemoteParticipantTrackEvent] = []
        let remoteSdp = androidRemoteOfferSdp(from: connection)

        for (participantId, storedTrack) in Array(connection.remoteVideoTracksByParticipantId) {
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let resolvedLiveTrack = remoteSdp.flatMap {
                androidResolveLiveRemoteCameraTrack(
                    participantId: trimmed,
                    connection: &connection,
                    remoteSdp: $0,
                    preferFreshFromPeerConnection: true
                )
            }

            // WebRTC still exposes a live receiver for this participant. Keep the mapping and let
            // ``rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded`` swap the
            // wrapper without clearing caches or re-emitting tile removal events.
            if let resolvedLiveTrack, resolvedLiveTrack.isLiveVideoTrack {
                continue
            }

            // Renegotiation still in flight; the stored wrapper is live but fresh lookup is not
            // ready yet. Pruning here would detach tiles that are still receiving media.
            if storedTrack.isLiveVideoTrack {
                continue
            }

            connection.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
            clearAndroidResolvedRemoteCameraMedia(participantId: trimmed, in: &connection)
            if connection.remoteVideoTrack === storedTrack {
                connection.remoteVideoTrack = connection.remoteVideoTracksByParticipantId.values.first
            }
            didPruneAny = true
            logger.log(
                level: .warning,
                message: "Android remote camera mapping pruned after track removal participant=\(trimmed) storedTrackId=\(storedTrack.trackIdIfAvailable ?? "<nil>") storedLive=\(storedTrack.isLiveVideoTrack) resolvedLiveTrackId=\(resolvedLiveTrack?.trackIdIfAvailable ?? "<nil>") connection=\(norm)"
            )

            if shouldSurfaceRemoteParticipantCameraTrack(connection: connection, participantId: trimmed) {
                pendingTrackEvents.append(
                    RemoteParticipantTrackEvent(
                        connectionId: connection.id,
                        participantId: trimmed,
                        kind: "video",
                        isActive: false
                    )
                )
            }
        }

        if didPruneAny {
            await connectionManager.updateConnection(id: connection.id, with: connection)
            for event in pendingTrackEvents {
                notifyRemoteParticipantTrackChanged(event)
            }
        }
        await rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(connectionId: norm)
    }

    /// Render a specific participant's video to an Android view (for group/conference calls).
    @discardableResult
    func renderRemoteVideoForParticipant(
        to view: AndroidSampleCaptureView,
        connectionId: String,
        participantId: String,
        preferFreshPeerConnectionTrack: Bool = true
    ) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote video for participant=\(participantId) connection=\(connectionId)")
        let manager = connectionManager as RTCConnectionManager

        guard !isConnectionFinishingOrEnded(normalizedId) else {
            logger.log(level: .info, message: "Skipping Android participant renderer attach for ended connection=\(normalizedId) participant=\(participantId)")
            return false
        }

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "No connection found for participant render: \(connectionId)")
            return false
        }

        if isGroupCallConnection(normalizedId),
           shouldDeferSfuGroupParticipantVideoAttach(for: normalizedId) {
            logger.log(
                level: .info,
                message: "Deferred Android participant renderer attach during SFU renegotiation participant=\(participantId) connection=\(normalizedId)"
            )
            return false
        }

        func mappedVideoTrack(in connection: RTCConnection) -> RTCVideoTrack? {
            let resolved: RTCVideoTrack?
            if let exact = connection.remoteVideoTracksByParticipantId[participantId] {
                resolved = exact
            } else {
                let participantKey = Self.conferenceParticipantIdentityKey(participantId)
                guard !participantKey.isEmpty else { return nil }
                resolved = connection.remoteVideoTracksByParticipantId.first {
                    Self.conferenceParticipantIdentityKey($0.key) == participantKey
                }?.value
            }
            guard let resolved else { return nil }
            guard resolved.isLiveVideoTrack else { return nil }
            return resolved
        }

        var connectionMutatedDuringResolve = false
        let persistMapUpdates = preferFreshPeerConnectionTrack

        func resolveRendererOnlyAttachTrack(from connection: RTCConnection) -> RTCVideoTrack? {
            if let storedTrack = androidConnectionStoredLiveRemoteCameraTrack(
                participantId: participantId,
                in: connection
            ) {
                return storedTrack
            }
            if let mappedTrack = mappedVideoTrack(in: connection) {
                return mappedTrack
            }
            guard let remoteSdp = androidRemoteOfferSdp(from: connection)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteSdp.isEmpty else {
                return nil
            }
            var scratchConnection = connection
            guard let liveTrack = androidResolveLiveRemoteCameraTrack(
                participantId: participantId,
                connection: &scratchConnection,
                remoteSdp: remoteSdp,
                preferFreshFromPeerConnection: false
            ),
            liveTrack.isLiveVideoTrack else {
                return nil
            }
            return liveTrack
        }

        func resolveLiveAttachTrack(from connection: inout RTCConnection) -> RTCVideoTrack? {
            if !persistMapUpdates {
                return resolveRendererOnlyAttachTrack(from: connection)
            }
            if let storedTrack = androidConnectionStoredLiveRemoteCameraTrack(
                participantId: participantId,
                in: connection
            ) {
                return storedTrack
            }
            guard let remoteSdp = androidRemoteOfferSdp(from: connection)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteSdp.isEmpty else {
                return nil
            }
            guard let liveTrack = androidResolveLiveRemoteCameraTrack(
                participantId: participantId,
                connection: &connection,
                remoteSdp: remoteSdp,
                preferFreshFromPeerConnection: true
            ),
            liveTrack.isLiveVideoTrack else {
                return nil
            }
            connectionMutatedDuringResolve = true
            _ = Self.claimRemoteCameraTrack(
                liveTrack,
                participantId: participantId,
                in: &connection,
                allowReplacingExistingStableOwner: true
            )
            if let liveTrackId = liveTrack.trackIdIfAvailable, !liveTrackId.isEmpty {
                rememberAndroidResolvedRemoteCameraMedia(
                    participantId: participantId,
                    trackId: liveTrackId,
                    mid: androidResolvedRemoteCameraMid(participantId: participantId, in: connection),
                    in: &connection
                )
            }
            return liveTrack
        }

        var videoTrack = resolveLiveAttachTrack(from: &connection)
        var loggedTrackId = videoTrack?.trackIdIfAvailable
            ?? androidResolvedRemoteCameraTrackId(participantId: participantId, in: connection)
        if videoTrack == nil {
            videoTrack = mappedVideoTrack(in: connection)
            loggedTrackId = videoTrack?.trackIdIfAvailable ?? loggedTrackId
        }
        let remoteSdp = androidRemoteOfferSdp(from: connection)

        if videoTrack == nil, let remoteSdp {
            logger.log(
                level: .info,
                message: "Android participant camera track unavailable; reconciling before renderer attach participant=\(participantId) connection=\(normalizedId)"
            )
            await reconcileAndroidRemoteParticipantCameraTracksAfterSetRemoteSDP(
                remoteSdp,
                connectionId: normalizedId
            )
            if let refreshed: RTCConnection = await manager.findConnection(with: normalizedId) {
                connection = refreshed
                videoTrack = resolveLiveAttachTrack(from: &connection)
                    ?? mappedVideoTrack(in: refreshed)
                loggedTrackId = videoTrack?.trackIdIfAvailable
                    ?? androidResolvedRemoteCameraTrackId(participantId: participantId, in: refreshed)
                logger.log(
                    level: .info,
                    message: "Android participant camera post-reconcile lookup participant=\(participantId) resolvedTrackId=\(loggedTrackId ?? "<nil>") connection=\(normalizedId)"
                )
            }
        }

        if videoTrack != nil, persistMapUpdates, connectionMutatedDuringResolve {
            await manager.updateConnection(id: connection.id, with: connection)
        }

        guard var attachTrack = videoTrack else {
            logger.log(level: .info, message: "Track not yet available for participant=\(participantId), will attach on arrival")
            return false
        }

        let attachTrackId = loggedTrackId ?? attachTrack.trackIdIfAvailable ?? "<unknown>"

        if preferFreshPeerConnectionTrack,
           let remoteSdp,
           let freshTrack = androidResolveLiveRemoteCameraTrack(
            participantId: participantId,
            connection: &connection,
            remoteSdp: remoteSdp,
            preferFreshFromPeerConnection: true
           ),
           freshTrack.isLiveVideoTrack,
           !attachTrack.isLiveVideoTrack ||
            AndroidRemoteVideoTrackAttachPolicy.shouldPreferPeerConnectionAttachTrack(
            mappedTrackPlatformIdenticalToLive: attachTrack.platformTrack === freshTrack.platformTrack
           ) {
            attachTrack = freshTrack
            loggedTrackId = freshTrack.trackIdIfAvailable ?? loggedTrackId
            connectionMutatedDuringResolve = true
            _ = Self.claimRemoteCameraTrack(
                freshTrack,
                participantId: participantId,
                in: &connection,
                allowReplacingExistingStableOwner: true
            )
            if let loggedTrackId {
                rememberAndroidResolvedRemoteCameraMedia(
                    participantId: participantId,
                    trackId: loggedTrackId,
                    mid: androidResolvedRemoteCameraMid(participantId: participantId, in: connection),
                    in: &connection
                )
            }
            await manager.updateConnection(id: connection.id, with: connection)
            logger.log(
                level: .info,
                message: "Android participant attach resolved live peer-connection track before bind participant=\(participantId) trackId=\(loggedTrackId ?? attachTrackId) connection=\(normalizedId)"
            )
        }

        let resolvedAttachTrackId = attachTrack.trackIdIfAvailable ?? loggedTrackId
        let probe = ParticipantRendererAttachSnapshot.from(view: view, track: attachTrack)
        if !AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: attachTrack.isLiveVideoTrack,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
            rendererHasPendingTrackBind: view.rendererHasPendingTrackBind(),
            rendererHadConfirmedFirstFrame: view.rendererHadConfirmedFirstFrameSinceSinkAttach()
                || view.rendererEverConfirmedFirstFrameForAttachedTrack()
        ) {
            view.rendererDidUpdateLayout()
            logger.log(
                level: .info,
                message: "Skipping redundant participant renderer attach participant=\(participantId) trackId=\(resolvedAttachTrackId ?? attachTrackId) connection=\(normalizedId)"
            )
            if !probe.hasActiveSink {
                notifyParticipantCameraRendererSinkRefreshIfNeeded(
                    connectionId: normalizedId,
                    participantIds: [participantId]
                )
            }
            return probe.hasActiveSink
        }

        view.setSurfaceReadyRetry { [weak self, weak view] in
            guard let self, let view else { return }
            Task {
                _ = await self.renderRemoteVideoForParticipant(
                    to: view,
                    connectionId: connectionId,
                    participantId: participantId
                )
            }
        }
        let didAttach = view.attach(attachTrack)
        let hasActiveSink = view.hasActiveSink()
        let postAttachProbe = ParticipantRendererAttachSnapshot.from(view: view, track: attachTrack)
        let diagnostics = view.rendererAttachDiagnosticSummary()
        let attachAcknowledged = AndroidMultipartyVideoLayout.participantRendererAttachAcknowledged(
            attachReturned: didAttach,
            hasActiveSink: hasActiveSink
        )
        logger.log(
            level: attachAcknowledged ? .info : .warning,
            message: """
            Android participant renderer attach result participant=\(participantId) \
            trackId=\(attachTrackId) attachReturned=\(didAttach) hasActiveSink=\(hasActiveSink) \
            attached=\(attachAcknowledged) probeActiveSink=\(postAttachProbe.hasActiveSink) \
            probeSharesSink=\(postAttachProbe.boundTrackSharesRendererSinkWithTarget) \
            probeLayoutReconcile=\(postAttachProbe.rendererLayoutNeedsSinkReconcile) \
            connection=\(normalizedId) diagnostics=\(diagnostics)
            """
        )
        if AndroidMultipartyVideoLayout.participantRendererAttachSucceeded(
            attachAcknowledged: attachAcknowledged,
            hasActiveSink: hasActiveSink
        ) {
            await persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
                connectionId: normalizedId,
                participantId: participantId,
                liveTrack: attachTrack
            )
            logger.log(level: .info, message: "Attached renderer to participant=\(participantId) trackId=\(attachTrackId)")
            return true
        }

        if attachTrack.isLiveVideoTrack {
            logger.log(
                level: .info,
                message: "Android participant renderer attach queued until surface is ready participant=\(participantId) trackId=\(attachTrackId) connection=\(normalizedId)"
            )
            return false
        }

        logger.log(
            level: .warning,
            message: "Android participant renderer attach rejected disposed track participant=\(participantId) trackId=\(attachTrackId); waiting for refreshed receiver"
        )
        if let remoteSdp,
           let freshTrack = androidResolveLiveRemoteCameraTrack(
            participantId: participantId,
            connection: &connection,
            remoteSdp: remoteSdp,
            preferFreshFromPeerConnection: true
           ),
           freshTrack.isLiveVideoTrack {
            _ = Self.claimRemoteCameraTrack(
                freshTrack,
                participantId: participantId,
                in: &connection,
                allowReplacingExistingStableOwner: true
            )
            if let liveTrackId = freshTrack.trackIdIfAvailable {
                rememberAndroidResolvedRemoteCameraMedia(
                    participantId: participantId,
                    trackId: liveTrackId,
                    mid: androidResolvedRemoteCameraMid(participantId: participantId, in: connection),
                    in: &connection
                )
            }
            await manager.updateConnection(id: connection.id, with: connection)
            let swapTrackId = freshTrack.trackIdIfAvailable ?? attachTrackId
            let didSwapAttach = view.attach(freshTrack)
            logger.log(
                level: didSwapAttach ? .info : .warning,
                message: "Android participant renderer native-source swap attach participant=\(participantId) trackId=\(swapTrackId) attached=\(didSwapAttach) connection=\(normalizedId)"
            )
            if AndroidMultipartyVideoLayout.participantRendererAttachSucceeded(
                attachAcknowledged: didSwapAttach,
                hasActiveSink: view.hasActiveSink()
            ) {
                return true
            }
        }
        notifyParticipantCameraRendererSinkRefreshIfNeeded(
            connectionId: normalizedId,
            participantIds: [participantId]
        )
        return false
    }
    
    /// Remove remote video renderer.
    func removeRemote(view: AndroidSampleCaptureView, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Removing remote video renderer for connection: \(connectionId)")
        pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        if let remoteTrack = connection.remoteVideoTrack {
            view.detach(remoteTrack)
        }
    }

    /// Remove remote video renderer for a specific participant.
    func removeRemoteForParticipant(view: AndroidSampleCaptureView, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Removing remote renderer for participant=\(participantId) connection=\(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        view.clearSurfaceReadyRetry()
        if let track = connection.remoteVideoTracksByParticipantId[participantId] {
            view.detach(track)
        }
    }
    
    /// Remove local video renderer
    func removeLocal(view: AndroidPreviewCaptureView, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Removing local video renderer for connection: \(connectionId)")
        pendingLocalVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
        let manager = connectionManager as RTCConnectionManager
        guard let localVideoTrack: RTCVideoTrack = await manager.findConnection(with: normalizedId)?.localVideoTrack else { return }
        view.detach(localVideoTrack)
    }

    /// Returns whether a remote screen share track is mapped for the participant.
    func hasMappedRemoteScreenTrack(connectionId: String, participantId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager

        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            return false
        }

        var screenTrack = connection.remoteScreenTracksByParticipantId[participantId]
        if screenTrack == nil {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            if !participantKey.isEmpty {
                screenTrack = connection.remoteScreenTracksByParticipantId.first {
                    Self.conferenceParticipantIdentityKey($0.key) == participantKey
                }?.value
            }
        }

        return screenTrack != nil
    }

    @discardableResult
    func renderRemoteScreenVideo(to view: AndroidSampleCaptureView, connectionId: String, participantId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote screen video for connection=\(connectionId) participant=\(participantId)")
        let manager = connectionManager as RTCConnectionManager

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "renderRemoteScreenVideo: connection not found for \(connectionId)")
            return false
        }

        // Prefer per-participant lookup, fall back to legacy single track
        var screenTrack = connection.remoteScreenTracksByParticipantId[participantId]
        if screenTrack == nil {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            if !participantKey.isEmpty {
                screenTrack = connection.remoteScreenTracksByParticipantId.first {
                    Self.conferenceParticipantIdentityKey($0.key) == participantKey
                }?.value
            }
        }
        if screenTrack == nil {
            screenTrack = connection.remoteScreenTrack
                ?? rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection)
            if let screenTrack {
                connection.remoteScreenTrack = screenTrack
                await manager.updateConnection(id: normalizedId, with: connection)
            }
        }

        if let screenTrack {
            _ = view.attach(screenTrack)
            logger.log(level: .info, message: "Remote screen renderer attached for participant=\(participantId)")
            return true
        } else {
            logger.log(level: .warning, message: "renderRemoteScreenVideo: screen track not available yet for participant=\(participantId)")
            return false
        }
    }

    /// Removes a renderer previously bound via `renderRemoteScreenVideo`.
    func removeRemoteScreenVideoRenderer(_ view: AndroidSampleCaptureView, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        let screenTrack = connection.remoteScreenTracksByParticipantId[participantId]
            ?? (!participantKey.isEmpty
                ? connection.remoteScreenTracksByParticipantId.first {
                    Self.conferenceParticipantIdentityKey($0.key) == participantKey
                }?.value
                : nil)
            ?? connection.remoteScreenTrack
        if let screenTrack {
            view.detach(screenTrack)
        }
    }
#else
    func renderLocalVideo(to renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering local video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.localVideoTrack?.add(renderer)
    }

    @discardableResult
    func renderLocalScreenVideo(to renderer: RTCVideoRenderWrapper, connectionId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering local screen video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .warning, message: "renderLocalScreenVideo: connection not found for \(connectionId)")
            return false
        }
        guard let screenTrack = connection.localScreenTrack else {
            logger.log(level: .warning, message: "renderLocalScreenVideo: local screen track not found for \(connectionId)")
            return false
        }
        screenTrack.remove(renderer)
        screenTrack.add(renderer)
#if os(macOS)
        _macScreenCaptureSourceStorage?.addLocalPreviewRenderer(renderer)
#endif
        logger.log(level: .info, message: "Local screen renderer attached trackId=\(screenTrack.trackId)")
        return true
    }

    func removeLocalScreenVideoRenderer(_ renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
#if os(macOS)
        _macScreenCaptureSourceStorage?.removeLocalPreviewRenderer(renderer)
#endif
        connection.localScreenTrack?.remove(renderer)
    }

    func renderRemoteVideo(to renderer: RTCVideoRenderWrapper, with connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
            logger.log(level: .trace, message: "Rendering remote video for connection: \(connectionId)")
        }
        let manager = connectionManager as RTCConnectionManager

        // Keep the renderer request registered even after an optimistic attach.
        // SFU/Unified Plan flows can surface a placeholder receiver track before the
        // actual inbound receiver is finalized; `didAddReceiver` must be able to rebind.
        pendingRemoteVideoRenderersByConnectionId[normalizedId] = renderer

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "Connection not found for: \(connectionId) (normalized=\(normalizedId))")
            return
        }

        let cachedTrack = connection.remoteVideoTrack
#if canImport(WebRTC) && !os(Android)
        let resolvedTrack = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: connection)
            ?? Self.resolveLiveInboundCameraVideoTrack(
                from: connection.peerConnection,
                preferringRemoteParticipantId: oneToOneSfuRemoteTrackOwnerId(connection: connection)
            )
#else
        let resolvedTrack = Self.resolveLiveInboundCameraVideoTrack(
            from: connection.peerConnection,
            preferringRemoteParticipantId: connection.remoteParticipantId
        )
#endif
        if let resolvedTrack,
           cachedTrack == nil || cachedTrack?.readyState == .ended || cachedTrack?.trackId != resolvedTrack.trackId {
            if Self.oneToOneSfuRemoteTrackWouldDowngradeRelayToPlaceholder(
                previousTrackId: cachedTrack?.trackId,
                resolvedTrackId: resolvedTrack.trackId
            ) {
                logger.log(
                    level: .info,
                    message: "renderRemoteVideo keeping SFU relay track over placeholder connection=\(normalizedId) trackId=\(cachedTrack?.trackId ?? "nil") placeholderTrackId=\(resolvedTrack.trackId)"
                )
            } else {
                connection.remoteVideoTrack = resolvedTrack
                logger.log(
                    level: .info,
                    message: "renderRemoteVideo resolved live inbound camera track connection=\(normalizedId) trackId=\(resolvedTrack.trackId) previousTrackId=\(cachedTrack?.trackId ?? "nil")"
                )
            }
        }
        
        if let videoTrack = connection.remoteVideoTrack {
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                logger.log(level: .trace, message: "Found remote video track, attaching renderer")
                logger.log(level: .trace, message: "Video track details - trackId: \(videoTrack.trackId), enabled: \(videoTrack.isEnabled), readyState: \(videoTrack.readyState.rawValue)")
            }

            let receiveKeyReady = oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(normalizedId))
            if Self.shouldDeferOneToOneSfuRemoteRendererAttach(
                isOneToOneSfuRoom: Self.isTrueOneToOneSfuRoom(call: connection.call),
                frameEncryptionEnabled: enableEncryption,
                receiveKeyReady: receiveKeyReady
            ) {
                logger.log(
                    level: .info,
                    message: "Deferring 1:1 SFU remote renderer attach until call_cipher receive key is installed connId=\(normalizedId)"
                )
                await manager.updateConnection(id: normalizedId, with: connection)
                return
            }
            if sfuRenegotiationReceiverCryptorRebindIsDeferred(for: normalizedId) {
                logger.log(
                    level: .info,
                    message: "Deferring 1:1 SFU remote renderer attach until SFU renegotiation answer completes connId=\(normalizedId)"
                )
                await manager.updateConnection(id: normalizedId, with: connection)
                return
            }

            if remoteVideoRendererAttachedTrackIdByConnectionId[normalizedId] == videoTrack.trackId {
                let receiverDrifted = inboundRemoteVideoRendererRebindNeeded(
                    connection: connection,
                    liveTrack: videoTrack
                )
                if !receiverDrifted {
                    logger.log(
                        level: .debug,
                        message: "Remote renderer already attached to live track connection=\(normalizedId) trackId=\(videoTrack.trackId)"
                    )
                    await manager.updateConnection(id: normalizedId, with: connection)
                    return
                }
                remoteVideoRendererAttachedTrackIdByConnectionId.removeValue(forKey: normalizedId)
            }
            
            // Check if the receiver has a track and if it's the same as the video track
            if let videoReceiver = connection.peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver {
                if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                    logger.log(level: .trace, message: "Receiver track: \(videoReceiver.track != nil ? "exists" : "nil"), trackId: \(videoReceiver.track?.trackId ?? "nil")")
                    logger.log(level: .trace, message: "Video track matches receiver track: \(videoReceiver.track == videoTrack)")
                    logger.log(level: .trace, message: "PeerConnection media summary: transceivers=\(connection.peerConnection.transceivers.count) receivers=\(connection.peerConnection.receivers.count) senders=\(connection.peerConnection.senders.count)")
                }

                // Check if FrameCryptor is attached to this receiver (only relevant when frame encryption is enabled).
                // SFU group calls store inbound cryptors in `videoReceiverCryptorsByParticipantId`; the legacy
                // `videoFrameCryptor` slot may be nil until a single receiver is chosen or after UUID→stable rebind.
                if enableEncryption {
                    let hasInboundVideoCryptor = connection.videoFrameCryptor != nil
                        || !connection.videoReceiverCryptorsByParticipantId.isEmpty
                    if hasInboundVideoCryptor {
                        if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled, let frameCryptor = connection.videoFrameCryptor {
                            logger.log(level: .trace, message: "FrameCryptor exists and is attached to receiver")
                            logger.log(level: .trace, message: "FrameCryptor enabled: \(frameCryptor.enabled)")
                        }
                    } else {
                        logger.log(level: .warning, message: "FrameCryptor is nil (enableEncryption=true) - frames won't be decrypted!")
                    }
                }
            }
            if let cachedTrack, cachedTrack !== videoTrack {
                cachedTrack.remove(renderer)
            }
            connection.remoteVideoTrack?.remove(renderer)
            videoTrack.add(renderer)
            remoteVideoRendererAttachedTrackIdByConnectionId[normalizedId] = videoTrack.trackId
            logger.log(
                level: .info,
                message: "Remote renderer attached connection=\(normalizedId) trackId=\(videoTrack.trackId) readyState=\(videoTrack.readyState.rawValue) enabled=\(videoTrack.isEnabled)"
            )

            // One-shot stats snapshot shortly after attaching the renderer.
            // This tells us definitively whether:
            // - video RTP is arriving (packetsReceived > 0)
            // - but not decoding (framesDecoded == 0) -> likely decrypt/decoder pipeline
            // - or not arriving at all (packetsReceived == 0) -> network/remote sender/ICE path
            #if canImport(WebRTC)
            logRtpStatsSnapshotOnce(
                connectionId: normalizedId,
                delayNanoseconds: 2_000_000_000,
                reason: "afterAttachRemoteRenderer")
            startInboundVideoFlowProbe(connectionId: normalizedId)
            #endif
        } else {
            logger.log(
                level: .warning,
                message: "Remote video track is nil after renderer request connection=\(normalizedId) media=\(RTCPeerConnectionMediaDiagnostics.summary(connection.peerConnection))"
            )
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                logger.log(level: .trace, message: "Remote renderer buffered; will attach when receiver/track is added")
                for (index, transceiver) in connection.peerConnection.transceivers.enumerated() {
                    logger.log(level: .trace, message: "Transceiver \(index): mediaType=\(transceiver.mediaType), receiver.track=\(String(describing: transceiver.receiver.track))")
                }
            }
        }
        await manager.updateConnection(id: normalizedId, with: connection)
    }

    /// Binds a renderer to a specific remote participant's camera track.
    ///
    /// Group/conference calls receive multiple camera tracks over one SFU PeerConnection; the
    /// participant id identifies the track owner and must map to
    /// ``RTCConnection/remoteVideoTracksByParticipantId``.
    @discardableResult
    func renderRemoteVideoForParticipant(
        to renderer: RTCVideoRenderWrapper,
        connectionId: String,
        participantId: String,
        forceParticipantRendererRebind: Bool = false
    ) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote camera for participant=\(participantId) connection=\(connectionId)")
        let manager = connectionManager as RTCConnectionManager

        guard !isConnectionFinishingOrEnded(normalizedId) else {
            logger.log(level: .info, message: "Skipping participant renderer attach for ended connection=\(normalizedId) participant=\(participantId)")
            return false
        }

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "renderRemoteVideoForParticipant: connection not found for \(connectionId)")
            return false
        }

        if isGroupCallConnection(normalizedId),
           shouldDeferSfuGroupParticipantVideoAttach(for: normalizedId) {
            logger.log(
                level: .info,
                message: "Deferred participant renderer attach during SFU renegotiation participant=\(participantId) connection=\(normalizedId)"
            )
            return false
        }

#if canImport(WebRTC) && !os(Android)
        if refreshGroupParticipantCameraTrackBindingIfNeeded(
            connection: &connection,
            participantId: participantId
        ) {
            await manager.updateConnection(id: connection.id, with: connection)
            if let updated = await manager.findConnection(with: normalizedId) {
                connection = updated
            }
        }
#endif

        guard let (mappedKey, videoTrack) = remoteCameraTrackBinding(in: connection, participantId: participantId) else {
            logger.log(level: .warning, message: "renderRemoteVideoForParticipant: camera track not found for participant=\(participantId)")
            return false
        }

        let attachmentKey = remoteParticipantVideoRendererAttachmentKey(
            connectionId: normalizedId,
            participantId: participantId
        )
#if canImport(WebRTC) && !os(Android)
        var trackForRender = videoTrack
        if let liveTrack = resolvedLiveGroupParticipantCameraTrack(
            in: connection,
            participantId: participantId,
            mappedTrack: videoTrack
        ) {
            trackForRender = liveTrack
            if liveTrack !== videoTrack {
                if Self.claimRemoteCameraTrack(
                    liveTrack,
                    participantId: participantId,
                    in: &connection,
                    allowReplacingExistingStableOwner: true
                ) {
                    await manager.updateConnection(id: connection.id, with: connection)
                }
            }
        } else if let receiver = Self.resolveLiveInboundCameraVideoReceiver(
            from: connection.peerConnection,
            matchingTrackId: videoTrack.trackId
        ), let receiverTrack = receiver.track as? WebRTC.RTCVideoTrack,
           receiverTrack.readyState != .ended {
            trackForRender = receiverTrack
        }

        let attachmentValue = remoteParticipantVideoRendererAttachmentValue(
            track: trackForRender,
            renderer: renderer,
            peerConnection: connection.peerConnection
        )
        if !forceParticipantRendererRebind,
           AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: remoteParticipantVideoRendererAttachedTrackIdByKey[attachmentKey],
            liveAttachmentValue: attachmentValue
        ) {
            logger.log(
                level: .debug,
                message: "Participant camera renderer already bound to live receiver participant=\(participantId) mappedKey=\(mappedKey) trackId=\(trackForRender.trackId) connection=\(normalizedId) binding=\(await participantCameraRendererBindingDiagnostics(connectionId: normalizedId, participantId: participantId, renderer: renderer))"
            )
            return true
        }

        if trackForRender !== videoTrack {
            videoTrack.remove(renderer)
        }
        trackForRender.remove(renderer)
        trackForRender.add(renderer)
        remoteParticipantVideoRendererAttachedTrackIdByKey[attachmentKey] = attachmentValue
        logger.log(level: .info, message: "Remote camera renderer attached for participant=\(participantId) mappedKey=\(mappedKey) trackId=\(trackForRender.trackId) binding=\(await participantCameraRendererBindingDiagnostics(connectionId: normalizedId, participantId: participantId, renderer: renderer))")
#else
        let attachmentValue = "\(videoTrack.trackId)|\(ObjectIdentifier(videoTrack))|\(ObjectIdentifier(renderer))"
        if remoteParticipantVideoRendererAttachedTrackIdByKey[attachmentKey] == attachmentValue {
            logger.log(
                level: .debug,
                message: "Participant camera renderer already attached participant=\(participantId) mappedKey=\(mappedKey) trackId=\(videoTrack.trackId) connection=\(normalizedId)"
            )
            return true
        }

        videoTrack.remove(renderer)
        videoTrack.add(renderer)
        remoteParticipantVideoRendererAttachedTrackIdByKey[attachmentKey] = attachmentValue
        logger.log(level: .info, message: "Remote camera renderer attached for participant=\(participantId) mappedKey=\(mappedKey) trackId=\(videoTrack.trackId) connection=\(normalizedId)")
#endif
        #if canImport(WebRTC)
        logRtpStatsSnapshotOnce(
            connectionId: normalizedId,
            delayNanoseconds: 2_000_000_000,
            reason: "afterAttachRemoteParticipantRenderer:\(participantId)")
        startInboundVideoFlowProbe(connectionId: normalizedId)
        #endif
        return true
    }

    /// Whether inbound remote video should be treated as live for UI (camera-off overlay).
    ///
    /// On the receive side, `RTCVideoTrack.isEnabled` is mostly a **local** output toggle and often
    /// stays `true` when the sender stops camera capture. This WebRTC Swift module does not expose
    /// `isMuted` on `RTCVideoTrack`, so call sites should also use frame timing (e.g.
    /// `SampleBufferViewRenderer.ageMillisecondsSinceLastVideoFrameCallback()`) to detect a frozen
    /// picture when the peer turns video off.
    ///
    /// Returns `true` when there is no receiver track yet (still connecting).
    func inboundRemoteVideoTrackAppearsEnabled(connectionId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await connectionManager.findConnection(with: normalizedId) else {
            return true
        }
        if let track = connection.remoteVideoTrack {
            return track.isEnabled
        }
        if let track = connection.remoteVideoTracksByParticipantId.values.first {
            return track.isEnabled
        }
        return true
    }

    /// Whether a remote participant's camera track is enabled (group / per-tile overlays).
    func inboundRemoteParticipantVideoTrackAppearsEnabled(
        connectionId: String,
        participantId: String
    ) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        let trimmedParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedParticipantId.isEmpty else { return true }
        guard let connection = await connectionManager.findConnection(with: normalizedId) else {
            return true
        }
        if let track = connection.remoteVideoTracksByParticipantId[trimmedParticipantId] {
            return track.isEnabled
        }
        if let key = connection.remoteVideoTracksByParticipantId.keys.first(where: {
            $0.caseInsensitiveCompare(trimmedParticipantId) == .orderedSame
        }), let track = connection.remoteVideoTracksByParticipantId[key] {
            return track.isEnabled
        }
        return true
    }

    /// Adds another sink for the remote video track without touching ``pendingRemoteVideoRenderersByConnectionId``
    /// (used for Picture in Picture so the in-call renderer stays the canonical pending target).
    func addAuxiliaryRemoteVideoRenderer(_ renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Adding auxiliary remote video renderer (e.g. PiP) for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .warning, message: "addAuxiliaryRemoteVideoRenderer: connection not found for \(connectionId)")
            return
        }
        if connection.remoteVideoTrack == nil {
#if canImport(WebRTC) && !os(Android)
            connection.remoteVideoTrack = Self.resolveLiveInboundCameraVideoTrack(
                from: connection.peerConnection,
                preferringRemoteParticipantId: oneToOneSfuRemoteTrackOwnerId(connection: connection)
            )
#else
            connection.remoteVideoTrack = Self.resolveLiveInboundCameraVideoTrack(
                from: connection.peerConnection,
                preferringRemoteParticipantId: connection.remoteParticipantId
            )
#endif
        }
        guard let videoTrack = connection.remoteVideoTrack else {
            logger.log(level: .warning, message: "addAuxiliaryRemoteVideoRenderer: remote video track nil")
            return
        }
        let receiveKeyReady = oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(normalizedId))
        if Self.shouldDeferOneToOneSfuRemoteRendererAttach(
            isOneToOneSfuRoom: Self.isTrueOneToOneSfuRoom(call: connection.call),
            frameEncryptionEnabled: enableEncryption,
            receiveKeyReady: receiveKeyReady
        ) {
            if !connection.auxiliaryRemoteVideoRenderers.contains(where: { $0 === renderer }) {
                connection.auxiliaryRemoteVideoRenderers.append(renderer)
            }
            await manager.updateConnection(id: normalizedId, with: connection)
            logger.log(
                level: .info,
                message: "Deferring 1:1 SFU auxiliary remote renderer attach until receive key is installed connId=\(normalizedId)"
            )
            return
        }
        if sfuRenegotiationReceiverCryptorRebindIsDeferred(for: normalizedId) {
            if !connection.auxiliaryRemoteVideoRenderers.contains(where: { $0 === renderer }) {
                connection.auxiliaryRemoteVideoRenderers.append(renderer)
            }
            await manager.updateConnection(id: normalizedId, with: connection)
            logger.log(
                level: .info,
                message: "Deferring 1:1 SFU auxiliary remote renderer attach until SFU renegotiation answer completes connId=\(normalizedId)"
            )
            return
        }
        if !connection.auxiliaryRemoteVideoRenderers.contains(where: { $0 === renderer }) {
            connection.auxiliaryRemoteVideoRenderers.append(renderer)
        }
        videoTrack.add(renderer)
        await manager.updateConnection(id: normalizedId, with: connection)
    }

    /// Adds a PiP/auxiliary sink to a specific participant camera track.
    @discardableResult
    func addAuxiliaryRemoteVideoRenderer(
        _ renderer: RTCVideoRenderWrapper,
        connectionId: String,
        participantId: String
    ) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        let participantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantId.isEmpty else {
            logger.log(level: .warning, message: "addAuxiliaryRemoteVideoRenderer: empty participant id for connection \(connectionId)")
            return false
        }
        logger.log(level: .info, message: "Adding auxiliary remote video renderer for participant=\(participantId) connection=\(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .warning, message: "addAuxiliaryRemoteVideoRenderer: connection not found for \(connectionId)")
            return false
        }
        guard let binding = remoteCameraTrackBinding(in: connection, participantId: participantId) else {
            logger.log(level: .warning, message: "addAuxiliaryRemoteVideoRenderer: camera track not found for participant=\(participantId)")
            return false
        }
        if !connection.auxiliaryRemoteVideoRenderers.contains(where: { $0 === renderer }) {
            connection.auxiliaryRemoteVideoRenderers.append(renderer)
        }
        binding.track.remove(renderer)
        binding.track.add(renderer)
        await manager.updateConnection(id: normalizedId, with: connection)
        return true
    }

    /// Removes an auxiliary sink added via ``addAuxiliaryRemoteVideoRenderer`` only (does not clear pending renderer state).
    func removeAuxiliaryRemoteVideoRenderer(_ renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Removing auxiliary remote video renderer for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.auxiliaryRemoteVideoRenderers.removeAll { $0 === renderer }
        connection.remoteVideoTrack?.remove(renderer)
        await manager.updateConnection(id: normalizedId, with: connection)
    }

    /// Removes a participant-specific auxiliary sink added for PiP/group-call rendering.
    func removeAuxiliaryRemoteVideoRenderer(
        _ renderer: RTCVideoRenderWrapper,
        connectionId: String,
        participantId: String
    ) async {
        let normalizedId = connectionId.normalizedConnectionId
        let participantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log(level: .info, message: "Removing auxiliary remote video renderer for participant=\(participantId) connection=\(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.auxiliaryRemoteVideoRenderers.removeAll { $0 === renderer }
        remoteCameraTrackBinding(in: connection, participantId: participantId)?.track.remove(renderer)
        await manager.updateConnection(id: normalizedId, with: connection)
    }

    /// Group/conference SFU: after renegotiation the active `RTCRtpReceiver` can swap while the
    /// stored `RTCVideoTrack` id stays stable. Renderers stay attached to a stale sink and never
    /// receive decoded frames even though FrameCryptor was rebound to the live receiver.
    func rebindGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(
        connectionId: String,
        forceParticipantSinkRefreshWhenTrackIdentityMatches: Bool = false
    ) async {
#if canImport(WebRTC) && !os(Android)
        let norm = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: norm) else { return }
        guard isGroupCallConnection(connection.id) else { return }
        guard !Self.isTrueOneToOneSfuRoom(call: connection.call) else { return }

        let remoteSdp = connection.peerConnection.remoteDescription?.sdp ?? ""
        let advertisedOwnersByTrackId = Self.advertisedRemoteCameraOwnersByTrackId(in: remoteSdp)
        var didRebindAny = false
        var pendingTrackEvents: [RemoteParticipantTrackEvent] = []
        var participantsNeedingSinkRefresh: [String] = []
        let renegotiationInFlight = isSfuGroupRenegotiationInFlight(for: norm)
        let duplicateTrackIds = Set(
            connection.remoteVideoTracksByParticipantId.values.map(\.trackId).filter { trackId in
                connection.remoteVideoTracksByParticipantId.values.filter { $0.trackId == trackId }.count > 1
            }
        )
        for trackId in duplicateTrackIds {
            let candidates = connection.remoteVideoTracksByParticipantId
                .filter { $0.value.trackId == trackId }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            guard candidates.count > 1 else { continue }
            let advertisedOwnerKey = advertisedOwnersByTrackId[trackId].map(Self.conferenceParticipantIdentityKey)
            let keepKey = candidates.first { candidate in
                guard let advertisedOwnerKey, !advertisedOwnerKey.isEmpty else { return false }
                return Self.conferenceParticipantIdentityKey(candidate.key) == advertisedOwnerKey
            }?.key ?? candidates.first?.key
            for candidate in candidates where candidate.key != keepKey {
                connection.remoteVideoTracksByParticipantId.removeValue(forKey: candidate.key)
                didRebindAny = true
                logger.log(
                    level: .warning,
                    message: "Removed duplicate SFU camera mapping participant=\(candidate.key) trackId=\(trackId) kept=\(keepKey ?? "nil") conn=\(norm)"
                )
                pendingTrackEvents.append(
                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: candidate.key, kind: "video", isActive: false)
                )
            }
        }

        for (participantId, storedTrack) in connection.remoteVideoTracksByParticipantId {
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard storedTrack.readyState != .ended else { continue }
            let participantKey = Self.conferenceParticipantIdentityKey(trimmed)
            let advertisedTrackIdsForParticipant = Set(advertisedOwnersByTrackId.compactMap { trackId, owner -> String? in
                Self.conferenceParticipantIdentityKey(owner) == participantKey ? trackId : nil
            })

            guard let liveTrack = Self.resolveLiveGroupParticipantCameraTrack(
                storedTrackId: storedTrack.trackId,
                advertisedTrackIds: advertisedTrackIdsForParticipant,
                in: connection.peerConnection
            ) else {
                connection.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
                didRebindAny = true
                logger.log(
                    level: .warning,
                    message: "Removed stale SFU group camera mapping participant=\(trimmed) storedTrackId=\(storedTrack.trackId) conn=\(norm)"
                )
                pendingTrackEvents.append(
                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: trimmed, kind: "video", isActive: false)
                )
                continue
            }

            if storedTrack === liveTrack, storedTrack.trackId == liveTrack.trackId {
                if connection.remoteVideoTrack == nil {
                    connection.remoteVideoTrack = liveTrack
                    didRebindAny = true
                }
                if forceParticipantSinkRefreshWhenTrackIdentityMatches {
                    clearRemoteParticipantVideoRendererAttachment(connectionId: norm, participantId: trimmed)
                    participantsNeedingSinkRefresh.append(trimmed)
                    didRebindAny = true
                }
                continue
            }

            logger.log(
                level: .info,
                message: "\(renegotiationInFlight ? "SFU group renegotiation" : "Live receiver wrapper sync"): rebinding remote camera participant=\(trimmed) oldTrackId=\(storedTrack.trackId) newTrackId=\(liveTrack.trackId) conn=\(norm)"
            )

            let advertisedParticipantKey = advertisedOwnersByTrackId[liveTrack.trackId]
            let allowOwnershipTransfer = advertisedParticipantKey == Self.conferenceParticipantIdentityKey(trimmed)
            guard Self.claimRemoteCameraTrack(
                liveTrack,
                participantId: trimmed,
                in: &connection,
                allowReplacingExistingStableOwner: allowOwnershipTransfer
            ) else {
                connection.remoteVideoTracksByParticipantId.removeValue(forKey: participantId)
                didRebindAny = true
                logger.log(
                    level: .warning,
                    message: "Rejected SFU group camera rebind duplicate participant=\(trimmed) trackId=\(liveTrack.trackId) conn=\(norm)"
                )
                pendingTrackEvents.append(
                    RemoteParticipantTrackEvent(connectionId: connection.id, participantId: trimmed, kind: "video", isActive: false)
                )
                continue
            }
            if connection.remoteVideoTrack === storedTrack || connection.remoteVideoTrack == nil {
                connection.remoteVideoTrack = liveTrack
            }
            clearRemoteParticipantVideoRendererAttachment(connectionId: norm, participantId: trimmed)
            participantsNeedingSinkRefresh.append(trimmed)
            didRebindAny = true
        }

        guard didRebindAny else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
        for event in pendingTrackEvents {
            notifyRemoteParticipantTrackChanged(event)
        }
        notifyParticipantCameraRendererSinkRefreshIfNeeded(
            connectionId: norm,
            participantIds: participantsNeedingSinkRefresh
        )
        logRtpStatsSnapshotOnce(
            connectionId: norm,
            delayNanoseconds: 2_000_000_000,
            reason: "afterSfuGroupRenegotiationRemoteVideoRebind")
        startInboundVideoFlowProbe(connectionId: norm)
#endif
    }

    /// After SFU placeholder renegotiations transceivers can remain send-only even once the remote
    /// peer publishes `sendrecv` media. WebRTC may never fire `didStartReceivingOn` until the
    /// transceiver direction includes receive.
#if canImport(WebRTC) && !os(Android)
    func ensureAppleInboundCameraReceiveAfterSfuRenegotiation(
        connection: RTCConnection,
        remoteSdp: String
    ) async {
        guard Self.isTrueOneToOneSfuRoom(call: connection.call) else { return }

        // Only the transceiver that owns the local mic sender may be upgraded. SFU relay audio
        // transceivers (created by remote offers, no local sender track) must stay receive-only:
        // answering sendrecv on a relay mid mints a phantom local SSRC, the SFU reflects it back
        // as a "new" source, and every renegotiation adds one more audio m-line until
        // SetRemoteDescription fails with an audio demux conflict (production 1:1 outage).
        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .audio {
            guard transceiver.sender.track != nil else { continue }
            guard transceiver.direction != .sendRecv else { continue }
            var error: NSError?
            let prior = transceiver.direction
            transceiver.setDirection(.sendRecv, error: &error)
            logger.log(
                level: .info,
                message: "Upgraded 1:1 SFU audio transceiver direction \(prior)→sendRecv connection=\(connection.id) error=\(error?.localizedDescription ?? "nil")"
            )
        }

        guard Self.remoteSdpIncludesInboundVideoFromPeer(in: remoteSdp) else { return }

        let videoTransceivers = connection.peerConnection.transceivers.filter { $0.mediaType == .video }
        guard !videoTransceivers.isEmpty else { return }

        let cameraTransceiver = videoTransceivers.first { transceiver in
            if let trackId = transceiver.receiver.track?.trackId, Self.isScreenShareId(trackId) {
                return false
            }
            if videoTransceivers.count >= 2, transceiver === videoTransceivers.last {
                return false
            }
            return true
        } ?? videoTransceivers.first

        guard let cameraTransceiver else { return }
        guard cameraTransceiver.direction != .sendRecv else { return }

        var error: NSError?
        let prior = cameraTransceiver.direction
        cameraTransceiver.setDirection(.sendRecv, error: &error)
        logger.log(
            level: .info,
            message: "Upgraded 1:1 SFU camera transceiver direction \(prior)→sendRecv after remote published video connection=\(connection.id) trackId=\(cameraTransceiver.receiver.track?.trackId ?? "nil") error=\(error?.localizedDescription ?? "nil")"
        )
    }

    /// Whether an SFU screen transceiver should be upgraded from `.inactive` to `.recvOnly` so
    /// viewers can receive restarted remote screen media. Never upgrades sharer transceivers.
    static func shouldUpgradeAppleScreenTransceiverForInboundScreenReceive(
        localScreenShareActive: Bool,
        senderTrackId: String?,
        receiverTrackId: String?,
        cameraTrackIds: Set<String>,
        transceiverDirection: RTCRtpTransceiverDirection
    ) -> Bool {
        guard !localScreenShareActive else { return false }
        if let senderTrackId, !senderTrackId.isEmpty { return false }
        if let receiverTrackId, cameraTrackIds.contains(receiverTrackId) { return false }
        if transceiverDirection == .inactive { return true }
        if transceiverDirection == .sendRecv,
           let receiverTrackId,
           Self.isScreenShareId(receiverTrackId) {
            return true
        }
        return false
    }

    /// Restores `sendOnly` on the local screen transceiver before generating an SFU answer/offer
    /// when a stale inbound renegotiation briefly downgraded the dedicated screen slot.
    func ensureAppleOutboundScreenShareBeforeSfuNegotiation(connection: RTCConnection) async {
        await restoreAppleOutboundScreenShareTransceiver(connection: connection, context: "before local screen negotiation")
    }

    /// After the SFU answers a local screen-share offer, restore `sendOnly` on mid=2 and bind encryption.
    func ensureAppleOutboundScreenShareAfterSfuAnswer(connection: RTCConnection) async {
        await restoreAppleOutboundScreenShareTransceiver(connection: connection, context: "after SFU screen-share answer")
        await ensureAppleScreenSenderCryptorIfNeeded(connection: connection)
    }

    private func restoreAppleOutboundScreenShareTransceiver(
        connection: RTCConnection,
        context: String
    ) async {
        guard let localScreenTrack = connection.localScreenTrack else { return }
        let localTrackId = localScreenTrack.trackId
        let streamId = "\(Self.screenStreamPrefix)\(connection.localParticipantId)"

        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .video {
            let senderTrackId = transceiver.sender.track?.trackId ?? ""
            let isScreenSlot = senderTrackId == localTrackId
                || Self.isScreenShareId(senderTrackId)
                || transceiver.sender.streamIds.contains(where: Self.isScreenShareId)
            guard isScreenSlot else { continue }

            if transceiver.sender.track !== localScreenTrack {
                transceiver.sender.track = localScreenTrack
                transceiver.sender.streamIds = [streamId]
                logger.log(
                    level: .info,
                    message: "Reattached local screen track to SFU screen sender \(context) connection=\(connection.id) mid=\(transceiver.mid) trackId=\(localTrackId)"
                )
            } else if transceiver.sender.streamIds.isEmpty {
                transceiver.sender.streamIds = [streamId]
            }

            guard transceiver.direction != .sendOnly else { continue }

            var error: NSError?
            let prior = transceiver.direction
            transceiver.setDirection(.sendOnly, error: &error)
            logger.log(
                level: .info,
                message: "Restored SFU screen transceiver direction \(prior)→sendOnly \(context) connection=\(connection.id) mid=\(transceiver.mid) error=\(error?.localizedDescription ?? "nil")"
            )
        }
    }

    /// After SFU screen-share handoffs the dedicated screen transceiver can remain `.inactive` even
    /// when the remote offer advertises live screen media. WebRTC then answers `a=inactive` on
    /// mid=2 and viewers attach renderers to a track that never receives RTP.
    func ensureAppleInboundScreenReceiveAfterSfuRenegotiation(
        connection: RTCConnection,
        remoteSdp: String
    ) async {
        let localScreenShareActive = connection.localScreenTrack != nil
        if localScreenShareActive {
            logger.log(
                level: .info,
                message: "Skipping SFU inbound screen transceiver upgrade while local screen share is active connection=\(connection.id)"
            )
            return
        }

        var remoteSendingScreenMids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
        if Self.isTrueOneToOneSfuRoom(call: connection.call) {
            remoteSendingScreenMids.formUnion(Self.oneToOneSfuIncomingScreenShareVideoMids(in: remoteSdp))
        }
        guard !remoteSendingScreenMids.isEmpty else { return }

        let contractMid = ScreenShareGroupCallContract.MediaMid.screen.rawValue
        let cameraTrackIds = Set(
            connection.remoteVideoTracksByParticipantId.values.map(\.trackId)
        )

        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .video {
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty,
                  remoteSendingScreenMids.contains(mid)
            else { continue }

            if mid == contractMid,
               let track = transceiver.receiver.track as? RTCVideoTrack,
               Self.isScreenShareId(track.trackId),
               !track.isEnabled {
                track.isEnabled = true
                logger.log(
                    level: .info,
                    message: "Re-enabled contract-mid SFU screen receiver connection=\(connection.id) mid=\(mid) trackId=\(track.trackId)"
                )
            }

            guard Self.shouldUpgradeAppleScreenTransceiverForInboundScreenReceive(
                localScreenShareActive: localScreenShareActive,
                senderTrackId: transceiver.sender.track?.trackId,
                receiverTrackId: transceiver.receiver.track?.trackId,
                cameraTrackIds: cameraTrackIds,
                transceiverDirection: transceiver.direction
            ) else { continue }

            var error: NSError?
            let prior = transceiver.direction
            transceiver.setDirection(.recvOnly, error: &error)
            logger.log(
                level: .info,
                message: "Upgraded SFU screen transceiver direction \(prior)→recvOnly after remote published screen connection=\(connection.id) mid=\(mid) trackId=\(transceiver.receiver.track?.trackId ?? "nil") error=\(error?.localizedDescription ?? "nil")"
            )
        }

        retireStaleAppleInboundScreenShareReceivers(
            connection: connection,
            activeRelayMids: remoteSendingScreenMids
        )
    }

    /// Disables stale `screen_*` receivers on relay mids the current SFU offer no longer advertises.
    func retireStaleAppleInboundScreenShareReceivers(
        connection: RTCConnection,
        activeRelayMids: Set<String>
    ) {
        guard !activeRelayMids.isEmpty else { return }
        let contractMid = ScreenShareGroupCallContract.MediaMid.screen.rawValue

        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .video {
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty, !activeRelayMids.contains(mid) else { continue }
            guard let track = transceiver.receiver.track as? RTCVideoTrack else { continue }
            let isLegacyScreenTrack = Self.isScreenShareId(track.trackId)
            let isEscalatedRelayMid = (Int(mid) ?? -1) > (Int(contractMid) ?? -1)
            guard isLegacyScreenTrack || isEscalatedRelayMid else { continue }

            if track.isEnabled {
                track.isEnabled = false
                logger.log(
                    level: .info,
                    message: "Disabled stale SFU screen receiver track connection=\(connection.id) mid=\(mid) trackId=\(track.trackId)"
                )
            }

            guard transceiver.direction != .inactive else { continue }

            var error: NSError?
            let prior = transceiver.direction
            transceiver.setDirection(.inactive, error: &error)
            logger.log(
                level: .info,
                message: "Deactivated stale SFU screen transceiver direction \(prior)→inactive connection=\(connection.id) mid=\(mid) trackId=\(track.trackId) error=\(error?.localizedDescription ?? "nil")"
            )
        }
    }

    /// Group/conference SFU: after renegotiation the live screen `RTCRtpReceiver` can drift while
    /// the stored `RTCVideoTrack` id stays stable. Rebind the mapping and notify UI to reattach.
    func rebindGroupRemoteParticipantScreenAfterSfuRenegotiationIfNeeded(connectionId: String) async {
        let norm = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: norm) else { return }
        guard isGroupCallConnection(connection.id) else { return }
        guard !Self.isTrueOneToOneSfuRoom(call: connection.call) else { return }

        let remoteSdp = connection.peerConnection.remoteDescription?.sdp ?? ""
        let remoteSendingScreenMids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
            .union(Self.sfuRelayIncomingScreenShareVideoMids(in: remoteSdp))
        guard !remoteSendingScreenMids.isEmpty else { return }

        var didRebindAny = false
        for (participantId, storedTrack) in connection.remoteScreenTracksByParticipantId {
            let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let participantKey = Self.conferenceParticipantIdentityKey(trimmed)
            if !participantKey.isEmpty,
               connection.suppressedRemoteScreenShareParticipantIds.contains(participantKey) {
                continue
            }
            guard storedTrack.readyState != .ended else { continue }

            guard let liveTrack = Self.resolveLiveGroupParticipantScreenTrack(
                storedTrackId: storedTrack.trackId,
                participantId: trimmed,
                in: connection.peerConnection,
                cameraTrackIds: Set(connection.remoteVideoTracksByParticipantId.values.map(\.trackId)),
                activeIncomingScreenMids: remoteSendingScreenMids
            ) else { continue }

            let liveReceiverId = connection.peerConnection.transceivers
                .first(where: { $0.receiver.track === liveTrack })
                .map { String(describing: ObjectIdentifier($0.receiver)) }
            let storedReceiverId = connection.screenReceiverCryptorBindingsByParticipantId[trimmed]?.receiverId
                ?? connection.screenReceiverCryptorBindingsByParticipantId[participantId]?.receiverId
            let receiverDrifted = liveReceiverId != nil
                && storedReceiverId != nil
                && liveReceiverId != storedReceiverId
            guard liveTrack !== storedTrack || receiverDrifted else { continue }

            logger.log(
                level: .info,
                message: "SFU group renegotiation: rebinding remote screen participant=\(trimmed) oldTrackId=\(storedTrack.trackId) newTrackId=\(liveTrack.trackId) receiverDrifted=\(receiverDrifted) conn=\(norm)"
            )

            connection.remoteScreenTracksByParticipantId[trimmed] = liveTrack
            didRebindAny = true
            await connectionManager.updateConnection(id: connection.id, with: connection)

            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connection.id, participantId: trimmed, isActive: true)
            )

            if enableEncryption,
               let receiver = connection.peerConnection.transceivers
                .first(where: { $0.receiver.track === liveTrack || $0.receiver.track?.trackId == liveTrack.trackId })?
                .receiver {
                do {
                    try await createEncryptedFrame(
                        connection: connection,
                        kind: .screenReceiver(receiver),
                        participantIdOverride: trimmed
                    )
                    if let refreshed = await connectionManager.findConnection(with: norm) {
                        connection = refreshed
                    }
                } catch {
                    logger.log(
                        level: .warning,
                        message: "Failed to rebind screen receiver FrameCryptor after SFU screen track drift participant=\(trimmed) conn=\(norm): \(error)"
                    )
                }
            }
        }

        guard didRebindAny else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }
#endif

    /// Rebinds screen-share sender/receiver cryptors and track mappings after decode stalls.
    public func recoverInboundRemoteScreenAfterDecodeStall(connectionId: String) async {
#if canImport(WebRTC) && !os(Android)
        guard await isConnectionStillActiveForRecovery(connectionId) else { return }
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }

        if connection.localScreenTrack != nil {
            await restoreAppleOutboundScreenShareTransceiver(
                connection: connection,
                context: "after screen-share decode stall recovery"
            )
            await ensureAppleScreenSenderCryptorIfNeeded(connection: connection)
        }

        if let remoteSdp = connection.peerConnection.remoteDescription?.sdp {
            var activeRelayMids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
            if Self.isTrueOneToOneSfuRoom(call: connection.call) {
                activeRelayMids.formUnion(Self.oneToOneSfuIncomingScreenShareVideoMids(in: remoteSdp))
            }
            await ensureAppleInboundScreenReceiveAfterSfuRenegotiation(
                connection: connection,
                remoteSdp: remoteSdp
            )
            if let refreshed = await connectionManager.findConnection(with: connectionId) {
                retireStaleAppleInboundScreenShareReceivers(
                    connection: refreshed,
                    activeRelayMids: activeRelayMids
                )
            }
        }

        await reconcileAppleReceiverFrameCryptorsAfterSfuRenegotiation(connectionId: connectionId)
        await rebindGroupRemoteParticipantScreenAfterSfuRenegotiationIfNeeded(connectionId: connectionId)

        let activeIncomingScreenMids: Set<String> = {
            guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp else { return [] }
            var mids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
            if Self.isTrueOneToOneSfuRoom(call: connection.call) {
                mids.formUnion(Self.oneToOneSfuIncomingScreenShareVideoMids(in: remoteSdp))
            }
            return mids
        }()

        if var refreshed = await connectionManager.findConnection(with: connectionId) {
            for (participantId, storedTrack) in refreshed.remoteScreenTracksByParticipantId {
                guard let liveTrack = Self.resolveLiveGroupParticipantScreenTrack(
                    storedTrackId: storedTrack.trackId,
                    participantId: participantId,
                    in: refreshed.peerConnection,
                    cameraTrackIds: Set(refreshed.remoteVideoTracksByParticipantId.values.map(\.trackId)),
                    activeIncomingScreenMids: activeIncomingScreenMids
                ), liveTrack !== storedTrack else { continue }
                refreshed.remoteScreenTracksByParticipantId[participantId] = liveTrack
                notifyRemoteScreenTrackChanged(
                    RemoteScreenTrackEvent(connectionId: refreshed.id, participantId: participantId, isActive: true)
                )
            }
            await connectionManager.updateConnection(id: refreshed.id, with: refreshed)
        }
        let aggregateFlow = await evaluateInboundRemoteVideoFlow(connectionId: connectionId)
        let screenFlow = await evaluateInboundRemoteScreenVideoFlow(connectionId: connectionId)
        if aggregateFlow?.likelyCause == "transport_or_ice_instability"
            || screenFlow?.likelyCause == "transport_or_ice_instability" {
            await attemptIceRestartRenegotiationIfNeeded(
                connectionId: connectionId,
                reason: "screen_share_decode_recovery"
            )
        }

        logScreenShareDiagnostics(connectionId: connectionId, reason: "afterScreenShareDecodeStallRecovery")
#endif
    }

    /// Rebinds receiver FrameCryptors and the main remote renderer after decode stalls while RTP ingress continues.
    public func recoverInboundRemoteVideoAfterDecodeStall(connectionId: String) async {
#if canImport(WebRTC) && !os(Android)
        guard await isConnectionStillActiveForRecovery(connectionId) else { return }
        let norm = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: norm) else { return }
        pulseInboundRemoteCameraTracksForDecodeRecovery(connection: &connection)
        await connectionManager.updateConnection(id: connection.id, with: connection)
        clearRemoteParticipantVideoRendererAttachments(connectionId: connectionId)
        remoteVideoRendererAttachedTrackIdByConnectionId.removeValue(forKey: norm)
        await recoverInboundRemoteScreenAfterDecodeStall(connectionId: connectionId)
        await reconcileAppleReceiverFrameCryptorsAfterSfuRenegotiation(connectionId: connectionId)
        await rebindInboundRemoteVideoAfterSfuRenegotiationIfNeeded(call: connection.call)
        await rebindGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(
            connectionId: connectionId,
            forceParticipantSinkRefreshWhenTrackIdentityMatches: true
        )
#endif
    }

    /// Handles an Apple receiver decoder stall when diagnostics prove the UI renderer is already
    /// bound to the live receiver. Repeating a renderer detach/attach in that state does not move
    /// decode counters; refresh the receiver/key/SFU readiness path instead.
    public func recoverInboundRemoteParticipantVideoDecoderAfterMatchedBindingStall(
        connectionId: String,
        participantId: String
    ) async {
#if canImport(WebRTC) && !os(Android)
        guard await isConnectionStillActiveForRecovery(connectionId) else { return }
        let norm = connectionId.normalizedConnectionId
        let trimmedParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedParticipantId.isEmpty,
              var connection = await connectionManager.findConnection(with: norm) else {
            return
        }

        if refreshGroupParticipantCameraTrackBindingIfNeeded(
            connection: &connection,
            participantId: trimmedParticipantId
        ) {
            await connectionManager.updateConnection(id: connection.id, with: connection)
            if let updated = await connectionManager.findConnection(with: norm) {
                connection = updated
            }
        }
        pulseInboundRemoteCameraTracksForDecodeRecovery(
            connection: &connection,
            participantId: trimmedParticipantId
        )
        await connectionManager.updateConnection(id: connection.id, with: connection)
        clearRemoteParticipantVideoRendererAttachment(
            connectionId: norm,
            participantId: trimmedParticipantId
        )
        await reconcileAppleReceiverFrameCryptorsAfterSfuRenegotiation(connectionId: norm)
        await rebindGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(
            connectionId: norm,
            forceParticipantSinkRefreshWhenTrackIdentityMatches: true
        )

        if isGroupCallConnection(connection.id) {
            do {
                try await sendSfuGroupMediaReady(
                    sourceParticipantId: trimmedParticipantId,
                    roomId: connection.call.sharedCommunicationId,
                    call: connection.call
                )
                logger.log(
                    level: .info,
                    message: "Re-sent SFU media readiness after matched-binding decode stall participant=\(trimmedParticipantId) connection=\(norm)"
                )
            } catch {
                logger.log(
                    level: .warning,
                    message: "Failed to send SFU media readiness for decode stall participant=\(trimmedParticipantId) connection=\(norm): \(error.localizedDescription)"
                )
            }
        }

        logRtpStatsSnapshotOnce(
            connectionId: norm,
            delayNanoseconds: 2_000_000_000,
            reason: "afterMatchedBindingParticipantDecodeStallRecovery:\(trimmedParticipantId)"
        )
        startInboundVideoFlowProbe(connectionId: norm)
#endif
    }

#if canImport(WebRTC) && !os(Android)
    /// Toggles inbound remote camera tracks to restart a stuck WebRTC decode pipeline while the
    /// negotiated track id and receiver wrapper stay stable.
    private func pulseInboundRemoteCameraTracksForDecodeRecovery(
        connection: inout RTCConnection,
        participantId: String? = nil
    ) {
        var tracks: [WebRTC.RTCVideoTrack] = []
        if let participantId,
           let binding = remoteCameraTrackBinding(in: connection, participantId: participantId),
           binding.track.readyState != .ended {
            tracks.append(binding.track)
            if let liveTrack = resolvedLiveGroupParticipantCameraTrack(
                in: connection,
                participantId: participantId,
                mappedTrack: binding.track
            ), liveTrack !== binding.track,
               liveTrack.readyState != .ended {
                tracks.append(liveTrack)
            }
        } else if let mainTrack = connection.remoteVideoTrack, mainTrack.readyState != .ended {
            tracks.append(mainTrack)
        }
        for (owner, track) in connection.remoteVideoTracksByParticipantId {
            guard track.readyState != .ended else { continue }
            if let participantId,
               Self.conferenceParticipantIdentityKey(owner) != Self.conferenceParticipantIdentityKey(participantId),
               !tracks.contains(where: { $0 === track }) {
                continue
            }
            if tracks.contains(where: { $0 === track }) { continue }
            tracks.append(track)
        }
        guard !tracks.isEmpty else { return }
        for track in tracks {
            let wasEnabled = track.isEnabled
            track.isEnabled = false
            track.isEnabled = wasEnabled
        }
        logger.log(
            level: .info,
            message: "Pulsed inbound remote camera tracks for decode recovery connection=\(connection.id) participant=\(participantId ?? "<all>") trackCount=\(tracks.count)"
        )
    }
#endif

#if canImport(WebRTC)
    /// True only for a renderer-level rebind signal. Apple receiver wrapper identity is ignored
    /// because track replacement is handled by caller-side track id checks.
    private func inboundRemoteVideoRendererRebindNeeded(
        connection: RTCConnection,
        liveTrack: WebRTC.RTCVideoTrack
    ) -> Bool {
        guard Self.resolveLiveInboundCameraVideoReceiver(from: connection.peerConnection) != nil else {
            return false
        }
        let remoteOwner = remoteTrackOwnerParticipantId(connection: connection, call: connection.call)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remoteOwner.isEmpty,
           let binding = connection.videoReceiverCryptorBindingsByParticipantId[remoteOwner],
           binding.trackId == liveTrack.trackId {
            return false
        }
        for binding in connection.videoReceiverCryptorBindingsByParticipantId.values where binding.trackId == liveTrack.trackId {
            return false
        }
        return false
    }

    /// Live camera track for a mapped group participant, restricted to known owner evidence.
    static func resolveLiveGroupParticipantCameraTrack(
        storedTrackId: String,
        advertisedTrackIds: Set<String> = [],
        in peerConnection: WebRTC.RTCPeerConnection
    ) -> WebRTC.RTCVideoTrack? {
        let trimmedTrackId = storedTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTrackIds = Set(([trimmedTrackId] + Array(advertisedTrackIds)).filter { !$0.isEmpty })
        guard !candidateTrackIds.isEmpty else { return nil }

        var receivingMatch: WebRTC.RTCVideoTrack?
        var fallbackMatch: WebRTC.RTCVideoTrack?
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            guard let track = transceiver.receiver.track as? WebRTC.RTCVideoTrack else { continue }
            if Self.isScreenShareId(track.trackId) { continue }
            if track.readyState == .ended { continue }
            guard candidateTrackIds.contains(track.trackId) else { continue }
            fallbackMatch = track
            if isAppleTransceiverReceivingRemoteMedia(transceiver) {
                receivingMatch = track
            }
        }
        return receivingMatch ?? fallbackMatch
    }

    /// True when the transceiver can receive remote media (not stopped/inactive).
    static func isAppleTransceiverReceivingRemoteMedia(_ transceiver: WebRTC.RTCRtpTransceiver) -> Bool {
        switch transceiver.direction {
        case .recvOnly, .sendRecv:
            return true
        case .sendOnly, .stopped, .inactive:
            return false
        @unknown default:
            return false
        }
    }

    /// Live screen-share track for a mapped group participant on contract mid=2.
    static func resolveLiveGroupParticipantScreenTrack(
        storedTrackId: String,
        participantId: String,
        in peerConnection: WebRTC.RTCPeerConnection,
        cameraTrackIds: Set<String>,
        activeIncomingScreenMids: Set<String> = []
    ) -> WebRTC.RTCVideoTrack? {
        let trimmedTrackId = storedTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let participantKey = conferenceParticipantIdentityKey(participantId)
        let contractMid = ScreenShareGroupCallContract.MediaMid.screen.rawValue
        var contractScreenMatch: WebRTC.RTCVideoTrack?
        var explicitScreenMatch: WebRTC.RTCVideoTrack?
        var storedIdMatch: WebRTC.RTCVideoTrack?

        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            guard let track = transceiver.receiver.track as? WebRTC.RTCVideoTrack,
                  track.readyState != .ended
            else { continue }
            if cameraTrackIds.contains(track.trackId) { continue }

            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            let isReceiving = isAppleTransceiverReceivingRemoteMedia(transceiver)
            let isExplicitScreenForParticipant = isScreenShareId(track.trackId)
                && conferenceParticipantIdentityKey(participantIdFromScreenShareId(track.trackId) ?? "") == participantKey
            let isActiveContractScreenRelay = mid == contractMid
                && activeIncomingScreenMids.contains(contractMid)
                && !participantKey.isEmpty

            if isReceiving,
               mid == contractMid,
               isExplicitScreenForParticipant || isActiveContractScreenRelay {
                contractScreenMatch = track
            }

            if isReceiving,
               isExplicitScreenForParticipant {
                explicitScreenMatch = track
            }
            if isReceiving,
               !trimmedTrackId.isEmpty,
               track.trackId == trimmedTrackId {
                storedIdMatch = track
            }
        }

        return contractScreenMatch ?? explicitScreenMatch ?? storedIdMatch
    }

    /// True when WebRTC exposes a non-`screen_*` native track id on an SDP section that is
    /// explicitly active as the SFU screen-share relay.
    static func isLiveTrackOnActiveScreenRelayMid(
        _ track: WebRTC.RTCVideoTrack,
        in peerConnection: WebRTC.RTCPeerConnection,
        activeIncomingScreenMids: Set<String>
    ) -> Bool {
        guard !activeIncomingScreenMids.isEmpty else { return false }
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            guard let liveTrack = transceiver.receiver.track as? WebRTC.RTCVideoTrack else { continue }
            guard liveTrack === track || liveTrack.trackId == track.trackId else { continue }
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard activeIncomingScreenMids.contains(mid) else { continue }
            return isAppleTransceiverReceivingRemoteMedia(transceiver)
        }
        return false
    }

    /// First non-screen, non-ended camera receiver on the peer connection.
    static func resolveLiveInboundCameraVideoReceiver(from pc: WebRTC.RTCPeerConnection) -> WebRTC.RTCRtpReceiver? {
        resolveLiveInboundCameraVideoReceiver(from: pc, matchingTrackId: nil)
    }

    static func resolveLiveInboundCameraVideoReceiver(
        from pc: WebRTC.RTCPeerConnection,
        matchingTrackId: String?
    ) -> WebRTC.RTCRtpReceiver? {
        let trimmedTrackId = matchingTrackId?.trimmingCharacters(in: .whitespacesAndNewlines)
        var receivingMatch: WebRTC.RTCRtpReceiver?
        var fallbackMatch: WebRTC.RTCRtpReceiver?
        for t in pc.transceivers where t.mediaType == .video {
            guard let track = t.receiver.track as? WebRTC.RTCVideoTrack else { continue }
            if Self.isScreenShareId(track.trackId) { continue }
            if track.readyState == .ended { continue }
            if let trimmedTrackId, !trimmedTrackId.isEmpty, track.trackId != trimmedTrackId { continue }
            fallbackMatch = t.receiver
            if isAppleTransceiverReceivingRemoteMedia(t) {
                receivingMatch = t.receiver
            }
        }
        if receivingMatch != nil || fallbackMatch != nil {
            return receivingMatch ?? fallbackMatch
        }
        for r in pc.receivers {
            guard let track = r.track as? WebRTC.RTCVideoTrack else { continue }
            if Self.isScreenShareId(track.trackId) { continue }
            if track.readyState == .ended { continue }
            if let trimmedTrackId, !trimmedTrackId.isEmpty, track.trackId != trimmedTrackId { continue }
            return r
        }
        return nil
    }
#endif

    /// First non-screen, non-ended video track exposed by the peer connection's video transceivers / receivers.
    static func resolveLiveInboundCameraVideoTrack(from pc: WebRTC.RTCPeerConnection) -> WebRTC.RTCVideoTrack? {
        for t in pc.transceivers where t.mediaType == .video {
            guard let track = t.receiver.track as? WebRTC.RTCVideoTrack else { continue }
            if Self.isScreenShareId(track.trackId) { continue }
            if track.readyState == .ended { continue }
            return track
        }
        for r in pc.receivers {
            guard let track = r.track as? WebRTC.RTCVideoTrack else { continue }
            if Self.isScreenShareId(track.trackId) { continue }
            if track.readyState == .ended { continue }
            return track
        }
        return nil
    }

    /// Owner-aware variant of ``resolveLiveInboundCameraVideoTrack(from:)``.
    ///
    /// In 1:1 SFU rooms the *first* video transceiver is usually the receive half of our own send
    /// m-line — a placeholder that never carries remote media. Once the SFU renegotiates the remote
    /// peer's published tracks into the room, the remote SDP advertises them under the peer's msid
    /// stream label. Prefer the receiver track the SDP advertises as owned by `remoteParticipantId`
    /// so renderers (and receiver FrameCryptors resolved from the track map) bind to the receiver
    /// that actually carries inbound RTP. Falls back to the positional resolver when the SDP does
    /// not (yet) advertise any remote-owned camera track.
    static func resolveLiveInboundCameraVideoTrack(
        from pc: WebRTC.RTCPeerConnection,
        preferringRemoteParticipantId remoteParticipantId: String?
    ) -> WebRTC.RTCVideoTrack? {
#if canImport(WebRTC) && !os(Android)
        if let remoteParticipantId,
           let owned = resolveAdvertisedRemoteOwnedCameraVideoTrack(
            in: pc,
            remoteParticipantId: remoteParticipantId
           ) {
            return owned
        }
#endif
        return resolveLiveInboundCameraVideoTrack(from: pc)
    }

#if canImport(WebRTC) && !os(Android)
    /// Live, non-screen video receiver track that the remote SDP advertises (via msid stream
    /// label / track label) as owned by `remoteParticipantId`. Returns `nil` when the SDP does not
    /// advertise a remote-owned camera track or no live receiver carries one.
    static func resolveAdvertisedRemoteOwnedCameraVideoTrack(
        in pc: WebRTC.RTCPeerConnection,
        remoteParticipantId: String
    ) -> WebRTC.RTCVideoTrack? {
        let remoteKey = conferenceParticipantIdentityKey(remoteParticipantId)
        guard !remoteKey.isEmpty else { return nil }
        guard let remoteSdp = pc.remoteDescription?.sdp else { return nil }
        let ownedTrackIds = Set(
            advertisedRemoteCameraOwnersByTrackId(in: remoteSdp).compactMap { trackId, owner in
                conferenceParticipantIdentityKey(owner) == remoteKey ? trackId : nil
            }
        )
        guard !ownedTrackIds.isEmpty else { return nil }
        for t in pc.transceivers where t.mediaType == .video {
            guard let track = t.receiver.track as? WebRTC.RTCVideoTrack,
                  track.readyState != .ended,
                  !isScreenShareId(track.trackId),
                  ownedTrackIds.contains(track.trackId)
            else { continue }
            return track
        }
        for r in pc.receivers {
            guard let track = r.track as? WebRTC.RTCVideoTrack,
                  track.readyState != .ended,
                  !isScreenShareId(track.trackId),
                  ownedTrackIds.contains(track.trackId)
            else { continue }
            return track
        }
        return nil
    }
#endif

    /// Returns whether a live remote screen-share track is mapped for the participant.
    func hasMappedRemoteScreenTrack(connectionId: String, participantId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection: RTCConnection = await connectionManager.findConnection(with: normalizedId) else {
            return false
        }
        guard let binding = remoteScreenTrackBinding(in: connection, participantId: participantId) else {
            return false
        }
        return binding.track.readyState != .ended
    }

    /// Binds a renderer to a remote participant's screen-share track.
    ///
    /// This mirrors ``renderRemoteVideo(to:with:)`` but targets the screen track stored in
    /// ``RTCConnection/remoteScreenTracksByParticipantId`` instead of the camera track.
    @discardableResult
    func renderRemoteScreenVideo(to renderer: RTCVideoRenderWrapper, connectionId: String, participantId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote screen video for connection=\(connectionId) participant=\(participantId)")
        let manager = connectionManager as RTCConnectionManager

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "renderRemoteScreenVideo: connection not found for \(connectionId)")
            return false
        }

        guard let binding = remoteScreenTrackBinding(in: connection, participantId: participantId) else {
            logger.log(level: .warning, message: "renderRemoteScreenVideo: screen track not found for participant=\(participantId)")
            return false
        }

        var track = binding.track
        let activeIncomingScreenMids: Set<String>
#if canImport(WebRTC) && !os(Android)
        if isGroupCallConnection(normalizedId) {
            activeIncomingScreenMids = {
                guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp else { return [] }
                var mids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
                mids.formUnion(Self.sfuRelayIncomingScreenShareVideoMids(in: remoteSdp))
                if Self.isTrueOneToOneSfuRoom(call: connection.call) {
                    mids.formUnion(Self.oneToOneSfuIncomingScreenShareVideoMids(in: remoteSdp))
                }
                return mids
            }()
            if let liveTrack = Self.resolveLiveGroupParticipantScreenTrack(
                storedTrackId: track.trackId,
                participantId: participantId,
                in: connection.peerConnection,
                cameraTrackIds: Set(connection.remoteVideoTracksByParticipantId.values.map(\.trackId)),
                activeIncomingScreenMids: activeIncomingScreenMids
            ) {
            if liveTrack !== track {
                logger.log(
                    level: .info,
                    message: "renderRemoteScreenVideo: rebound live screen track participant=\(participantId) trackId=\(liveTrack.trackId)"
                )
            }
                connection.remoteScreenTracksByParticipantId[binding.key] = liveTrack
                await manager.updateConnection(id: normalizedId, with: connection)
                track = liveTrack
            }
        } else {
            activeIncomingScreenMids = []
        }
#endif

        if isGroupCallConnection(normalizedId),
           !Self.isTrueOneToOneSfuRoom(call: connection.call),
           !Self.isScreenShareId(track.trackId),
           !Self.isLiveTrackOnActiveScreenRelayMid(
            track,
            in: connection.peerConnection,
            activeIncomingScreenMids: activeIncomingScreenMids
           ) {
            logger.log(
                level: .warning,
                message: "renderRemoteScreenVideo: refusing non-screen SFU video track for participant=\(participantId) trackId=\(track.trackId)"
            )
            connection.remoteScreenTracksByParticipantId.removeValue(forKey: binding.key)
            await manager.updateConnection(id: normalizedId, with: connection)
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: normalizedId, participantId: participantId, isActive: false)
            )
            return false
        }

        track.remove(renderer)
        track.add(renderer)
        logger.log(level: .info, message: "Remote screen renderer attached for participant=\(participantId) resolvedKey=\(binding.key) trackId=\(track.trackId)")
        logScreenShareDiagnostics(connectionId: normalizedId, delayNanoseconds: 3_000_000_000, reason: "afterAttachRemoteScreenRenderer:\(participantId)")
        logScreenShareDiagnostics(connectionId: normalizedId, delayNanoseconds: 8_000_000_000, reason: "afterAttachRemoteScreenRenderer+8s:\(participantId)")
        return true
    }

    /// Removes a renderer previously bound via ``renderRemoteScreenVideo(to:connectionId:participantId:)``.
    func removeRemoteScreenVideoRenderer(_ renderer: RTCVideoRenderWrapper, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        remoteScreenTrackBinding(in: connection, participantId: participantId)?.track.remove(renderer)
    }

    private func remoteScreenTrackBinding(
        in connection: RTCConnection,
        participantId: String
    ) -> (key: String, track: WebRTC.RTCVideoTrack)? {
        if let exact = connection.remoteScreenTracksByParticipantId[participantId] {
            return (participantId, exact)
        }

        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        if !participantKey.isEmpty,
           let normalized = connection.remoteScreenTracksByParticipantId.first(where: {
               Self.conferenceParticipantIdentityKey($0.key) == participantKey
           }) {
            return (normalized.key, normalized.value)
        }

        return nil
    }

    func participantCameraRendererBindingDiagnostics(
        connectionId: String,
        participantId: String,
        renderer: RTCVideoRenderWrapper
    ) async -> String {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            return "connection=<missing>"
        }
        let binding = remoteCameraTrackBinding(in: connection, participantId: participantId)
        let mappedKey = binding?.key ?? "<nil>"
        let mappedTrackId = binding?.track.trackId ?? "<nil>"
        let attachmentKey = remoteParticipantVideoRendererAttachmentKey(
            connectionId: normalizedId,
            participantId: participantId
        )
        let cachedAttachment = remoteParticipantVideoRendererAttachedTrackIdByKey[attachmentKey] ?? "<nil>"
        let expectedAttachment: String
        if let binding {
            let liveTrack = resolvedLiveGroupParticipantCameraTrack(
                in: connection,
                participantId: participantId,
                mappedTrack: binding.track
            ) ?? binding.track
            expectedAttachment = remoteParticipantVideoRendererAttachmentValue(
                track: liveTrack,
                renderer: renderer,
                peerConnection: connection.peerConnection
            )
        } else {
            expectedAttachment = "<nil>"
        }
        let liveReceiverTrackId = binding.flatMap {
            Self.resolveLiveInboundCameraVideoReceiver(
                from: connection.peerConnection,
                matchingTrackId: $0.track.trackId
            )?.track?.trackId
        } ?? Self.resolveLiveInboundCameraVideoReceiver(from: connection.peerConnection)?.track?.trackId ?? "<nil>"
        return "participant=\(participantId) mappedKey=\(mappedKey) mappedTrackId=\(mappedTrackId) liveReceiverTrackId=\(liveReceiverTrackId) attachmentKey=\(attachmentKey) cachedAttachment=\(cachedAttachment) expectedAttachment=\(expectedAttachment)"
    }

    func participantCameraRendererBindingIsCurrent(
        connectionId: String,
        participantId: String,
        renderer: RTCVideoRenderWrapper
    ) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId),
              let binding = remoteCameraTrackBinding(in: connection, participantId: participantId) else {
            return false
        }
        let attachmentKey = remoteParticipantVideoRendererAttachmentKey(
            connectionId: normalizedId,
            participantId: participantId
        )
        let liveTrack = resolvedLiveGroupParticipantCameraTrack(
            in: connection,
            participantId: participantId,
            mappedTrack: binding.track
        ) ?? binding.track
        let expectedAttachment = remoteParticipantVideoRendererAttachmentValue(
            track: liveTrack,
            renderer: renderer,
            peerConnection: connection.peerConnection
        )
        return AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: remoteParticipantVideoRendererAttachedTrackIdByKey[attachmentKey],
            liveAttachmentValue: expectedAttachment
        )
    }

    private func remoteCameraTrackBinding(
        in connection: RTCConnection,
        participantId: String
    ) -> (key: String, track: WebRTC.RTCVideoTrack)? {
        if let exact = connection.remoteVideoTracksByParticipantId[participantId] {
            return (participantId, exact)
        }

        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        if !participantKey.isEmpty,
           let normalized = connection.remoteVideoTracksByParticipantId.first(where: {
               Self.conferenceParticipantIdentityKey($0.key) == participantKey
           }) {
            return (normalized.key, normalized.value)
        }

        let normalizedConnectionId = connection.id.normalizedConnectionId
        let isGroupConnection = groupCalls[normalizedConnectionId] != nil
            || groupCalls[connection.id] != nil
            || (isGroupCall && activeConnectionId?.normalizedConnectionId == normalizedConnectionId)
        if !isGroupConnection, let legacy = connection.remoteVideoTrack {
            return (participantId, legacy)
        }

        return nil
    }

    /// Removes a renderer previously bound via ``renderRemoteVideoForParticipant(to:connectionId:participantId:)``.
    func removeRemoteForParticipant(renderer: RTCVideoRenderWrapper, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.remoteVideoTracksByParticipantId[participantId]?.remove(renderer)
        let attachmentKey = remoteParticipantVideoRendererAttachmentKey(
            connectionId: normalizedId,
            participantId: participantId
        )
        remoteParticipantVideoRendererAttachedTrackIdByKey.removeValue(forKey: attachmentKey)
    }

    func removeRemote(renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Removing remote video renderer for connection: \(connectionId)")
        pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
        stopInboundVideoFlowProbe(connectionId: normalizedId)
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.remoteVideoTrack?.remove(renderer)
    }
    
    func removeLocal(renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Removing local video renderer for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.localVideoTrack?.remove(renderer)
    }
    
#endif
    
    /// Attaches buffered remote renderers once the 1:1 SFU receive frame key is installed.
    func flushPendingOneToOneSfuRemoteVideoRenderersIfNeeded(connectionId: String) async {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }
        guard oneToOneSfuReceiveKeyReadyConnectionIds.contains(teardownConnectionIdKey(normalizedId)) else { return }
        guard let connection = await connectionManager.findConnection(with: normalizedId) else { return }
        guard Self.isTrueOneToOneSfuRoom(call: connection.call) else { return }

        if let pending = pendingRemoteVideoRenderersByConnectionId[normalizedId] {
            logger.log(
                level: .info,
                message: "Attaching deferred 1:1 SFU remote renderer after receive key install connId=\(normalizedId)"
            )
#if os(Android)
            if let pending = pendingRemoteVideoRenderersByConnectionId[normalizedId] as? AndroidSampleCaptureView {
                await renderRemoteVideo(to: pending, connectionId: normalizedId)
            }
#else
            await renderRemoteVideo(to: pending, with: normalizedId)
#endif
        }

        guard var refreshed = await connectionManager.findConnection(with: normalizedId) else { return }
        // Prefer the SDP-advertised remote-owned track over the cached slot: after SFU
        // renegotiation the cached track can still be the placeholder receive half of our
        // own send m-line, which never delivers frames.
#if os(Android)
        let resolvedTrack = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: &refreshed)
        let cachedTrack = refreshed.remoteVideoTrack
        let liveTrack: RTCVideoTrack?
        if let resolvedTrack {
            let resolvedId = resolvedTrack.trackIdIfAvailable
            let cachedId = cachedTrack?.isLiveVideoTrack == true ? cachedTrack?.trackIdIfAvailable : nil
            if Self.oneToOneSfuRemoteTrackWouldDowngradeRelayToPlaceholder(
                previousTrackId: cachedId,
                resolvedTrackId: resolvedId
            ) {
                liveTrack = cachedTrack?.isLiveVideoTrack == true ? cachedTrack : resolvedTrack
            } else {
                liveTrack = resolvedTrack
            }
        } else {
            liveTrack = cachedTrack?.isLiveVideoTrack == true ? cachedTrack : nil
        }
        guard let liveTrack else { return }
        if let pending = pendingRemoteVideoRenderersByConnectionId[normalizedId] as? AndroidSampleCaptureView {
            _ = pending.attach(liveTrack)
            pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
        }
        refreshed.remoteVideoTrack = liveTrack
        let owner = oneToOneSfuRemoteTrackOwnerId(connection: refreshed)
        if !owner.isEmpty {
            refreshed.remoteVideoTracksByParticipantId[owner] = liveTrack
        }
        await connectionManager.updateConnection(id: normalizedId, with: refreshed)
#elseif canImport(WebRTC)
        guard let liveTrack = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: refreshed)
            ?? Self.resolveLiveInboundCameraVideoTrack(
                from: refreshed.peerConnection,
                preferringRemoteParticipantId: oneToOneSfuRemoteTrackOwnerId(connection: refreshed)
            )
            ?? refreshed.remoteVideoTrack
        else { return }

        for aux in refreshed.auxiliaryRemoteVideoRenderers {
            liveTrack.remove(aux)
            liveTrack.add(aux)
        }
        await connectionManager.updateConnection(id: normalizedId, with: refreshed)
#endif
    }

    /// After an SFU-driven SDP renegotiation, the inbound camera track on the video transceiver may be
    /// replaced without another `didAddReceiver` — renderers would stay on the old track and never
    /// receive frames. Refreshes from live transceivers and re-attaches pending + auxiliary sinks.
    func rebindInboundRemoteVideoAfterSfuRenegotiationIfNeeded(call: Call) async {
        guard call.supportsVideo else { return }
        guard Self.isTrueOneToOneSfuRoom(call: call) else { return }

        let norm = call.sharedCommunicationId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else { return }
#if canImport(WebRTC) && !os(Android)
        let resolved = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: connection)
            ?? Self.resolveLiveInboundCameraVideoTrack(
                from: connection.peerConnection,
                preferringRemoteParticipantId: oneToOneSfuRemoteTrackOwnerId(connection: connection)
            )
#elseif os(Android)
        let resolved = resolveOneToOneSfuInboundRemoteCameraVideoTrack(connection: &connection)
#else
        let resolved = Self.resolveLiveInboundCameraVideoTrack(
            from: connection.peerConnection,
            preferringRemoteParticipantId: connection.remoteParticipantId
        )
#endif
        guard let resolved else {
            logger.log(level: .debug, message: "rebindInboundRemoteVideoAfterSfuRenegotiationIfNeeded: no live inbound camera track conn=\(norm)")
            return
        }

        let previous = connection.remoteVideoTrack
#if os(Android)
        let resolvedTrackId = resolved.trackIdIfAvailable
        let previousTrackId: String? = {
            guard let previous, previous.isLiveVideoTrack else { return nil }
            return previous.trackIdIfAvailable
        }()
#else
        let resolvedTrackId = resolved.trackId
        let previousTrackId = previous?.trackId
#endif
        if Self.oneToOneSfuRemoteTrackWouldDowngradeRelayToPlaceholder(
            previousTrackId: previousTrackId,
            resolvedTrackId: resolvedTrackId
        ) {
            logger.log(
                level: .info,
                message: "SFU renegotiation: skipping remote video renderer rebind that would downgrade from SFU relay track oldTrackId=\(previousTrackId ?? "nil") placeholderTrackId=\(resolvedTrackId ?? "nil") conn=\(norm)"
            )
#if os(Android)
            if let previous, previous.isLiveVideoTrack,
               let pending = pendingRemoteVideoRenderersByConnectionId[norm] as? AndroidSampleCaptureView {
                _ = pending.attach(previous)
                pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: norm)
            }
#endif
            return
        }
#if os(Android)
        if previous === resolved {
            return
        }
        if let previousTrackId, let resolvedTrackId, previousTrackId == resolvedTrackId {
            return
        }
#elseif canImport(WebRTC) && !os(Android)
        if let previous, previous.trackId == resolvedTrackId, previous === resolved {
            if !inboundRemoteVideoRendererRebindNeeded(connection: connection, liveTrack: resolved) {
                return
            }
        }
#else
        if let previous, previous.trackId == resolvedTrackId, previous === resolved {
            return
        }
#endif

        logger.log(
            level: .info,
            message: "SFU renegotiation: rebinding remote video renderers oldTrackId=\(previousTrackId ?? "nil") newTrackId=\(resolvedTrackId ?? "<unknown>") conn=\(norm)"
        )

        let rendererRebindNeeded: Bool
#if canImport(WebRTC) && !os(Android)
        rendererRebindNeeded = inboundRemoteVideoRendererRebindNeeded(connection: connection, liveTrack: resolved)
#else
        rendererRebindNeeded = false
#endif
#if os(Android)
        let trackIdChanged = previousTrackId != resolvedTrackId
#else
        let trackIdChanged = previous?.trackId != resolvedTrackId
#endif
        if trackIdChanged || rendererRebindNeeded {
            remoteVideoRendererAttachedTrackIdByConnectionId.removeValue(forKey: norm)
        }

        if let previous {
#if !os(Android)
            if let pending = pendingRemoteVideoRenderersByConnectionId[norm] {
                previous.remove(pending)
            }
            for aux in connection.auxiliaryRemoteVideoRenderers {
                previous.remove(aux)
            }
#endif
        }

        connection.remoteVideoTrack = resolved
        let remotePid = oneToOneSfuRemoteTrackOwnerId(connection: connection)
        if let previous {
            connection.remoteVideoTracksByParticipantId = connection.remoteVideoTracksByParticipantId.filter { _, track in
                track !== previous
            }
        }
        if !remotePid.isEmpty {
            connection.remoteVideoTracksByParticipantId[remotePid] = resolved
        }

        if let pending = pendingRemoteVideoRenderersByConnectionId[norm] {
#if os(Android)
            if let androidPending = pending as? AndroidSampleCaptureView {
                _ = androidPending.attach(resolved)
                pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: norm)
            }
#else
            resolved.add(pending)
            remoteVideoRendererAttachedTrackIdByConnectionId[norm] = resolved.trackId
            pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: norm)
#endif
        }
#if !os(Android)
        for aux in connection.auxiliaryRemoteVideoRenderers {
            resolved.add(aux)
        }
#endif

        await connectionManager.updateConnection(id: connection.id, with: connection)

        #if canImport(WebRTC)
        logRtpStatsSnapshotOnce(
            connectionId: norm,
            delayNanoseconds: 2_000_000_000,
            reason: "afterSfuRenegotiationRemoteVideoRebind")
        startInboundVideoFlowProbe(connectionId: norm)
        #endif
    }

    func sfuRenegotiationReceiverCryptorRebindIsDeferred(for connectionId: String) -> Bool {
        sfuRenegotiationReceiverCryptorRebindDeferredConnectionIds.contains(
            teardownConnectionIdKey(connectionId))
    }

    /// Creates a local video track with proper error handling and validation
    /// - Parameter connection: The connection to add the video track to
    /// - Returns: Tuple containing the video track and updated connection
    /// - Throws: RTCErrors if creation fails
    func createLocalVideoTrack(with connection: RTCConnection) async throws -> (SPTVideoTrack, RTCConnection) {
        logger.log(level: .info, message: "Creating local video track for connection: \(connection.id)")
        
        var updatedConnection = connection
        
#if os(Android)
        let videoSource = self.rtcClient.createVideoSource()
        let videoTrack = self.rtcClient.createVideoTrack(id: connection.id, videoSource)
        
        // Update connection in manager
        let manager = connectionManager as RTCConnectionManager
        await manager.updateConnection(id: connection.id, with: updatedConnection)
        
        logger.log(level: .info, message: "Successfully created local video track for connection: \(connection.id), track: \(videoTrack.trackId)")
        return (.init(track: videoTrack), updatedConnection)
#elseif canImport(WebRTC)
        // Create video source
        let videoSource = RTCSession.factory.videoSource()
        // Create video track
        // IMPORTANT (SFU + E2EE):
        // Track IDs must be unique per sender. Using only `connection.id` (room id) causes all
        // participants to publish "video_<roomId>", which collapses identities on the SFU.
        let videoTrackId = "video_\(connection.localParticipantId)_\(connection.id)"
        let videoTrack = RTCSession.factory.videoTrack(with: videoSource, trackId: videoTrackId)
        // Apple-specific video capture wrapper
        updatedConnection.rtcVideoCaptureWrapper = RTCVideoCaptureWrapper(delegate: videoSource)
        
        // Update connection in manager
        let manager = connectionManager as RTCConnectionManager
        await manager.updateConnection(id: connection.id, with: updatedConnection)

        // Wake any controller waiting for the wrapper so it can bind capture injection.
        if let wrapper = updatedConnection.rtcVideoCaptureWrapper {
            resumeVideoCaptureWrapperWaiters(connectionId: connection.id, wrapper: wrapper)
#if os(iOS) || os(macOS)
            await rebindRegisteredLocalPreviewCaptureIfNeeded(connectionId: connection.id, wrapper: wrapper)
#endif
        }
        
        logger.log(level: .info, message: "Successfully created local video track for connection: \(connection.id)")
        return (.init(track: videoTrack), updatedConnection)
#else
        throw RTCErrors.mediaError("Unsupported platform for local video track creation")
#endif
    }

#if canImport(WebRTC)
    /// Rebuilds the local video sender pipeline by creating a fresh `RTCVideoSource` + `RTCVideoTrack`
    /// and re-binding the existing capture wrapper delegate to the new source.
    ///
    /// This is used as an escalated recovery when outbound video counters remain flat even though
    /// audio and transport are healthy.
    func restartLocalVideoSenderPipeline(connectionId: String) async -> Bool {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard var connection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .warning, message: "restartLocalVideoSenderPipeline: connection not found for id=\(normalizedId)")
            return false
        }
        guard connection.call.supportsVideo else { return false }

        let newVideoSource = RTCSession.factory.videoSource()
        let newTrackId = "video_\(connection.localParticipantId)_\(connection.id)_recovery_\(UUID().uuidString)"
        let newVideoTrack = RTCSession.factory.videoTrack(with: newVideoSource, trackId: newTrackId)

        if let wrapper = connection.rtcVideoCaptureWrapper {
            wrapper.updateCaptureDelegate(newVideoSource)
        } else {
            connection.rtcVideoCaptureWrapper = RTCVideoCaptureWrapper(delegate: newVideoSource)
            if let wrapper = connection.rtcVideoCaptureWrapper {
                // Wake controllers that may still be waiting for a wrapper after a late reconnect.
                resumeVideoCaptureWrapperWaiters(connectionId: normalizedId, wrapper: wrapper)
#if os(iOS) || os(macOS)
                await rebindRegisteredLocalPreviewCaptureIfNeeded(connectionId: normalizedId, wrapper: wrapper)
#endif
            }
        }

        var touchedAnyVideoSender = false
        for sender in connection.peerConnection.senders where sender.track?.kind == kRTCMediaStreamTrackKindVideo {
            sender.track = newVideoTrack
            var params = sender.parameters
            if !params.encodings.isEmpty {
                for encoding in params.encodings {
                    encoding.isActive = true
                }
                sender.parameters = params
            }
            touchedAnyVideoSender = true
        }

        if !touchedAnyVideoSender {
            logger.log(level: .warning, message: "restartLocalVideoSenderPipeline: no video sender found for connection id=\(normalizedId)")
            return false
        }

        connection.localVideoTrack = newVideoTrack
        await manager.updateConnection(id: normalizedId, with: connection)
        logger.log(level: .warning, message: "Rebuilt local video sender pipeline for connection id=\(normalizedId)")
        return true
    }
#endif
    
    func setVideoTrack(isEnabled: Bool, connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard !normalizedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.log(level: .error, message: "setVideoTrack called with empty connectionId")
            return
        }
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            // This can happen when the UI requests video enable/disable before the peer connection
            // is created/registered (common on inbound call answer flows).
            pendingVideoEnabledByConnectionId[normalizedId] = isEnabled
            logger.log(level: .info, message: "Video track state requested before connection exists; buffering isEnabled=\(isEnabled) for connectionId=\(normalizedId)")
            return
        }
#if !os(Android)
        await setTrackEnabled(WebRTC.RTCVideoTrack.self, isEnabled: isEnabled, with: connection)
        // Adaptive sender control should only run for SFU group calls while video is enabled.
        if connection.id.isGroupCall {
            if isEnabled {
                await startAdaptiveVideoSendIfNeeded(connectionId: normalizedId)
            } else {
                stopAdaptiveVideoSend(connectionId: normalizedId)
            }
        }
#elseif os(Android)
        self.rtcClient.setVideoEnabled(isEnabled)
        if !isEnabled {
            stopAdaptiveVideoSend(connectionId: normalizedId)
            return
        }

        let shouldStartConnectedVideoWork: Bool
        if case .connected(_, let activeCall) = await callState.currentState {
            let activeIds = [
                activeCall.sharedCommunicationId.normalizedConnectionId,
                activeCall.resolvedChannelWireId?.normalizedConnectionId ?? ""
            ]
            shouldStartConnectedVideoWork = activeIds.contains(normalizedId)
        } else {
            shouldStartConnectedVideoWork = false
        }

        if shouldStartConnectedVideoWork {
            self.rtcClient.startLocalVideoCaptureIfNeeded()
            if connection.id.isGroupCall {
                await startAdaptiveVideoSendIfNeeded(connectionId: normalizedId)
            }
        }
#endif
    }

    /// For SFU conferences: whether the main remote tile’s health watchdog should expect inbound frames.
    ///
    /// Uses **mapped remote camera tracks** (`remoteVideoTracksByParticipantId`), not roster membership:
    /// roster can list audio-only peers or signaling-only entries while the main video tile still has
    /// nothing to decode.
    ///
    /// Non-group calls always return `true`.
    public func shouldExpectRemoteVideoCallbacksFromOtherParticipants(connectionId: String) async -> Bool {
        guard let connection = await connectionManager.findConnection(with: connectionId) else {
            return true
        }
        if !connection.id.isGroupCall {
            return true
        }
        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connectionHasRemoteVideoFromNonLocalParticipant(connection, localNorm: local)
    }

    private func connectionHasRemoteVideoFromNonLocalParticipant(_ connection: RTCConnection, localNorm: String) -> Bool {
        for (participantKey, _) in connection.remoteVideoTracksByParticipantId {
            let p = participantKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !p.isEmpty, p != localNorm {
                return true
            }
        }
        return false
    }
    
#if !os(Android)
    func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool, with connection: RTCConnection) async {
        // Prefer `senders` — some stacks attach local tracks there before transceiver.sender.track is wired.
        var applied = Set<ObjectIdentifier>()
#if canImport(WebRTC)
        var audioEncoderMuteApplied = false
#endif
        for sender in connection.peerConnection.senders {
            guard let track = sender.track as? T else { continue }
            track.isEnabled = isEnabled
            applied.insert(ObjectIdentifier(track))
        }
        for transceiver in connection.peerConnection.transceivers {
            guard let track = transceiver.sender.track as? T else { continue }
            let id = ObjectIdentifier(track)
            guard !applied.contains(id) else { continue }
            track.isEnabled = isEnabled
            applied.insert(id)
        }
#if canImport(WebRTC)
        // Cached local track can diverge from `sender.track` reference in some negotiation paths; always sync it for video.
        if T.self == WebRTC.RTCVideoTrack.self, let local = connection.localVideoTrack {
            if let track = local as? T {
                let oid = ObjectIdentifier(track)
                if !applied.contains(oid) {
                    track.isEnabled = isEnabled
                    applied.insert(oid)
                }
            }
        }
        // Audio: keep cached mic track in sync, and drive RTP sender encodings — some WebRTC builds keep uplink active when only `track.isEnabled` is toggled.
        if T.self == WebRTC.RTCAudioTrack.self {
            if let local = connection.localAudioTrack, let track = local as? T {
                let oid = ObjectIdentifier(track)
                if !applied.contains(oid) {
                    track.isEnabled = isEnabled
                    applied.insert(oid)
                }
            }
            for sender in connection.peerConnection.senders {
                guard sender.track?.kind == kRTCMediaStreamTrackKindAudio else { continue }
                var params = sender.parameters
                if !params.encodings.isEmpty {
                    for encoding in params.encodings {
                        encoding.isActive = isEnabled
                    }
                    sender.parameters = params
                    audioEncoderMuteApplied = true
                }
            }
        }
#endif
        var shouldWarnNoTrackTouches = applied.isEmpty
#if canImport(WebRTC)
        if T.self == WebRTC.RTCAudioTrack.self, audioEncoderMuteApplied {
            shouldWarnNoTrackTouches = false
        }
#endif
        if shouldWarnNoTrackTouches {
            logger.log(
                level: .warning,
                message: "setTrackEnabled(\(String(describing: T.self))): no tracks updated for connection id=\(connection.id); senders=\(connection.peerConnection.senders.count) transceivers=\(connection.peerConnection.transceivers.count) localVideoTrack=\(connection.localVideoTrack != nil) localAudioTrack=\(connection.localAudioTrack != nil)"
            )
        }
    }
#endif
}
