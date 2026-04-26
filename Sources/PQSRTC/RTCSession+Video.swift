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

import NeedleTailLogger
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
    
#if os(Android)
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

        connection.remoteVideoTrack = client.getRemoteVideoTrack(peerConnection: connection.peerConnection)
        
        if let videoTrack = connection.remoteVideoTrack {
            logger.log(level: .info, message: "Found remote video track, attaching renderer - trackId: \(videoTrack.trackId)")
            view.attach(videoTrack)
            pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: normalizedId)
        } else {
            logger.log(level: .info, message: "Remote renderer buffered; will attach when receiver/track is added")
        }
        
        await manager.updateConnection(id: normalizedId, with: connection)
    }

    /// Render a specific participant's video to an Android view (for group/conference calls).
    func renderRemoteVideoForParticipant(to view: AndroidSampleCaptureView, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote video for participant=\(participantId) connection=\(connectionId)")
        let manager = connectionManager as RTCConnectionManager

        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "No connection found for participant render: \(connectionId)")
            return
        }

        guard let videoTrack = connection.remoteVideoTracksByParticipantId[participantId] else {
            logger.log(level: .info, message: "Track not yet available for participant=\(participantId), will attach on arrival")
            return
        }

        view.attach(videoTrack)
        logger.log(level: .info, message: "Attached renderer to participant=\(participantId) trackId=\(videoTrack.trackId)")
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

    /// Render a remote screen share track to an Android view.
    func renderRemoteScreenVideo(to view: AndroidSampleCaptureView, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote screen video for connection=\(connectionId) participant=\(participantId)")
        let manager = connectionManager as RTCConnectionManager

        guard var connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "renderRemoteScreenVideo: connection not found for \(connectionId)")
            return
        }

        // Prefer per-participant lookup, fall back to legacy single track
        var screenTrack = connection.remoteScreenTracksByParticipantId[participantId]
        if screenTrack == nil {
            screenTrack = connection.remoteScreenTrack
                ?? rtcClient.getRemoteScreenVideoTrack(peerConnection: connection.peerConnection)
            if let screenTrack {
                connection.remoteScreenTrack = screenTrack
                await manager.updateConnection(id: normalizedId, with: connection)
            }
        }

        if let screenTrack {
            view.attach(screenTrack)
            logger.log(level: .info, message: "Remote screen renderer attached for participant=\(participantId)")
        } else {
            logger.log(level: .warning, message: "renderRemoteScreenVideo: screen track not available yet for participant=\(participantId)")
        }
    }

    /// Removes a renderer previously bound via `renderRemoteScreenVideo`.
    func removeRemoteScreenVideoRenderer(_ view: AndroidSampleCaptureView, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        let screenTrack = connection.remoteScreenTracksByParticipantId[participantId] ?? connection.remoteScreenTrack
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

        // Prefer any track already cached from delegate events; otherwise try to read from transceivers.
        if connection.remoteVideoTrack == nil {
            connection.remoteVideoTrack = connection.peerConnection.transceivers.first { $0.mediaType == .video }?.receiver.track as? WebRTC.RTCVideoTrack
        }
        
        if let videoTrack = connection.remoteVideoTrack {
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                logger.log(level: .trace, message: "Found remote video track, attaching renderer")
                logger.log(level: .trace, message: "Video track details - trackId: \(videoTrack.trackId), enabled: \(videoTrack.isEnabled), readyState: \(videoTrack.readyState.rawValue)")
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
            connection.remoteVideoTrack?.remove(renderer)
            videoTrack.add(renderer)

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
            logger.log(level: .warning, message: "Remote video track is nil - transceivers: \(connection.peerConnection.transceivers.count)")
            if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                logger.log(level: .trace, message: "Remote renderer buffered; will attach when receiver/track is added")
                for (index, transceiver) in connection.peerConnection.transceivers.enumerated() {
                    logger.log(level: .trace, message: "Transceiver \(index): mediaType=\(transceiver.mediaType), receiver.track=\(String(describing: transceiver.receiver.track))")
                }
            }
        }
        await manager.updateConnection(id: normalizedId, with: connection)
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
        guard let track = await connectionManager.findConnection(with: normalizedId)?.remoteVideoTrack else {
            return true
        }
        return track.isEnabled
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
            connection.remoteVideoTrack = connection.peerConnection.transceivers.first { $0.mediaType == .video }?.receiver.track as? WebRTC.RTCVideoTrack
        }
        guard let videoTrack = connection.remoteVideoTrack else {
            logger.log(level: .warning, message: "addAuxiliaryRemoteVideoRenderer: remote video track nil")
            return
        }
        if !connection.auxiliaryRemoteVideoRenderers.contains(where: { $0 === renderer }) {
            connection.auxiliaryRemoteVideoRenderers.append(renderer)
        }
        videoTrack.add(renderer)
        await manager.updateConnection(id: normalizedId, with: connection)
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

    /// After an SFU-driven SDP renegotiation, the inbound camera track on the video transceiver may be
    /// replaced without another `didAddReceiver` — renderers would stay on the old track and never
    /// receive frames. Refreshes from live transceivers and re-attaches pending + auxiliary sinks.
    func rebindInboundRemoteVideoAfterSfuRenegotiationIfNeeded(call: Call) async {
        guard call.supportsVideo else { return }
        guard Self.isTrueOneToOneSfuRoom(call: call) else { return }

        let norm = call.sharedCommunicationId.normalizedConnectionId
        guard var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) else { return }
        guard let resolved = Self.resolveLiveInboundCameraVideoTrack(from: connection.peerConnection) else {
            logger.log(level: .debug, message: "rebindInboundRemoteVideoAfterSfuRenegotiationIfNeeded: no live inbound camera track conn=\(norm)")
            return
        }

        let previous = connection.remoteVideoTrack
        if let previous, previous.trackId == resolved.trackId, previous === resolved {
            return
        }

        logger.log(
            level: .info,
            message: "SFU renegotiation: rebinding remote video renderers oldTrackId=\(previous?.trackId ?? "nil") newTrackId=\(resolved.trackId) conn=\(norm)"
        )

        if let previous {
            if let pending = pendingRemoteVideoRenderersByConnectionId[norm] {
                previous.remove(pending)
            }
            for aux in connection.auxiliaryRemoteVideoRenderers {
                previous.remove(aux)
            }
        }

        connection.remoteVideoTrack = resolved
        let remotePid = connection.remoteParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previous {
            connection.remoteVideoTracksByParticipantId = connection.remoteVideoTracksByParticipantId.filter { _, track in
                track !== previous
            }
        }
        if !remotePid.isEmpty {
            connection.remoteVideoTracksByParticipantId[remotePid] = resolved
        }

        if let pending = pendingRemoteVideoRenderersByConnectionId[norm] {
            resolved.add(pending)
        }
        for aux in connection.auxiliaryRemoteVideoRenderers {
            resolved.add(aux)
        }

        await connectionManager.updateConnection(id: connection.id, with: connection)

        #if canImport(WebRTC)
        logRtpStatsSnapshotOnce(
            connectionId: norm,
            delayNanoseconds: 2_000_000_000,
            reason: "afterSfuRenegotiationRemoteVideoRebind")
        startInboundVideoFlowProbe(connectionId: norm)
        #endif
    }

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

    /// Binds a renderer to a remote participant's screen-share track.
    ///
    /// This mirrors ``renderRemoteVideo(to:with:)`` but targets the screen track stored in
    /// ``RTCConnection/remoteScreenTracksByParticipantId`` instead of the camera track.
    func renderRemoteScreenVideo(to renderer: RTCVideoRenderWrapper, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        logger.log(level: .info, message: "Rendering remote screen video for connection=\(connectionId) participant=\(participantId)")
        let manager = connectionManager as RTCConnectionManager

        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else {
            logger.log(level: .error, message: "renderRemoteScreenVideo: connection not found for \(connectionId)")
            return
        }

        guard let screenTrack = connection.remoteScreenTracksByParticipantId[participantId] else {
            logger.log(level: .warning, message: "renderRemoteScreenVideo: screen track not found for participant=\(participantId)")
            return
        }

        screenTrack.add(renderer)
        logger.log(level: .info, message: "Remote screen renderer attached for participant=\(participantId) trackId=\(screenTrack.trackId)")
    }

    /// Removes a renderer previously bound via ``renderRemoteScreenVideo(to:connectionId:participantId:)``.
    func removeRemoteScreenVideoRenderer(_ renderer: RTCVideoRenderWrapper, connectionId: String, participantId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: normalizedId) else { return }
        connection.remoteScreenTracksByParticipantId[participantId]?.remove(renderer)
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
        if connection.id.isGroupCall {
            if isEnabled {
                await startAdaptiveVideoSendIfNeeded(connectionId: normalizedId)
            } else {
                stopAdaptiveVideoSend(connectionId: normalizedId)
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
