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

    /// The bundled Apple WebRTC API exposes device audio capture, but not a public
    /// push-audio source that can feed ScreenCaptureKit PCM samples into RTP.
    public static let supportsScreenShareSystemAudioEgress = false

    /// Whether a track id or stream id represents a screen share.
    static func isScreenShareId(_ id: String) -> Bool {
        id.hasPrefix(screenTrackPrefix)
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

        if connection.localScreenTrack != nil {
            logger.log(level: .info, message: "Screen share already active; stopping previous before starting new")
            await removeScreenTrackFromStream(connectionId: connectionId)
            if let updated = await connectionManager.findConnection(with: normalizedId) {
                connection = updated
            }
        }

#if os(Android)
        logger.log(level: .info, message: "Adding Android screen share track")
        guard let snapshot = androidMediaProjectionPermission.readSnapshot() else {
            throw RTCErrors.mediaError("MediaProjection result not set. Call setAndroidMediaProjectionResult before starting screen share.")
        }
        let screenTrack = try rtcClient.prepareScreenShareSendRecv(
            id: "\(connection.localParticipantId)",
            resultCode: snapshot.resultCode,
            data: snapshot.intent
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
        #if os(macOS)
        guard !options.shareSystemAudio || Self.supportsScreenShareSystemAudioEgress else {
            throw RTCErrors.mediaError(
                "Sharing device audio is not available in this WebRTC build. Start screen sharing without Share system audio."
            )
        }
        #endif
        let (screenTrack, updatedConnection) = try await createLocalScreenTrack(
            target: target,
            options: options,
            with: connection
        )
        connection = updatedConnection

        let streamId = "\(Self.screenStreamPrefix)\(connection.localParticipantId)"
        let maybeScreenSender = addAppleScreenSender(
            screenTrack,
            streamId: streamId,
            to: connection.peerConnection
        )

        if enableEncryption, let screenSender = maybeScreenSender, connection.screenSenderCryptor == nil {
            do {
                try await self.createEncryptedFrame(
                    connection: connection,
                    kind: .screenSender(screenSender)
                )
            } catch {
                logger.log(level: .warning, message: "Failed to create screen sender FrameCryptor: \(error)")
            }
        }

        await connectionManager.updateConnection(id: normalizedId, with: connection)
#endif
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
        logger.log(level: .info, message: "Screen share track added for connection \(normalizedId)")
    }

    static func shouldEnforceScreenShareConferencePermissions(
        call: Call,
        permissions: ConferencePermissions
    ) -> Bool {
        if Self.isTrueOneToOneSfuRoom(call: call) {
            return false
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
        rtcClient.stopScreenCapture()
        connection.localScreenTrack = nil
        if !reflectedLocalScreenParticipants.isEmpty {
            connection.remoteScreenTrack = nil
        }
        await connectionManager.updateConnection(id: normalizedId, with: connection)
#elseif canImport(WebRTC)
        if let screenTrack = connection.localScreenTrack {
            for sender in connection.peerConnection.senders where sender.track?.trackId == screenTrack.trackId {
                removeAppleScreenSender(sender, from: connection.peerConnection)
            }
        }

        if let captureSource = screenCaptureSourceForCurrentPlatform {
            await stopPlatformScreenCapture(captureSource)
        }

        connection.screenSenderCryptor?.enabled = false
        connection.screenSenderCryptor?.delegate = nil
        connection.screenSenderCryptor = nil
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

    private func renegotiateScreenShareIfNeeded(
        connectionId: String,
        reason: String
    ) async throws {
        let normalizedId = connectionId.normalizedConnectionId
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

    private func removeAppleScreenSender(
        _ sender: WebRTC.RTCRtpSender,
        from peerConnection: WebRTC.RTCPeerConnection
    ) {
        let transceiver = appleTransceiver(for: sender, in: peerConnection)
        let didRemove = peerConnection.removeTrack(sender)
        if !didRemove {
            logger.log(level: .warning, message: "Failed to remove screen sender from PeerConnection")
        }

        if let transceiver {
            setAppleTransceiverDirection(
                .inactive,
                transceiver: transceiver,
                reason: "screen share stop"
            )
        }
    }

    private func reusableAppleScreenTransceiver(
        in peerConnection: WebRTC.RTCPeerConnection
    ) -> WebRTC.RTCRtpTransceiver? {
        peerConnection.transceivers.first { transceiver in
            transceiver.sender.track == nil
                && transceiver.sender.streamIds.contains(where: Self.isScreenShareId)
                && transceiver.direction == .inactive
        }
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

        #if os(macOS)
        let captureGeneration = beginPlatformScreenCaptureGeneration()
        let connectionId = connection.id
        let captureSource = MacScreenCaptureSource { [weak self] in
            Task { [weak self] in
                await self?.platformScreenCaptureDidFinishUnexpectedly(
                    connectionId: connectionId,
                    generation: captureGeneration
                )
            }
        }
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
        let captureSource = iOSScreenCaptureSource { [weak self] in
            Task { [weak self] in
                await self?.platformScreenCaptureDidFinishUnexpectedly(
                    connectionId: connectionId,
                    generation: captureGeneration
                )
            }
        }
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

    // MARK: - Platform capture source helpers

#if os(iOS) || os(macOS)
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
}
