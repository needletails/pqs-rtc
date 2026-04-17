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
#if canImport(WebRTC)
import WebRTC
#endif

extension RTCSession {

    // MARK: - Screen share track prefix

    static let screenTrackPrefix = "screen_"
    static let screenStreamPrefix = "screen_"

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
        guard conferencePermissions.canScreenShare else {
            throw RTCErrors.permissionDenied("Screen sharing requires Presenter role or higher")
        }

        let normalizedId = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: normalizedId) else {
            throw RTCErrors.connectionNotFound
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
        let (screenTrack, updatedConnection) = try await createLocalScreenTrack(
            target: target,
            with: connection
        )
        connection = updatedConnection

        let streamId = "\(Self.screenStreamPrefix)\(connection.localParticipantId)"
        let maybeScreenSender = connection.peerConnection.add(screenTrack, streamIds: [streamId])

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
        logger.log(level: .info, message: "Screen share track added for connection \(normalizedId)")
    }

    /// Removes the screen share track and stops capture.
    public func removeScreenTrackFromStream(connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: normalizedId) else {
            return
        }

#if os(Android)
        rtcClient.stopScreenCapture()
        connection.localScreenTrack = nil
        await connectionManager.updateConnection(id: normalizedId, with: connection)
#elseif canImport(WebRTC)
        if let screenTrack = connection.localScreenTrack {
            for sender in connection.peerConnection.senders where sender.track?.trackId == screenTrack.trackId {
                connection.peerConnection.removeTrack(sender)
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
        logger.log(level: .info, message: "Screen share track removed for connection \(normalizedId)")
    }

    // MARK: - Internal: create local screen track

#if canImport(WebRTC)
    /// Creates the platform-specific capture source + RTCVideoSource, starts feeding
    /// frames, and returns the configured screen track.
    internal func createLocalScreenTrack(
        target: ScreenShareTarget,
        with connection: RTCConnection
    ) async throws -> (WebRTC.RTCVideoTrack, RTCConnection) {
        var updatedConnection = connection
        let videoSource = RTCSession.factory.videoSource()

        let screenTrackId = "\(Self.screenTrackPrefix)\(connection.localParticipantId)_\(connection.id)"
        let screenTrack = RTCSession.factory.videoTrack(with: videoSource, trackId: screenTrackId)
        updatedConnection.localScreenTrack = screenTrack
        updatedConnection.screenCaptureWrapper = RTCVideoCaptureWrapper(delegate: videoSource)

        #if os(macOS)
        let captureSource = MacScreenCaptureSource()
        try await captureSource.startCapture(target: target, videoSource: videoSource)
        _macScreenCaptureSourceStorage = captureSource
        #elseif os(iOS)
        let captureSource = iOSScreenCaptureSource()
        try await captureSource.startCapture(videoSource: videoSource)
        _iOSScreenCaptureSourceStorage = captureSource
        #endif

        await connectionManager.updateConnection(id: connection.id, with: updatedConnection)
        return (screenTrack, updatedConnection)
    }
#endif

    // MARK: - Platform capture source helpers

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
            await macSource.stopCapture()
            _macScreenCaptureSourceStorage = nil
        }
        #elseif os(iOS) && !os(Android)
        if let iosSource = source as? iOSScreenCaptureSource {
            await iosSource.stopCapture()
            _iOSScreenCaptureSourceStorage = nil
        }
        #endif
    }
}
