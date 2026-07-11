//
//  RTCSession+ScreenShare.swift
//  pqs-rtc
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
import BinaryCodable
#if canImport(WebRTC)
import WebRTC
#endif

extension RTCSession {

    // MARK: - Screen share track prefix

    static let screenTrackPrefix = "screen_"
    static let screenStreamPrefix = "screen_"

    /// Whether this build can send screen-share system audio to remote participants.
    ///
    /// On Apple platforms the bundled webrtc-sdk fork exposes
    /// `RTCDefaultAudioProcessingModule`'s capture post-processing hook, which lets us
    /// mix ScreenCaptureKit / ReplayKit system audio into the outbound mic capture path
    /// (no extra SDP m-section needed). Android does not have this wired up yet.
#if canImport(WebRTC) && !os(Android)
    public static let supportsScreenShareSystemAudioEgress = true
#else
    public static let supportsScreenShareSystemAudioEgress = false
#endif

    /// Whether a track id or stream id represents a screen share.
    static func isScreenShareId(_ id: String) -> Bool {
        id.hasPrefix(screenTrackPrefix)
    }

    /// SFU-generated camera tracks use stable `video_<participant>_<room>` labels.
    /// These must never be promoted to remote screen share during renegotiation.
    static func isSfuCameraMediaId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("video_") || trimmed.hasPrefix("streamId_video_")
    }

    /// Conference screen-share events and maps should never key off raw SFU UUID stream placeholders.
    static func isPlausibleConferenceScreenShareParticipantId(_ rawParticipantId: String) -> Bool {
        let trimmed = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return UUID(uuidString: trimmed) == nil
    }

    /// Extracts the participant portion from a `"screen_<participantId>"` identifier.
    static func participantIdFromScreenShareId(_ id: String) -> String? {
        guard id.hasPrefix(screenTrackPrefix) else { return nil }
        let suffix = String(id.dropFirst(screenTrackPrefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    static func resolvedScreenShareParticipantId(
        streamIds: [String],
        trackId: String,
        fallback: String
    ) -> String {
        let candidates = streamIds + [trackId]
        for candidate in candidates {
            guard let participant = participantIdFromScreenShareId(candidate) else { continue }
            let trimmed = participant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One active screen-share participant advertised in remote SDP.
    struct AdvertisedRemoteScreenShare: Equatable, Sendable {
        let participantId: String
        let trackId: String?
    }

    /// Parses active remote screen-share participants from SDP `m=video` sections.
    ///
    /// Skips `a=inactive` / `a=recvonly` sections. `resolveParticipantId` maps an msid stream or
    /// track label to a stable participant id; return `nil` to ignore a label.
    static func advertisedRemoteScreenShares(
        in sdp: String,
        localParticipantId: String,
        resolveParticipantId: (String) -> String?
    ) -> [AdvertisedRemoteScreenShare] {
        var results: [AdvertisedRemoteScreenShare] = []
        var seenParticipants = Set<String>()
        var currentMediaKind: String?
        var currentSectionLines: [String] = []
        let local = localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)

        func isScreenShareLabel(_ rawLabel: String) -> Bool {
            let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix(screenTrackPrefix)
                || trimmed.hasPrefix("streamId_\(screenTrackPrefix)")
        }

        func appendAdvertisement(streamLabel: String, trackId: String?) {
            let candidates = [streamLabel, trackId].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && isScreenShareLabel($0) }
            guard !candidates.isEmpty else { return }

            var participantId: String?
            for candidate in candidates {
                var label = candidate
                if label.hasPrefix("streamId_") {
                    label = String(label.dropFirst("streamId_".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let resolved = resolveParticipantId(label) {
                    participantId = resolved
                    break
                }
                if let fromScreenId = participantIdFromScreenShareId(label) {
                    participantId = fromScreenId.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            guard let id = participantId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return }
            guard UUID(uuidString: id) == nil else { return }
            guard local.isEmpty || id.caseInsensitiveCompare(local) != .orderedSame else { return }
            guard !seenParticipants.contains(id) else { return }
            seenParticipants.insert(id)
            results.append(AdvertisedRemoteScreenShare(participantId: id, trackId: trackId))
        }

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
                guard let streamLabel = parts.first else { continue }
                let trackId = parts.count > 1 ? parts[1] : nil
                appendAdvertisement(streamLabel: streamLabel, trackId: trackId)
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

        return results
    }

    /// Legacy parser for SFU relay offers without a `screen_` msid prefix.
    ///
    /// Bare UUID relay video sections are ambiguous in group rooms and can represent camera media.
    /// The active contract requires screen-share tracks/streams to use `screen_` identifiers, so
    /// this no longer surfaces UUID-only video sections as remote screen share.
    static func advertisedRelayStyleRemoteScreenShares(
        in sdp: String,
        localParticipantId: String,
        participantFromStreamLabel: (String) -> String?
    ) -> [AdvertisedRemoteScreenShare] {
        _ = sdp
        _ = localParticipantId
        _ = participantFromStreamLabel
        return []
    }

    // MARK: - Public API

    /// Adds a screen share track to the peer connection as a second video sender.
    ///
    /// Creates a platform-specific capture source, feeds frames into a new `RTCVideoTrack`,
    /// and adds it to the peer connection with a `"screen_"` prefixed stream ID so remote
    /// participants and the SFU can distinguish it from the camera track.
    public func addScreenTrackToStream(
        target: ScreenShareTarget,
        connectionId: String
    ) async throws {
        try await addScreenTrackToStream(
            target: target,
            options: ScreenShareOptions(),
            connectionId: connectionId
        )
    }

    /// Adds a screen share track to the peer connection with the selected capture options.
    public func addScreenTrackToStream(
        target: ScreenShareTarget,
        options: ScreenShareOptions,
        connectionId: String
    ) async throws {
        let normalizedId = connectionId.normalizedConnectionId
        if let existingInFlight = screenShareStartInFlightConnectionIds.first {
            logger.log(
                level: .warning,
                message: "Ignoring duplicate screen share start while another start is in flight existing=\(existingInFlight) requested=\(normalizedId)"
            )
            throw RTCErrors.mediaError("Screen share is already starting.")
        }
        screenShareStartInFlightConnectionIds.insert(normalizedId)
        defer {
            screenShareStartInFlightConnectionIds.remove(normalizedId)
        }

        guard var connection = await connectionManager.findConnection(with: normalizedId) else {
            throw RTCErrors.connectionNotFound
        }

        let permissions = conferencePermissions
        let shouldEnforcePermissions = Self.shouldEnforceScreenShareConferencePermissions(
            call: connection.call,
            permissions: permissions
        )
        guard !shouldEnforcePermissions || permissions.canScreenShare else {
            logger.log(
                level: .warning,
                message: "Screen share denied by conference permissions role=\(permissions.localRole.rawValue) participants=\(permissions.participantRoles.count)"
            )
            throw RTCErrors.permissionDenied("Screen sharing requires Presenter role or higher")
        }

        try await enforceExclusiveScreenShareBeforeStarting(connectionId: normalizedId, connection: connection)
        await clearRemoteScreenShareMappingsBeforeLocalStart(connectionId: normalizedId)
        if let updated = await connectionManager.findConnection(with: normalizedId) {
            connection = updated
        }

        if connection.localScreenTrack != nil {
            logger.log(level: .info, message: "Screen share already active; stopping previous before starting new")
            await removeScreenTrackFromStream(connectionId: connectionId)
            if let updated = await connectionManager.findConnection(with: normalizedId) {
                connection = updated
            }
        }

#if os(Android)
        logger.log(level: .info, message: "Adding Android screen share track")
        guard let projectionResultCode = androidMediaProjectionPermission.readResultCode() else {
            throw RTCErrors.mediaError("MediaProjection result not set. Call setAndroidMediaProjectionResult before starting screen share.")
        }
        let metrics = AndroidScreenShareCaptureMetrics.compute(optimizeForVideo: options.optimizeForVideo)
        let captureGeneration = beginPlatformScreenCaptureGeneration()
        let capturedConnectionId = normalizedId
        rtcClient.setScreenCaptureLifecycleHandlers(
            onCaptureStarted: { [weak self] success in
                guard success else {
                    Task { await self?.platformScreenCaptureDidFinishUnexpectedly(
                        connectionId: capturedConnectionId,
                        generation: captureGeneration
                    ) }
                    return
                }
                Task { await self?.screenCaptureDidBecomeReady(connectionId: capturedConnectionId) }
            },
            onProjectionStopped: { [weak self] in
                Task { await self?.platformScreenCaptureDidFinishUnexpectedly(
                    connectionId: capturedConnectionId,
                    generation: captureGeneration
                ) }
            }
        )
        let screenTrack = try rtcClient.prepareScreenShareSendRecv(
            id: "\(connection.localParticipantId)",
            resultCode: projectionResultCode,
            width: metrics.width,
            height: metrics.height,
            fps: metrics.fps
        )
        connection.localScreenTrack = screenTrack
        await connectionManager.updateConnection(id: normalizedId, with: connection)
        if enableEncryption, let screenTrack {
            rtcClient.createScreenSenderEncryptedFrame(
                participant: connection.localParticipantId,
                connectionId: normalizedId,
                trackId: screenTrack.trackId
            )
        }
#elseif canImport(WebRTC)
        guard !options.shareSystemAudio || Self.supportsScreenShareSystemAudioEgress else {
            throw RTCErrors.mediaError(
                "Sharing device audio is not available in this WebRTC build. Start screen sharing without Share system audio."
            )
        }
        let wantsSystemAudio = options.shareSystemAudio && Self.supportsScreenShareSystemAudioEgress
        if wantsSystemAudio {
            try await beginSystemAudioShareEgress(connectionId: normalizedId, connection: connection)
        }
        let (screenTrack, updatedConnection): (WebRTC.RTCVideoTrack, RTCConnection)
        do {
            (screenTrack, updatedConnection) = try await createLocalScreenTrack(
                target: target,
                options: options,
                with: connection
            )
        } catch {
            if wantsSystemAudio {
                await endSystemAudioShareEgressIfNeeded(connectionId: normalizedId)
            }
            throw error
        }
        connection = updatedConnection

        let streamId = "\(Self.screenStreamPrefix)\(connection.localParticipantId)"
        let maybeScreenSender = addAppleScreenSender(
            screenTrack,
            streamId: streamId,
            to: connection.peerConnection
        )

        if enableEncryption, maybeScreenSender != nil {
            await ensureAppleScreenSenderCryptorIfNeeded(connection: connection)
        }

        if var latest = await connectionManager.findConnection(with: normalizedId) {
            latest.localScreenTrack = connection.localScreenTrack
            await connectionManager.updateConnection(id: normalizedId, with: latest)
        } else {
            await connectionManager.updateConnection(id: normalizedId, with: connection)
        }
#endif
        let deferOfferUntilCaptureReady = Self.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: target)
#if os(iOS) || os(Android)
        if deferOfferUntilCaptureReady {
            pendingScreenShareRenegotiationConnectionIds.insert(normalizedId)
        }
#endif
        if !deferOfferUntilCaptureReady {
            do {
                try await renegotiateScreenShareIfNeeded(
                    connectionId: normalizedId,
                    reason: "started"
                )
            } catch {
                logger.log(
                    level: .warning,
                    message: "Screen share start failed during renegotiation for connection \(normalizedId); cleaning up local capture: \(error)"
                )
                await removeScreenTrackFromStream(connectionId: normalizedId)
                throw error
            }
            notifyLocalScreenShareChanged(isSharing: true)
        } else {
#if os(iOS) || os(Android)
            scheduleAbandonedScreenShareCaptureCleanup(connectionId: normalizedId)
#endif
            await refreshLocalScreenSharePresentationState()
        }
        logger.log(level: .info, message: "Screen share track added for connection \(normalizedId)")
    }

    static func shouldDeferScreenShareRenegotiationUntilCaptureReady(target: ScreenShareTarget) -> Bool {
        switch target {
        case .appScreen, .androidScreen:
            return true
        case .entireScreen, .window:
            return false
        }
    }

    /// Whether local screen-share chrome should show an active share (capture ready and advertised).
    ///
    /// While a deferred-start connection is waiting for platform capture, the local track may exist
    /// but the UI must remain idle until renegotiation completes.
    static func isLocalScreenShareActiveForPresentation(
        connections: [RTCConnection],
        pendingCaptureReadyIds: Set<String>
    ) -> Bool {
        connections.contains { connection in
            guard connection.localScreenTrack != nil else { return false }
            return !pendingCaptureReadyIds.contains(connection.id.normalizedConnectionId)
        }
    }

    /// Pushes the derived presentation flag to ``localScreenShareStateStream()`` subscribers.
    func refreshLocalScreenSharePresentationState() async {
        let connections = await connectionManager.findAllConnections()
        let isSharing = Self.isLocalScreenShareActiveForPresentation(
            connections: connections,
            pendingCaptureReadyIds: pendingScreenShareRenegotiationConnectionIds
        )
        notifyLocalScreenShareChanged(isSharing: isSharing)
    }

#if os(iOS) || os(Android)
    /// How long to wait for platform capture (ReplayKit / MediaProjection) before rolling back a deferred start.
    static let abandonedScreenShareCaptureTimeoutSeconds: Double = 60.0

    func scheduleAbandonedScreenShareCaptureCleanup(connectionId: String) {
        let normalizedId = connectionId.normalizedConnectionId
        abandonedScreenShareCaptureCleanupTasks[normalizedId]?.cancel()
        abandonedScreenShareCaptureCleanupTasks[normalizedId] = Task { [weak self] in
            let timeout = Self.abandonedScreenShareCaptureTimeoutSeconds
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.handleAbandonedScreenShareCaptureTimeout(
                connectionId: normalizedId,
                timeoutSeconds: timeout)
        }
    }

    private func handleAbandonedScreenShareCaptureTimeout(
        connectionId: String,
        timeoutSeconds: Double
    ) async {
        guard pendingScreenShareRenegotiationConnectionIds.contains(connectionId) else { return }
        logger.log(
            level: .warning,
            message: "Abandoned screen share capture cleanup after \(Int(timeoutSeconds))s without capture-ready connId=\(connectionId)")
        await removeScreenTrackFromStream(connectionId: connectionId)
        clearAbandonedScreenShareCaptureCleanupTask(for: connectionId)
    }

    func clearAbandonedScreenShareCaptureCleanupTask(for connectionId: String) {
        let normalizedId = connectionId.normalizedConnectionId
        abandonedScreenShareCaptureCleanupTasks.removeValue(forKey: normalizedId)?.cancel()
    }
#endif

    public static func shouldEnforceScreenShareConferencePermissions(
        call: Call,
        permissions: ConferencePermissions
    ) -> Bool {
        // True 1:1 SFU relay (wire present) never uses conference chrome.
        if Self.isTrueOneToOneSfuRoom(call: call) {
            return false
        }
        // UUID-shaped 1:1 (P2P or SFU Call copy missing wire) must stay on CallView controls
        // even if an SFU roster briefly populates participantRoles.
        if Self.isLikelyOneToOneSfuRoom(call: call), call.conferencePassword == nil {
            let wire = (call.resolvedChannelWireId ?? call.channelWireId)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if wire.isEmpty {
                return false
            }
            let commNorm = call.sharedCommunicationId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .normalizedConnectionId
            if wire.normalizedConnectionId == commNorm {
                return false
            }
        }
        if call.conferencePassword != nil {
            return true
        }
        return !permissions.participantRoles.isEmpty
    }

    /// Voice-only call chrome must yield while a shared screen is visible.
    ///
    /// Screen sharing is video media even when the underlying CallKit call began as audio-only.
    static func shouldPresentVoiceOnlyCallChrome(
        callSupportsVideo: Bool,
        hasVisibleScreenShare: Bool
    ) -> Bool {
        !callSupportsVideo && !hasVisibleScreenShare
    }

    /// Removes the screen share track and stops capture.
    public func removeScreenTrackFromStream(connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        cancelRelayFallbackTimer(connectionId: normalizedId)
#if canImport(WebRTC) && !os(Android)
        await endSystemAudioShareEgressIfNeeded(connectionId: normalizedId)
#endif
#if os(iOS) || os(Android)
        clearAbandonedScreenShareCaptureCleanupTask(for: normalizedId)
        pendingScreenShareRenegotiationConnectionIds.remove(normalizedId)
#endif
        guard var connection = await connectionManager.findConnection(with: normalizedId) else {
            if let captureSource = screenCaptureSourceForCurrentPlatform {
                await stopPlatformScreenCapture(captureSource)
            }
            notifyLocalScreenShareChanged(isSharing: false)
            return
        }

        let localParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let localParticipantKey = Self.conferenceParticipantIdentityKey(localParticipantId)
        var reflectedLocalScreenParticipants: [String] = []

        if !localParticipantKey.isEmpty {
            for participantId in Array(connection.remoteScreenTracksByParticipantId.keys)
            where Self.conferenceParticipantIdentityKey(participantId) == localParticipantKey {
                connection.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
#if canImport(WebRTC) && !os(Android)
                if let cryptor = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                    cryptor.enabled = false
                    cryptor.delegate = nil
                }
                connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
#endif
                reflectedLocalScreenParticipants.append(participantId)
            }
        }

#if os(Android)
        invalidatePlatformScreenCaptureGeneration()
        rtcClient.clearScreenCaptureLifecycleHandlers()
        androidMediaProjectionPermission.clear()
        rtcClient.stopScreenCapture()
        connection.localScreenTrack = nil
        if !reflectedLocalScreenParticipants.isEmpty {
            connection.remoteScreenTrack = nil
        }
        await connectionManager.updateConnection(id: normalizedId, with: connection)
#elseif canImport(WebRTC)
        connection.localScreenTrack?.isEnabled = false
        await prepareAppleScreenSenderCryptorForTrackRemoval(
            from: &connection,
            reason: "removeScreenTrackFromStream"
        )

        if let captureSource = screenCaptureSourceForCurrentPlatform {
            await stopPlatformScreenCapture(captureSource)
        }

        if let screenTrack = connection.localScreenTrack {
            for sender in connection.peerConnection.senders where sender.track?.trackId == screenTrack.trackId {
                removeAppleScreenSender(sender, from: connection.peerConnection, connection: connection)
            }
        }

        connection.localScreenTrack = nil
        connection.screenCaptureWrapper = nil
        await connectionManager.updateConnection(id: normalizedId, with: connection)
#endif
        for participantId in reflectedLocalScreenParticipants {
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: normalizedId, participantId: participantId, isActive: false)
            )
        }
        notifyLocalScreenShareChanged(isSharing: false)
        do {
            try await renegotiateScreenShareIfNeeded(
                connectionId: normalizedId,
                reason: "stopped"
            )
        } catch {
            logger.log(
                level: .warning,
                message: "Screen share removed locally but renegotiation failed for connection \(normalizedId): \(error)"
            )
        }
        logger.log(level: .info, message: "Screen share track removed for connection \(normalizedId)")
    }

    private func awaitClearScreenShareOfferInFlight(connectionId: String) async {
        let offerKey = connectionId.normalizedConnectionId
        for _ in 0..<25 where offerInFlightConnectionIds.contains(offerKey) {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func renegotiateScreenShareIfNeeded(
        connectionId: String,
        reason: String
    ) async throws {
        let normalizedId = connectionId.normalizedConnectionId
        await awaitClearScreenShareOfferInFlight(connectionId: normalizedId)
        guard var connection = await connectionManager.findConnection(with: normalizedId) else {
            logger.log(
                level: .warning,
                message: "Screen share \(reason): no connection found for renegotiation id=\(normalizedId)"
            )
            return
        }

        let wireRoomId = connection.call.resolvedChannelWireId ?? connection.call.sharedCommunicationId
        let isSfuConnection = connection.id.isGroupCall
            || wireRoomId.isGroupCall
            || groupCall(forSfuIdentity: normalizedId) != nil
            || groupCall(forSfuIdentity: wireRoomId) != nil

        if isSfuConnection {
            let updatedCall = try await sendGroupCallOffer(connection.call)
            connection.call = updatedCall
            await connectionManager.updateConnection(id: normalizedId, with: connection)
            if let group = groupCall(forSfuIdentity: wireRoomId) ?? groupCall(forSfuIdentity: normalizedId) {
                await group.applyUpdatedCallForNegotiation(updatedCall)
            }
            logger.log(
                level: .info,
                message: "Screen share \(reason): sent SFU renegotiation offer for connection=\(connection.id)"
            )
            return
        }

        let updatedCall = try await sendOneToOneScreenShareOffer(connection.call)
        connection.call = updatedCall
        await connectionManager.updateConnection(id: normalizedId, with: connection)
        logger.log(
            level: .info,
            message: "Screen share \(reason): sent 1:1 renegotiation offer for connection=\(connection.id)"
        )
    }

    private func sendOneToOneScreenShareOffer(_ call: Call) async throws -> Call {
        let offerKey = call.sharedCommunicationId.normalizedConnectionId
        guard !offerInFlightConnectionIds.contains(offerKey) else {
            logger.log(
                level: .warning,
                message: "Screen share offer already in flight for \(offerKey); skipping duplicate renegotiation offer"
            )
            return call
        }

        offerInFlightConnectionIds.insert(offerKey)
        defer { offerInFlightConnectionIds.remove(offerKey) }

        var updated = try await createOffer(call: call)
        let keyBundle = try await pcKeyManager.fetchCallKeyBundle()
        guard let localProps = await keyBundle.sessionIdentity.props(symmetricKey: keyBundle.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Local signaling props are missing for screen-share renegotiation")
        }

        updated.signalingIdentityProps = localProps
        let offerPlaintext = try BinaryEncoder().encode(updated)
        let writeTask = WriteTask(
            data: offerPlaintext,
            roomId: updated.sharedCommunicationId.normalizedConnectionId,
            flag: .offer,
            call: updated
        )
        let encryptableTask = EncryptableTask(task: .writeMessage(writeTask))
        try await taskProcessor.feedTask(task: encryptableTask)
        updateFallbackLatestCall(updated)

        do {
            try await startSendingCandidates(call: updated)
        } catch {
            logger.log(level: .warning, message: "Failed to start sending ICE candidates after screen-share offer: \(error)")
        }

        return updated
    }

    /// Reserves contract mid=2 on SFU joins so relay binding does not require escalating mids.
    func ensureGroupCallScreenSlotReserved(with connection: RTCConnection) -> RTCConnection {
        guard shouldReserveSfuScreenShareSlot(for: connection) else { return connection }
        let streamId = ScreenShareGroupCallContract.screenStreamLabel(
            participantId: connection.localParticipantId
        )

#if os(Android)
        do {
            try rtcClient.reserveScreenShareSlot(streamId: streamId)
            logger.log(
                level: .info,
                message: "Reserved SFU screen slot connection=\(connection.id) streamId=\(streamId)"
            )
        } catch {
            logger.log(
                level: .warning,
                message: "Failed to reserve SFU screen slot connection=\(connection.id) streamId=\(streamId): \(error)"
            )
        }
        return connection
#elseif canImport(WebRTC)
        let peerConnection = connection.peerConnection
        let contractMid = ScreenShareGroupCallContract.MediaMid.screen.rawValue

        if peerConnection.transceivers.contains(where: {
            $0.mediaType == .video && $0.mid == contractMid
        }) {
            return connection
        }

        if reusableAppleScreenTransceiver(in: peerConnection) != nil {
            return connection
        }

        let initConfig = RTCRtpTransceiverInit()
        initConfig.direction = .inactive
        initConfig.streamIds = [streamId]

        if let transceiver = peerConnection.addTransceiver(of: .video, init: initConfig) {
            transceiver.sender.streamIds = [streamId]

            logger.log(
                level: .info,
                message: "Reserved SFU screen slot connection=\(connection.id) mid=\(transceiver.mid) streamId=\(streamId)"
            )
        }
        return connection
#else
        return connection
#endif
    }

    private func shouldReserveSfuScreenShareSlot(for connection: RTCConnection) -> Bool {
        if connection.id.isGroupCall || isGroupCallConnection(connection.id) { return true }
        if Self.isTrueOneToOneSfuRoom(call: connection.call) { return true }
        if shouldReserveSfuScreenShareSlot(forRoomId: connection.call.resolvedChannelWireId) { return true }
        if shouldReserveSfuScreenShareSlot(forRoomId: connection.call.channelWireId) { return true }
        return false
    }

    private func shouldReserveSfuScreenShareSlot(forRoomId roomId: String?) -> Bool {
        guard let roomId = roomId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !roomId.isEmpty
        else { return false }
        return roomId.isGroupCall || isGroupCallConnection(roomId)
    }

    #if canImport(WebRTC) && !os(Android)
    private func addAppleScreenSender(
        _ screenTrack: WebRTC.RTCVideoTrack,
        streamId: String,
        to peerConnection: WebRTC.RTCPeerConnection
    ) -> WebRTC.RTCRtpSender? {
        if let transceiver = reusableAppleScreenTransceiver(in: peerConnection) {
            transceiver.sender.track = screenTrack
            transceiver.sender.streamIds = [streamId]
            setAppleTransceiverDirection(
                .sendOnly,
                transceiver: transceiver,
                reason: "screen share restart"
            )
            logger.log(level: .info, message: "Reused inactive screen transceiver for subsequent screen share")
            return transceiver.sender
        }

        let sender = peerConnection.add(screenTrack, streamIds: [streamId])
        guard let sender else {
            logger.log(level: .warning, message: "Failed to add screen sender to PeerConnection")
            return nil
        }

        setAppleScreenTransceiverDirection(
            .sendOnly,
            for: sender,
            in: peerConnection,
            reason: "screen share start"
        )
        return sender
    }

    /// WebRTC rollback of a local screen-share *stop* offer can restore a previous `sendOnly`
    /// screen sender even though `localScreenTrack` was already cleared (e.g. preempt while a
    /// remote sharer's relay offer arrives). Re-apply SFU inactive teardown on any screen slot.
    func enforceAppleOutboundScreenShareStoppedAfterSfuOfferRollback(connectionId: String) async {
        guard var connection = await connectionManager.findConnection(with: connectionId),
              connection.localScreenTrack == nil
        else { return }

        await prepareAppleScreenSenderCryptorForTrackRemoval(
            from: &connection,
            reason: "enforceLocalScreenShareStopAfterSfuOfferRollback"
        )

        var didMutate = false
        for transceiver in connection.peerConnection.transceivers where transceiver.mediaType == .video {
            let sender = transceiver.sender
            let senderTrackId = sender.track?.trackId ?? ""
            let isScreenSender = Self.isScreenShareId(senderTrackId)
                || sender.streamIds.contains(where: Self.isScreenShareId)
            guard isScreenSender else { continue }

            removeAppleScreenSender(sender, from: connection.peerConnection, connection: connection)
            didMutate = true
            logger.log(
                level: .info,
                message: "Re-enforced local screen-share stop after SFU offer rollback connection=\(connection.id) mid=\(transceiver.mid)"
            )
        }

        guard didMutate else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }

    private func removeAppleScreenSender(
        _ sender: WebRTC.RTCRtpSender,
        from peerConnection: WebRTC.RTCPeerConnection,
        connection: RTCConnection
    ) {
        let transceiver = appleTransceiver(for: sender, in: peerConnection)
        let didRemove = peerConnection.removeTrack(sender)
        if !didRemove {
            logger.log(level: .warning, message: "Failed to remove screen sender from PeerConnection")
        }

        if let transceiver {
            let usesSfuMedia = isGroupCallConnection(connection.id)
                || Self.isTrueOneToOneSfuRoom(call: connection.call)
            if usesSfuMedia {
                // SFU treats `a=inactive` on the dedicated screen `m=video` as track removal and
                // fans out updated offers without the screen msid. `recvonly` leaves stale screen
                // advertisements relayed to viewers, so their UI never tears down.
                transceiver.sender.streamIds = []
                setAppleTransceiverDirection(
                    .inactive,
                    transceiver: transceiver,
                    reason: "screen share stop (SFU inactive teardown)"
                )
            } else {
                setAppleTransceiverDirection(
                    .inactive,
                    transceiver: transceiver,
                    reason: "screen share stop"
                )
            }
        }
    }

    private func isReusableAppleScreenShareTransceiver(_ transceiver: WebRTC.RTCRtpTransceiver) -> Bool {
        guard transceiver.sender.track == nil else { return false }
        switch transceiver.direction {
        case .inactive, .recvOnly:
            return true
        default:
            return false
        }
    }

    private func isInactiveAppleScreenShareTransceiver(_ transceiver: WebRTC.RTCRtpTransceiver) -> Bool {
        guard transceiver.sender.track == nil else { return false }
        let hasScreenStreamId = transceiver.sender.streamIds.contains(where: Self.isScreenShareId)
        return hasScreenStreamId && isReusableAppleScreenShareTransceiver(transceiver)
    }

    private func isInactiveDedicatedScreenSlotTransceiver(_ transceiver: WebRTC.RTCRtpTransceiver) -> Bool {
        transceiver.sender.track == nil && isReusableAppleScreenShareTransceiver(transceiver)
    }

    private func reusableAppleScreenTransceiver(
        in peerConnection: WebRTC.RTCPeerConnection
    ) -> WebRTC.RTCRtpTransceiver? {
        for transceiver in peerConnection.transceivers where isInactiveAppleScreenShareTransceiver(transceiver) {
            return transceiver
        }

        let videoTransceivers = peerConnection.transceivers.filter { $0.mediaType == .video }
        guard videoTransceivers.count >= 2 else { return nil }

        for transceiver in videoTransceivers.dropFirst() where isInactiveDedicatedScreenSlotTransceiver(transceiver) {
            return transceiver
        }
        return nil
    }

    private func setAppleScreenTransceiverDirection(
        _ direction: WebRTC.RTCRtpTransceiverDirection,
        for sender: WebRTC.RTCRtpSender,
        in peerConnection: WebRTC.RTCPeerConnection,
        reason: String
    ) {
        guard let transceiver = appleTransceiver(for: sender, in: peerConnection) else {
            logger.log(level: .warning, message: "Could not find screen transceiver for \(reason)")
            return
        }
        setAppleTransceiverDirection(direction, transceiver: transceiver, reason: reason)
    }

    private func setAppleTransceiverDirection(
        _ direction: WebRTC.RTCRtpTransceiverDirection,
        transceiver: WebRTC.RTCRtpTransceiver,
        reason: String
    ) {
        var error: NSError?
        transceiver.setDirection(direction, error: &error)
        if let error {
            logger.log(level: .warning, message: "Failed to set screen transceiver direction for \(reason): \(error)")
        }
    }

    private func appleTransceiver(
        for sender: WebRTC.RTCRtpSender,
        in peerConnection: WebRTC.RTCPeerConnection
    ) -> WebRTC.RTCRtpTransceiver? {
        let senderId = sender.senderId
        let trackId = sender.track?.trackId
        return peerConnection.transceivers.first { transceiver in
            if transceiver.sender.senderId == senderId {
                return true
            }
            guard let trackId else { return false }
            return transceiver.sender.track?.trackId == trackId
        }
    }
    #endif

    // MARK: - Internal: create local screen track

#if canImport(WebRTC)
    /// Creates the platform-specific capture source + RTCVideoSource, starts feeding
    /// frames, and returns the configured screen track.
    internal func createLocalScreenTrack(
        target: ScreenShareTarget,
        options: ScreenShareOptions = ScreenShareOptions(),
        with connection: RTCConnection
    ) async throws -> (WebRTC.RTCVideoTrack, RTCConnection) {
        var updatedConnection = connection
        let videoSource = RTCSession.factory.videoSource()

        let screenTrackId = "\(Self.screenTrackPrefix)\(connection.localParticipantId)_\(connection.id)"
        let screenTrack = RTCSession.factory.videoTrack(with: videoSource, trackId: screenTrackId)
        updatedConnection.localScreenTrack = screenTrack
        updatedConnection.screenCaptureWrapper = RTCVideoCaptureWrapper(delegate: videoSource)

        #if !os(Android)
        let systemAudioEgress: any ScreenShareSystemAudioEgress = Self.supportsScreenShareSystemAudioEgress
            ? RTCSession.screenShareSystemAudioEgress
            : NoOpScreenShareSystemAudioEgress()
        #endif

        #if os(macOS)
        let captureGeneration = beginPlatformScreenCaptureGeneration()
        let connectionId = connection.id
        let captureSource = MacScreenCaptureSource(
            systemAudioEgress: systemAudioEgress,
            onUnexpectedStop: { [weak self] in
                Task { [weak self] in
                    await self?.platformScreenCaptureDidFinishUnexpectedly(
                        connectionId: connectionId,
                        generation: captureGeneration
                    )
                }
            }
        )
        _macScreenCaptureSourceStorage = captureSource
        do {
            try await captureSource.startCapture(target: target, options: options, videoSource: videoSource)
        } catch {
            if _macScreenCaptureSourceStorage === captureSource {
                _macScreenCaptureSourceStorage = nil
                invalidatePlatformScreenCaptureGeneration(captureGeneration)
            }
            throw error
        }
        #elseif os(iOS)
        guard case .appScreen = target else {
            throw RTCErrors.mediaError("iOS screen sharing requires the ReplayKit broadcast target")
        }
        let captureGeneration = beginPlatformScreenCaptureGeneration()
        let connectionId = connection.id
        let captureSource = iOSScreenCaptureSource(
            systemAudioEgress: systemAudioEgress,
            onBroadcastFinished: { [weak self] in
                Task { [weak self] in
                    await self?.platformScreenCaptureDidFinishUnexpectedly(
                        connectionId: connectionId,
                        generation: captureGeneration
                    )
                }
            },
            onBroadcastStarted: { [weak self] in
                Task { [weak self] in
                    await self?.screenCaptureDidBecomeReady(connectionId: connectionId)
                }
            }
        )
        _iOSScreenCaptureSourceStorage = captureSource
        do {
            try await captureSource.startCapture(options: options, videoSource: videoSource)
        } catch {
            if _iOSScreenCaptureSourceStorage === captureSource {
                _iOSScreenCaptureSourceStorage = nil
                invalidatePlatformScreenCaptureGeneration(captureGeneration)
            }
            throw error
        }
        #endif

        await connectionManager.updateConnection(id: connection.id, with: updatedConnection)
        return (screenTrack, updatedConnection)
    }
#endif

    // MARK: - Exclusive room screen share (1:1 / group / conference)

    /// True when the call uses an SFU room where only one participant may share at a time.
    static func shouldEnforceExclusiveRoomScreenShare(call: Call) -> Bool {
        if isTrueOneToOneSfuRoom(call: call) { return true }
        if call.conferencePassword != nil { return true }
        if call.resolvedChannelWireId != nil { return true }
        return false
    }

    /// Candidate connection ids for resolving an inbound ``PacketFlag/screenSharePreempt``.
    static func screenSharePreemptConnectionLookupIds(sfuIdentity: String, call: Call) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for raw in [sfuIdentity, call.sharedCommunicationId, call.resolvedChannelWireId ?? "", call.channelWireId ?? ""] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.normalizedUUIDConnectionId.lowercased()
            guard seen.insert(key).inserted else { continue }
            results.append(trimmed)
            let bare = trimmed.normalizedConnectionId
            if bare != trimmed, seen.insert(bare.lowercased()).inserted {
                results.append(bare)
            }
        }
        return results
    }

    func activeRemoteScreenShareParticipantIds(connection: RTCConnection) -> [String] {
        let localKey = Self.conferenceParticipantIdentityKey(connection.localParticipantId)
        var seen = Set<String>()
        var results: [String] = []

        func append(_ participantId: String) {
            guard Self.isPlausibleConferenceScreenShareParticipantId(participantId) else { return }
            let key = Self.conferenceParticipantIdentityKey(participantId)
            guard !key.isEmpty, key != localKey else { return }
            let normalized = key.lowercased()
            guard seen.insert(normalized).inserted else { return }
            results.append(participantId)
        }

        for participantId in connection.remoteScreenTracksByParticipantId.keys {
            append(participantId)
        }

        #if canImport(WebRTC)
        for participantId in sdpAdvertisedActiveRemoteScreenShareParticipantIds(connection: connection) {
            append(participantId)
        }
        #endif

        return results
    }

    static func remoteScreenShareParticipantMatches(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let leftKey = Self.conferenceParticipantIdentityKey(lhs)
        let rightKey = Self.conferenceParticipantIdentityKey(rhs)
        if !leftKey.isEmpty, !rightKey.isEmpty {
            return leftKey == rightKey
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func shouldAcceptRemoteScreenShareEnd(
        activeParticipantId: String?,
        endedParticipantId: String
    ) -> Bool {
        activeParticipantId == nil
            || remoteScreenShareParticipantMatches(activeParticipantId, endedParticipantId)
    }

    /// Ends any other participant's active room screen share before this client starts sharing.
    func enforceExclusiveScreenShareBeforeStarting(
        connectionId: String,
        connection: RTCConnection
    ) async throws {
        guard Self.shouldEnforceExclusiveRoomScreenShare(call: connection.call) else { return }

        let remoteSharers = activeRemoteScreenShareParticipantIds(connection: connection)
        guard !remoteSharers.isEmpty else { return }

        for participantId in remoteSharers {
            logger.log(
                level: .info,
                message: "Exclusive screen share: requesting stop for active sharer=\(participantId) before local start connId=\(connectionId)"
            )
            try await sendScreenSharePreempt(
                targetParticipantSecretName: participantId,
                connection: connection
            )
            await markRemoteScreenShareStopRequested(
                participantId: participantId,
                connectionId: connectionId
            )
            let didStop = await waitForRemoteScreenShareToEnd(
                participantId: participantId,
                connectionId: connectionId,
                connection: connection
            )
            guard didStop else {
                throw RTCErrors.mediaError("Waiting for \(participantId) to stop screen sharing. Try again in a moment.")
            }
            let transportStable = await waitForInboundTransportStable(
                connectionId: connectionId,
                timeoutSeconds: 6.0
            )
            if !transportStable {
                logger.log(
                    level: .warning,
                    message: "Exclusive screen share: remote sharer stopped but inbound transport not stable before local start connId=\(connectionId)"
                )
            }
            await clearRemoteScreenShareStopRequested(
                participantId: participantId,
                connectionId: connectionId
            )
        }
    }

    func sendScreenSharePreempt(
        targetParticipantSecretName: String,
        connection: RTCConnection
    ) async throws {
        let trimmedTarget = targetParticipantSecretName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return }

        var outboundCall = connection.call
        outboundCall.metadata = try BinaryEncoder().encode(
            ScreenSharePreemptCommand(targetParticipantSecretName: trimmedTarget)
        )
        let wireRoom = outboundCall.resolvedChannelWireId ?? outboundCall.sharedCommunicationId
        let plaintext = try BinaryEncoder().encode(outboundCall)
        let writeTask = WriteTask(
            data: plaintext,
            roomId: wireRoom.normalizedConnectionId,
            flag: .screenSharePreempt,
            call: outboundCall
        )
        try await taskProcessor.feedTask(task: EncryptableTask(task: .writeMessage(writeTask)))
    }

    /// Stops local capture when another participant takes over room screen share.
    public func handleInboundScreenSharePreempt(call: Call, sfuIdentity: String) async {
        guard let metadata = call.metadata else { return }
        guard let command = try? BinaryDecoder().decode(ScreenSharePreemptCommand.self, from: metadata) else {
            logger.log(level: .warning, message: "Ignoring screenSharePreempt with undecodable metadata room=\(sfuIdentity)")
            return
        }

        let lookupIds = Self.screenSharePreemptConnectionLookupIds(sfuIdentity: sfuIdentity, call: call)

        var connection: RTCConnection?
        for lookupId in lookupIds {
            if let found = await connectionManager.findConnection(with: lookupId) {
                connection = found
                break
            }
        }
        guard let connection else {
            logger.log(
                level: .warning,
                message: "Ignoring screenSharePreempt: no connection for lookupIds=\(lookupIds.joined(separator: ",")) target=\(command.targetParticipantSecretName)"
            )
            return
        }

        let localSecret = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSecret = command.targetParticipantSecretName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localSecret.isEmpty,
              !targetSecret.isEmpty,
              localSecret.caseInsensitiveCompare(targetSecret) == .orderedSame else {
            logger.log(
                level: .info,
                message: "Ignoring screenSharePreempt: local participant=\(localSecret) is not preempt target=\(targetSecret)"
            )
            return
        }
        guard connection.localScreenTrack != nil else {
            logger.log(
                level: .info,
                message: "Ignoring screenSharePreempt: local screen track already stopped connId=\(connection.id)"
            )
            return
        }

        logger.log(
            level: .info,
            message: "Received screenSharePreempt; stopping local screen share connId=\(connection.id)"
        )
        await removeScreenTrackFromStream(connectionId: connection.id)
    }

    /// How long to wait for a remote sharer to tear down after ``sendScreenSharePreempt``.
    ///
    /// SFU rooms need extra time: preempt → remote stop → renegotiation offer → SFU relay →
    /// local SDP reconcile can exceed direct P2P latency (observed ~10s on cross-region 1:1 SFU).
    static func exclusiveScreenShareStopWaitTimeout(for call: Call) -> Double {
        shouldEnforceExclusiveRoomScreenShare(call: call) ? 20.0 : 8.0
    }

    private func waitForRemoteScreenShareToEnd(
        participantId: String,
        connectionId: String,
        connection: RTCConnection,
        timeoutSeconds: Double? = nil
    ) async -> Bool {
        let targetKey = Self.conferenceParticipantIdentityKey(participantId).lowercased()
        guard !targetKey.isEmpty else { return true }

        let resolvedTimeout = timeoutSeconds ?? Self.exclusiveScreenShareStopWaitTimeout(for: connection.call)
        if await !remoteScreenShareStillActive(participantKey: targetKey, connectionId: connectionId) {
            return true
        }

        let stream = remoteScreenTrackStream()
        let deadline = Date().addingTimeInterval(resolvedTimeout)
        let didStop = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    guard event.connectionId.normalizedConnectionId == connectionId.normalizedConnectionId else {
                        continue
                    }
                    guard Self.conferenceParticipantIdentityKey(event.participantId).lowercased() == targetKey else {
                        continue
                    }
                    if !event.isActive {
                        return true
                    }
                }
                return false
            }
            group.addTask { [self] in
                while Date() < deadline {
                    if await !self.remoteScreenShareStillActive(participantKey: targetKey, connectionId: connectionId) {
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if didStop {
            clearRemoteScreenIngressFlatObservation(connectionId: connectionId, participantKey: targetKey)
            return true
        }

        // Grace re-check: remote may have stopped between the last poll and the timeout log.
        let graceSeconds = 5.0
        let graceDeadline = Date().addingTimeInterval(graceSeconds)
        while Date() < graceDeadline {
            if await !remoteScreenShareStillActive(participantKey: targetKey, connectionId: connectionId) {
                clearRemoteScreenIngressFlatObservation(connectionId: connectionId, participantKey: targetKey)
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        clearRemoteScreenIngressFlatObservation(connectionId: connectionId, participantKey: targetKey)
        logger.log(
            level: .warning,
            message: "Timed out waiting for remote screen share to end participant=\(participantId) connId=\(connectionId) waitedSeconds=\(resolvedTimeout + graceSeconds)"
        )
        return false
    }

    func remoteScreenIngressFlatObservationKey(
        connectionId: String,
        participantKey: String
    ) -> String {
        "\(connectionId.normalizedConnectionId)|\(participantKey.lowercased())"
    }

#if canImport(WebRTC)
    func clearRemoteScreenIngressFlatObservation(connectionId: String, participantKey: String) {
        remoteScreenIngressFlatSinceByKey.removeValue(
            forKey: remoteScreenIngressFlatObservationKey(connectionId: connectionId, participantKey: participantKey)
        )
    }

    /// Returns true once screen mid RTP has remained flat long enough to treat preempt as complete.
    func remoteScreenIngressCeasedIndicatingStop(
        connectionId: String,
        participantKey: String
    ) async -> Bool {
        guard ScreenShareGroupCallContract.preemptWaitAllowsIngressCeasedFallback else { return false }
        let observationKey = remoteScreenIngressFlatObservationKey(
            connectionId: connectionId,
            participantKey: participantKey
        )
        let now = Date()
        let flatSince = remoteScreenIngressFlatSinceByKey[observationKey]
        let hasSustainedFlatObservation = flatSince.map {
            now.timeIntervalSince($0) >= ScreenShareGroupCallContract.preemptWaitIngressCeasedMinimumFlatSeconds
        } ?? false

        guard let flow = await evaluateInboundRemoteScreenVideoFlow(connectionId: connectionId) else {
            if hasSustainedFlatObservation { return true }
            clearRemoteScreenIngressFlatObservation(connectionId: connectionId, participantKey: participantKey)
            return false
        }

        guard Self.screenFlowIndicatesRemoteShareStopped(flow) else {
            if hasSustainedFlatObservation,
               flow.deltaPacketsReceived <= 0,
               flow.deltaFramesReceived <= 0 {
                return true
            }
            clearRemoteScreenIngressFlatObservation(connectionId: connectionId, participantKey: participantKey)
            return false
        }

        if remoteScreenIngressFlatSinceByKey[observationKey] == nil {
            remoteScreenIngressFlatSinceByKey[observationKey] = now
            return false
        }
        guard hasSustainedFlatObservation else {
            return false
        }

        // Re-check once more after the sustained-flat window. If stats are temporarily unavailable
        // between probes, the elapsed window is still authoritative for preempt completion.
        if let refreshedFlow = await evaluateInboundRemoteScreenVideoFlow(connectionId: connectionId) {
            return Self.screenFlowIndicatesRemoteShareStopped(refreshedFlow)
        }
        return true
    }
#else
    func clearRemoteScreenIngressFlatObservation(connectionId: String, participantKey: String) {}

    func remoteScreenIngressCeasedIndicatingStop(
        connectionId: String,
        participantKey: String
    ) async -> Bool {
        false
    }
#endif

    private func remoteScreenShareStillActive(participantKey: String, connectionId: String) async -> Bool {
        guard let connection = await connectionManager.findConnection(with: connectionId) else { return false }

        func mappingStillLive(in connection: RTCConnection) -> Bool {
            connection.remoteScreenTracksByParticipantId.contains { participantId, track in
                guard Self.isPlausibleConferenceScreenShareParticipantId(participantId) else { return false }
                guard Self.conferenceParticipantIdentityKey(participantId).lowercased() == participantKey else { return false }
                #if canImport(WebRTC)
                return track.readyState != .ended
                #else
                return true
                #endif
            }
        }

        func sdpStillAdvertisesShare(in connection: RTCConnection) -> String? {
            #if canImport(WebRTC)
            guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
                  !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return sdpAdvertisedActiveRemoteScreenShareParticipantIds(connection: connection).first {
                Self.conferenceParticipantIdentityKey($0).lowercased() == participantKey
            }
            #else
            return nil
            #endif
        }

        if connection.remoteScreenShareStopRequestedParticipantKeys.contains(participantKey) {
            #if canImport(WebRTC)
            if let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
               !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let mappedParticipantId = connection.remoteScreenTracksByParticipantId.keys.first(where: {
                    Self.conferenceParticipantIdentityKey($0).lowercased() == participantKey
                }) ?? sdpStillAdvertisesShare(in: connection)
                if let mappedParticipantId,
                   isRemoteScreenShareExplicitlyStoppedInSDP(
                       participantId: mappedParticipantId,
                       remoteSdp: remoteSdp,
                       connection: connection
                   ) {
                    await reconcilePendingRemoteScreenShareStop(connectionId: connectionId)
                    return false
                }
            }
            #endif

            if await remoteScreenIngressCeasedIndicatingStop(
                connectionId: connectionId,
                participantKey: participantKey
            ) {
                logger.log(
                    level: .info,
                    message: "Remote screen share treated as stopped after flat screen ingress participantKey=\(participantKey) connId=\(connectionId)"
                )
                await reconcilePendingRemoteScreenShareStop(connectionId: connectionId)
                clearRemoteScreenIngressFlatObservation(connectionId: connectionId, participantKey: participantKey)
                return false
            }

            if mappingStillLive(in: connection) || sdpStillAdvertisesShare(in: connection) != nil {
                return true
            }
            return false
        }

        if mappingStillLive(in: connection) {
            return true
        }

        return sdpStillAdvertisesShare(in: connection) != nil
    }

    #if canImport(WebRTC)
    private func waitForInboundTransportStable(
        connectionId: String,
        timeoutSeconds: Double
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let flow = await evaluateInboundRemoteVideoFlow(connectionId: connectionId),
               flow.dtlsState == "connected",
               flow.selectedPairState == "succeeded" || flow.selectedPairState == "in-progress" || flow.selectedPairState == "inprogress" {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
    #else
    private func waitForInboundTransportStable(
        connectionId: String,
        timeoutSeconds: Double
    ) async -> Bool {
        _ = connectionId
        _ = timeoutSeconds
        return true
    }
    #endif

    private func markRemoteScreenShareStopRequested(participantId: String, connectionId: String) async {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return }
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard connection.remoteScreenShareStopRequestedParticipantKeys.insert(participantKey).inserted else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }

    private func clearRemoteScreenShareStopRequested(participantId: String, connectionId: String) async {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return }
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard connection.remoteScreenShareStopRequestedParticipantKeys.remove(participantKey) != nil else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }

    private func clearRemoteScreenShareMappingsBeforeLocalStart(connectionId: String) async {
        guard var connection = await connectionManager.findConnection(with: connectionId) else { return }
        guard !connection.remoteScreenTracksByParticipantId.isEmpty else { return }

        let localKey = Self.conferenceParticipantIdentityKey(connection.localParticipantId)
        var didUpdate = false
        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) {
            let participantKey = Self.conferenceParticipantIdentityKey(participantId)
            guard participantKey != localKey else { continue }
            connection.remoteScreenTracksByParticipantId.removeValue(forKey: participantId)
#if canImport(WebRTC) && !os(Android)
            if let cryptor = connection.screenReceiverCryptorsByParticipantId.removeValue(forKey: participantId) {
                cryptor.enabled = false
                cryptor.delegate = nil
            }
            connection.screenReceiverCryptorBindingsByParticipantId.removeValue(forKey: participantId)
#endif
            if !participantKey.isEmpty {
                connection.suppressedRemoteScreenShareParticipantIds.insert(participantKey)
            }
            didUpdate = true
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(connectionId: connectionId, participantId: participantId, isActive: false)
            )
        }
        guard didUpdate else { return }
        await connectionManager.updateConnection(id: connection.id, with: connection)
    }

    private func reconcilePendingRemoteScreenShareStop(connectionId: String) async {
        guard let connection = await connectionManager.findConnection(with: connectionId),
              !connection.remoteScreenShareStopRequestedParticipantKeys.isEmpty
        else { return }
        #if canImport(WebRTC)
        guard let remoteSdp = connection.peerConnection.remoteDescription?.sdp,
              !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        await reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(remoteSdp, connectionId: connectionId)
        #endif
    }

    /// Removes stale remote screen-share tiles/tracks so only one sharer is active in the UI.
    func supersedeRemoteScreenShares(
        connectionId: String,
        keepingParticipantId activeParticipantId: String
    ) async {
        let normalizedConnectionId = connectionId.normalizedConnectionId
        guard let connection = await connectionManager.findConnection(with: normalizedConnectionId) else { return }

        let activeKey = Self.conferenceParticipantIdentityKey(activeParticipantId).lowercased()
        for participantId in Array(connection.remoteScreenTracksByParticipantId.keys) {
            let key = Self.conferenceParticipantIdentityKey(participantId).lowercased()
            guard !key.isEmpty, key != activeKey else { continue }
            notifyRemoteScreenTrackChanged(
                RemoteScreenTrackEvent(
                    connectionId: normalizedConnectionId,
                    participantId: participantId,
                    isActive: false
                )
            )
        }
    }

    // MARK: - Platform capture source helpers

#if os(iOS) || os(Android)
    private func screenCaptureDidBecomeReady(connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        clearAbandonedScreenShareCaptureCleanupTask(for: normalizedId)
        guard pendingScreenShareRenegotiationConnectionIds.remove(normalizedId) != nil else { return }
        do {
            try await renegotiateScreenShareIfNeeded(
                connectionId: normalizedId,
                reason: "capture-ready"
            )
            notifyLocalScreenShareChanged(isSharing: true)
        } catch {
            logger.log(
                level: .warning,
                message: "Screen share capture became ready but renegotiation failed for connection \(normalizedId); cleaning up local capture: \(error)"
            )
            await removeScreenTrackFromStream(connectionId: normalizedId)
        }
    }
#endif

#if os(iOS) || os(macOS) || os(Android)
    private func platformScreenCaptureDidFinishUnexpectedly(
        connectionId: String,
        generation: UInt64
    ) async {
        guard isCurrentPlatformScreenCaptureGeneration(generation) else {
            logger.log(level: .debug, message: "Ignored stale screen capture termination callback generation=\(generation)")
            return
        }
        await removeScreenTrackFromStream(connectionId: connectionId)
    }
#endif

    var screenCaptureSourceForCurrentPlatform: Any? {
        #if os(macOS)
        return _macScreenCaptureSourceStorage
        #elseif os(iOS) && !os(Android)
        return _iOSScreenCaptureSourceStorage
        #else
        return nil
        #endif
    }

    func stopPlatformScreenCapture(_ source: Any) async {
        #if os(macOS)
        if let macSource = source as? MacScreenCaptureSource {
            let ownsCurrentCapture = _macScreenCaptureSourceStorage === macSource
            if ownsCurrentCapture {
                invalidatePlatformScreenCaptureGeneration()
            }
            await macSource.stopCapture()
            if _macScreenCaptureSourceStorage === macSource {
                _macScreenCaptureSourceStorage = nil
            }
        }
        #elseif os(iOS) && !os(Android)
        if let iosSource = source as? iOSScreenCaptureSource {
            let ownsCurrentCapture = _iOSScreenCaptureSourceStorage === iosSource
            if ownsCurrentCapture {
                invalidatePlatformScreenCaptureGeneration()
            }
            await iosSource.stopCapture()
            if _iOSScreenCaptureSourceStorage === iosSource {
                _iOSScreenCaptureSourceStorage = nil
            }
        }
        #endif
    }

    // MARK: - Screen-share system audio egress lifecycle

#if canImport(WebRTC) && !os(Android)
    /// Ensures mid=0 can carry mixed system audio. When the mic was muted we
    /// re-enable the audio sender but suppress mic samples in the capture
    /// post-processor so remotes hear app audio only.
    private func beginSystemAudioShareEgress(
        connectionId: String,
        connection: RTCConnection
    ) async throws {
        let normalizedId = connectionId.normalizedConnectionId
        guard systemAudioShareActiveConnectionIds.insert(normalizedId).inserted else { return }

        let micEgressDisabled = isLocalAudioEgressDisabled(on: connection)
        systemAudioShareMicWasMutedByConnectionId[normalizedId] = micEgressDisabled

        if micEgressDisabled {
            try await setAudioTrack(isEnabled: true, connectionId: normalizedId)
#if os(iOS)
            setAudio(true)
#endif
            logger.log(
                level: .info,
                message: "Enabled audio egress for screen-share system audio while keeping mic suppressed connection=\(normalizedId)"
            )
        } else {
            logger.log(
                level: .info,
                message: "Screen-share system audio will mix into the active mic track connection=\(normalizedId)"
            )
        }

        RTCSession.activateSystemAudioCaptureProcessing()
        RTCSession.screenShareSystemAudioProcessor.setSuppressMicCapture(micEgressDisabled)
    }

    private func endSystemAudioShareEgressIfNeeded(connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        guard systemAudioShareActiveConnectionIds.remove(normalizedId) != nil else { return }

        RTCSession.screenShareSystemAudioProcessor.setSuppressMicCapture(false)
        RTCSession.deactivateSystemAudioCaptureProcessing()

        guard systemAudioShareMicWasMutedByConnectionId.removeValue(forKey: normalizedId) == true else {
            return
        }
        do {
            try await setAudioTrack(isEnabled: false, connectionId: normalizedId)
            logger.log(
                level: .info,
                message: "Restored muted mic after screen-share system audio connection=\(normalizedId)"
            )
        } catch {
            logger.log(
                level: .warning,
                message: "Failed to restore muted mic after screen-share system audio connection=\(normalizedId): \(error)"
            )
        }
    }

    private func isLocalAudioEgressDisabled(on connection: RTCConnection) -> Bool {
        for sender in connection.peerConnection.senders {
            guard sender.track?.kind == kRTCMediaStreamTrackKindAudio else { continue }
            if let track = sender.track as? RTCAudioTrack, !track.isEnabled {
                return true
            }
            let params = sender.parameters
            if !params.encodings.isEmpty, params.encodings.contains(where: { !$0.isActive }) {
                return true
            }
            return false
        }
        if let track = connection.localAudioTrack, !track.isEnabled {
            return true
        }
        return false
    }
#endif
}
