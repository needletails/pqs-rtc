//
//  RTCSession+PeerConnection.swift
//  pqs-rtc
//
//  Created by Cole M on 12/2/25.
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
import DoubleRatchetKit
#if os(iOS)
import AVFoundation
#endif
#if canImport(WebRTC)
import WebRTC
#endif

extension RTCSession {
    
    /// Creates and configures a new peer connection for a call.
    ///
    /// This helper constructs the platform-appropriate `RTCPeerConnection` (Apple WebRTC or the
    /// Android client wrapper), registers the delegate bridge used to surface peer connection events,
    /// and attaches local media tracks.
    ///
    /// If `willFinishNegotiation` is `false`, this method also performs the cryptographic message-key
    /// setup needed for frame-encrypted media before returning.
    ///
    /// - Parameters:
    ///   - call: The call context used to derive the connection identifier and media capabilities.
    ///   - sender: The local participant identifier used for call/session routing.
    ///   - recipient: The remote participant identifier used for call/session routing.
    ///   - localIdentity: The local cryptographic identity material for this connection.
    ///   - sessionIdentity: The per-connection session identity used by the ratchet/key manager.
    ///   - willFinishNegotiation: If `true`, defers message-key setup so the caller can complete
    ///     negotiation first.
    /// - Returns: A fully created `RTCConnection` registered with the connection manager.
    /// - Throws: `RTCErrors` or platform-specific errors if the peer connection or media setup fails.
    public func createPeerConnection(
        with call: Call,
        sender: String,
        recipient: String,
        localIdentity: ConnectionLocalIdentity,
        sessionIdentity: SessionIdentity,
        willFinishNegotiation: Bool = false
    ) async throws -> RTCConnection {
        logger.log(level: .info, message: "Creating peer connection with id: \(call.sharedCommunicationId), hasVideo: \(call.supportsVideo)")
        // Validate input parameters
        guard !call.sharedCommunicationId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw RTCErrors.invalidConfiguration("Connection ID cannot be empty")
        }
        
        let localKeys = localIdentity.localKeys
        let symmetricKey = localIdentity.symmetricKey
        
        var connection: RTCConnection?
#if os(Android)
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: call.sharedCommunicationId,
            logger: logger,
            continuation: peerConnectionNotificationsContinuation)
        rtcClient.setEventDelegate(delegateWrapper.delegate)
        delegateWrapper.delegate?.setRTCClient(rtcClient)
        
        // Create media constraints similar to iOS configuration
        let constraints = rtcClient.createConstraints(
            optional: [
                "DtlsSrtpKeyAgreement": "true",
                "googDscp": "true"
            ]
        )
        do {
            logger.log(level: .info, message: "Creating peer connection with id: \(call.sharedCommunicationId), hasVideo: \(call.supportsVideo)")
            // Initialize the factory with ICE servers (now properly configured)
            let peerConnection = try self.rtcClient.initializeFactory(
                iceServers: self.iceServers,
                username: self.username,
                password: self.password
            )
            logger.log(level: .info, message: "Successfully initialized factory for connection: \(call.sharedCommunicationId)")
            
            connection = RTCConnection(
                id: call.sharedCommunicationId,
                peerConnection: RTCPeerConnection(peerConnection),
                delegateWrapper: delegateWrapper,
                sender: sender,
                recipient: recipient,
                localKeys: localKeys,
                symmetricKey: symmetricKey,
                sessionIdentity: sessionIdentity,
                call: call)
            
            logger.log(level: .info, message: "Successfully created RTCConnection: \(call.sharedCommunicationId)")
        } catch {
            logger.log(level: .error, message: "There was an error creating the peer connection: \(error)")
            throw error  // Re-throw to prevent continuing with nil connection
        }
        logger.log(level: .info, message: "Connection created: \(String(describing: connection))")
#elseif canImport(WebRTC)
        let config = WebRTC.RTCConfiguration()
        let iceServers = [
            WebRTC.RTCIceServer(
                urlStrings: self.iceServers,
                username: self.username,
                credential: self.password)
        ]
        
        config.iceServers = iceServers
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        config.enableDscp = true
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        config.continualGatheringPolicy = .gatherContinually
        
        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = WebRTC.RTCMediaConstraints(mandatoryConstraints: nil,
                                                     optionalConstraints: [
                                                        "DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue,
                                                        "googDscp" : kRTCMediaConstraintsValueTrue]
        )
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: call.sharedCommunicationId,
            logger: self.logger,
            continuation: peerConnectionNotificationsContinuation)
        
        // Apple Platform WebRTC peer connection creation
        guard let createdPeerConnection = RTCSession.factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegateWrapper.delegate
        ) else {
            logger.log(level: .error, message: "Failed to create RTCPeerConnection")
            throw RTCErrors.mediaError("Failed to create RTCPeerConnection")
        }
        
        createdPeerConnection.delegate = delegateWrapper.delegate
        
        connection = RTCConnection(
            id: call.sharedCommunicationId,
            peerConnection: createdPeerConnection,
            delegateWrapper: delegateWrapper,
            sender: sender,
            recipient: recipient,
            localKeys: localKeys,
            symmetricKey: symmetricKey,
            sessionIdentity: sessionIdentity,
            call: call)
#endif
        
#if os(iOS)
        do {
            try self.configureAudioSession()
        } catch {
            logger.log(level: .error, message: "Failed to configure audio session: \(error)")
            throw RTCErrors.mediaError("Failed to configure audio session: \(error.localizedDescription)")
        }
#endif
        
        guard var connection else {
            logger.log(level: .error, message: "Failed to create RTCPeerConnection")
            throw RTCErrors.mediaError("Failed to create RTCPeerConnection")
        }
        
        // Add connection to manager BEFORE adding tracks to ensure notifications work
        await connectionManager.addConnection(connection)
        
        // Start notification handling if not already running
        handleNotificationsStream()
        
        if !willFinishNegotiation {
            try await setMessageKey(connection: connection, call: call)
            if let foundConnection = await connectionManager.findConnection(with: connection.id) {
                connection = foundConnection
            }
        }
        // Add audio and video tracks (this may trigger notifications immediately)
        connection = try await self.addAudioToStream(with: connection)
        if call.supportsVideo {
            connection = try await self.addVideoToStream(with: connection)
        }
        
        // Update connection in manager with any changes from adding tracks
        await connectionManager.updateConnection(id: connection.id, with: connection)
        
        logger.log(level: .info, message: "Successfully created peer connection with id: \(call.sharedCommunicationId)")
        return connection
    }
    
    /// Tears down the session and releases all call-related resources.
    ///
    /// This is the terminal cleanup path for the `RTCSession` instance. It ends any active call,
    /// finishes state streams, closes all peer connections, cancels internal tasks, and clears
    /// crypto/key state so the next call starts from a clean slate.
    ///
    /// - Parameter call: The call to end. If `nil`, the session attempts to close any remaining
    ///   connections as a fallback.
    public func shutdown(with call: Call?) async {
        // Stop background consumers first so we don't process late callbacks
        // while tearing down peer connections.
        stateTask?.cancel()
        stateTask = nil
        // Retire peer-notifications consumer. Bump generation and yield a `nil` wake-up so any
        // lingering consumer can observe cancellation/mismatch and exit.
        notificationsTaskGeneration &+= 1
        peerConnectionNotificationsContinuation.yield(nil)
        notificationsTask?.cancel()
        notificationsTask = nil
        notificationsConsumerIsRunning = false

        // Recreate the notifications stream so subsequent calls start with a fresh pipeline.
        // This is critical for sequential-call reliability when the previous stream has
        // terminated (observed via consumer immediately exiting on call #2).
        resetPeerConnectionNotificationsStream()

        // Prefer idempotent teardown: `shutdown(with:)` can be invoked multiple times from
        // different end-call triggers (e.g. signaling end_call + CallKit). The rest of
        // `shutdown(with:)` still performs a full reset.
        await finishEndConnection(currentCall: call, force: false)

        // Close any remaining peer connections and notify delegates.
        // (Normally `finishEndConnection` already removed them, but keep this as a safety net.)
        let remainingConnections = await connectionManager.findAllConnections()
        for connection in remainingConnections {
            await connection.delegateWrapper.delegate?.shutdown()
    #if os(Android)
            // Android cleanup is centralized on the shared AndroidRTCClient.
    #else
            connection.peerConnection.delegate = nil
            connection.peerConnection.close()
    #endif
        }

    #if os(Android)
        self.rtcClient.close()
        logger.log(level: .info, message: "Did close AndroidRTCClient during shutdown")
    #endif

    #if os(iOS)
        // Disable WebRTC audio playout/recording and deactivate AVAudioSession so the next call starts clean.
        setAudio(false)
        do {
            try deactivateAudioSession(session: AVAudioSession.sharedInstance())
        } catch {
            logger.log(level: .warning, message: "⚠️ Failed to deactivate AVAudioSession during shutdown: \(error.localizedDescription)")
        }
    #endif

        // Clear any session-level pending buffers/caches.
        iceDeque.removeAll()
    #if !os(Android)
        pendingRemoteVideoRenderersByConnectionId.removeAll()
    #endif

        // Shutdown ratchet manager and clear all crypto/key state so the
        // next call starts from a clean slate (no pending ciphertext/keys).
        try? await ratchetManager.shutdown()
        await keyManager.clearAll()

        await connectionManager.removeAllConnections()

    #if os(Android)
        didStartReceiving = false
        remoteViewData.removeAll()
    #endif

    #if DEBUG
        let remainingConnectionCount = await connectionManager.findAllConnections().count
        assert(remainingConnectionCount == 0, "RTCSession shutdown should leave zero connections (found: \(remainingConnectionCount))")
        assert(inboundCandidateConsumers.isEmpty, "RTCSession shutdown should clear inbound candidate buffers")
        assert(pcStateByConnectionId.isEmpty, "RTCSession shutdown should clear per-connection pcState")
        assert(pcState == .none, "RTCSession shutdown should reset pcState to .none")
    #endif
    }
    
    /// Adds audio to a stream with proper error handling
    /// - Parameter connection: The connection to add audio to
    /// - Returns: Updated connection with audio track
    /// - Throws: AudioError if audio addition fails
    func addAudioToStream(with connection: RTCConnection) async throws -> RTCConnection {
        logger.log(level: .info, message: "Adding audio to stream for connection: \(connection.id)")
        
        do {
#if !os(Android)
            // Create audio track
            let audioTrack = try self.createAudioTrack(with: connection)
            
            // Add audio track to peer connection and capture the returned sender
            let id = "streamId_\(connection.id)"
            let maybeAudioSender = connection.peerConnection.add(audioTrack, streamIds: [id])
            
            // CRITICAL: Create sender FrameCryptor using the returned sender
            // This ensures frames are encrypted from the start, without relying on async sender discovery
            if let audioSender = maybeAudioSender, connection.audioSenderCryptor == nil {
                do {
                    try await self.createEncryptedFrame(connection: connection, kind: .audioSender(audioSender))
                } catch {
                    logger.log(level: .warning, message: "⚠️ Failed to create audio sender FrameCryptor immediately - will retry in addedStream: \(error)")
                }
            } else if maybeAudioSender == nil {
                logger.log(level: .warning, message: "⚠️ Failed to obtain audio sender from peerConnection.add - will rely on addedStream fallback")
            }
#elseif os(Android)
            // Create audio track
            let audioTrack = try await self.createAudioTrack(with: connection)
            // Use NeedleTailRTC's prepareAudioSendRecv method to handle audio track addition
            try await self.rtcClient.prepareAudioSendRecv(id: connection.id)
#endif
            
            logger.log(level: .info, message: "Successfully added audio to stream for connection: \(connection.id)")
            return connection
            
        } catch let error as AudioError {
            logger.log(level: .error, message: "Failed to add audio to stream: \(error.localizedDescription)")
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error adding audio to stream: \(error)")
            throw AudioError.audioTrackCreationFailed("Failed to add audio to stream: \(error.localizedDescription)")
        }
    }
    
    /// Adds video to a stream with proper error handling
    /// - Parameter connection: The connection to add video to
    /// - Returns: Updated connection with video track
    /// - Throws: RTCErrors if video addition fails
    public func addVideoToStream(with connection: RTCConnection) async throws -> RTCConnection {
        logger.log(level: .info, message: "Adding video to stream for connection: \(connection.id)")
        
        do {
            var updatedConnection = connection
            
#if !os(Android)
            // Create local video track for Apple platforms
            let (videoTrack, returnedConnection) = try await self.createLocalVideoTrack(with: connection)
            // Use the returned updated connection so we keep rtcVideoCaptureWrapper
            updatedConnection = returnedConnection
            updatedConnection.localVideoTrack = videoTrack.track
            let id = "streamId_\(connection.id)"
            // Add video track to peer connection and capture the returned sender
            let maybeVideoSender = updatedConnection.peerConnection.add(videoTrack.track, streamIds: [id])
            
            // CRITICAL: Create sender FrameCryptor using the returned sender
            // This ensures frames are encrypted from the start, without relying on async sender discovery
            if let videoSender = maybeVideoSender, updatedConnection.videoSenderCryptor == nil {
                do {
                    try await self.createEncryptedFrame(connection: updatedConnection, kind: .videoSender(videoSender))
                } catch {
                    logger.log(level: .warning, message: "⚠️ Failed to create sender FrameCryptor immediately - will retry in addedStream: \(error)")
                }
            } else if maybeVideoSender == nil {
                logger.log(level: .warning, message: "⚠️ Failed to obtain video sender from peerConnection.add - will rely on addedStream fallback")
            }
#else
            // Android: Let prepareVideoSendRecv handle complete setup (track creation + peer connection)
            updatedConnection.localVideoTrack = try self.rtcClient.prepareVideoSendRecv(id: connection.id)
#endif
            
            // Update connection in manager
            let manager = connectionManager as RTCConnectionManager
            await manager.updateConnection(id: connection.id, with: updatedConnection)
            
            logger.log(level: .info, message: "Successfully added video to stream for connection: \(connection.id)")
            return updatedConnection
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "Failed to add video to stream: \(error.localizedDescription)")
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error adding video to stream: \(error)")
            throw RTCErrors.mediaError("Failed to add video to stream: \(error.localizedDescription)")
        }
    }
    
    /// Ensures the peer-connection notifications task is running.
    ///
    /// The session consumes an internal notification stream (emitted by platform delegates) to
    /// coordinate negotiation, media events, and crypto lifecycle changes.
    func handleNotificationsStream() {
        // Start a new task if one doesn't exist, is cancelled, or we previously observed that the
        // consumer isn't actually running.
        let needsRestart = notificationsTask == nil
            || notificationsTask?.isCancelled == true
            || notificationsConsumerIsRunning == false

        guard needsRestart else { return }

        if notificationsTask != nil {
            logger.log(level: .info, message: "Restarting peer-notifications consumer task")
            // Wake any existing consumer so it can observe cancellation/generation mismatch.
            peerConnectionNotificationsContinuation.yield(nil)
            notificationsTask?.cancel()
        }

        notificationsTaskGeneration &+= 1
        let generation = notificationsTaskGeneration
        logger.log(level: .info, message: "Starting peer-notifications consumer task (generation=\(generation))")

        // Use a detached task so this long-lived consumer does not inherit cancellation from
        // whatever call/setup task happened to create it.
        notificationsTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.handlePeerConnectionNotifications(generation: generation)
            // Always clear the task reference when the consumer exits (usually due to
            // cancellation during teardown). Do not use a nested Task here because it can
            // inherit cancellation and fail to run, leaving a completed 'zombie' task.
            await self.notificationsTaskDidFinish(generation: generation)
        }
    }

    private func notificationsTaskDidFinish(generation: UInt64) {
        // Only clear if this is still the latest task.
        guard generation == notificationsTaskGeneration else { return }
        notificationsTask = nil
        notificationsConsumerIsRunning = false
    }
    
    /// Creates a state stream for a call.
    ///
    /// This initializes the call state machine stream(s) and starts the background task that reacts
    /// to state changes.
    /// - Parameters:
    ///   - call: The call to create a state stream for
    ///   - recipientName: The name/identifier of the recipient (used for SessionIdentity)
    public func createStateStream(
        with call: Call,
        recipientName: String? = nil
    ) async throws {
        // Treat this call's connection id as the active one.
        // This prevents late callbacks from a previous call from affecting the new call.
        activeConnectionId = call.sharedCommunicationId
        await callState.createStreams(with: call)
        handleStateStream()
    }
    
    private func handleStateStream() {
        if stateTask?.isCancelled == false { stateTask?.cancel() }
        stateTask = Task { [weak self] in
            guard let self else { return }
            guard let stateStream = await self.callState.currentCallStream.first else { return }
            try await handleState(stateStream: stateStream)
        }
    }
    
    /// Transitions the call state machine to `.connecting` if the session is currently `.ready`.
    ///
    /// This is a convenience guard to avoid invalid transitions when call setup is triggered from
    /// multiple asynchronous entry points.
    ///
    /// - Parameters:
    ///   - call: The call being connected.
    ///   - callDirection: The direction of the call (incoming/outgoing).
    public func setConnectingIfReady(
        call: Call,
        callDirection: CallStateMachine.CallDirection) async {
            switch await callState.currentState {
            case .ready:
                await self.callState.transition(
                    to: .connecting(
                        callDirection,
                        call
                    )
                )
            default:
                break
            }
        }
    
    /// Safely ends a connection with proper cleanup and error handling
    /// - Parameter currentCall: The call to end
    public func finishEndConnection(currentCall: Call?) async {
        await finishEndConnection(currentCall: currentCall, force: false)
    }

    /// Safely ends a connection with proper cleanup and error handling.
    ///
    /// - Parameters:
    ///   - currentCall: The call to end.
    ///   - force: If `true`, performs cleanup even if the session has already recorded teardown
    ///     for this call key. This is used by `shutdown(with:)` to guarantee a full reset.
    public func finishEndConnection(currentCall: Call?, force: Bool) async {
        let callKey = currentCall.map { teardownKey(for: $0) }
        let connectionIdKey = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines)

        if !force {
            if let connectionIdKey, !connectionIdKey.isEmpty {
                if !beginEnding(connectionId: connectionIdKey) {
                    logger.log(level: .debug, message: "Skipping duplicate finishEndConnection for connectionId: \(connectionIdKey)")
                    return
                }
            } else if let callKey {
                if !beginEnding(callKey: callKey) {
                    logger.log(level: .debug, message: "Skipping duplicate finishEndConnection for callKey: \(callKey)")
                    return
                }
            }
        }

        defer {
            if let connectionIdKey, !connectionIdKey.isEmpty {
                endEnding(connectionId: connectionIdKey)
            }
            if let callKey {
                endEnding(callKey: callKey)
            }
        }

        logger.log(level: .info, message: "Finishing connection for call: \(String(describing: currentCall?.id))")

        // If we're ending the currently active call, clear the active connection marker.
        if let currentCall {
            if activeConnectionId == currentCall.sharedCommunicationId {
                activeConnectionId = nil
            }
        } else {
            activeConnectionId = nil
        }
        
        let connectionId = currentCall?.sharedCommunicationId

        if let connectionId {
            pendingRemoteVideoRenderersByConnectionId.removeValue(forKey: connectionId)
        }
        
        // Clean up video and crypto resources before closing connection
        if let connectionId,
           var connection = await connectionManager.findConnection(with: connectionId) {
#if canImport(WebRTC)
            // Disable video tracks first to stop capture/rendering
            if connection.localVideoTrack != nil {
                await setVideoTrack(isEnabled: false, connectionId: connectionId)
                logger.log(level: .debug, message: "Disabled local video track for connection: \(connectionId)")
            }
            
            // Clean up video capture wrapper - this stops the capture
            if connection.rtcVideoCaptureWrapper != nil {
                connection.rtcVideoCaptureWrapper = nil
                logger.log(level: .debug, message: "Cleaned up video capture wrapper for connection: \(connectionId)")
            }
            
            // Disable and release FrameCryptor instances for this connection
            connection.videoFrameCryptor?.enabled = false
            connection.videoFrameCryptor?.delegate = nil
            connection.videoSenderCryptor?.enabled = false
            connection.videoSenderCryptor?.delegate = nil
            connection.audioFrameCryptor?.enabled = false
            connection.audioFrameCryptor?.delegate = nil
            connection.audioSenderCryptor?.enabled = false
            connection.audioSenderCryptor?.delegate = nil
            
            connection.videoFrameCryptor = nil
            connection.videoSenderCryptor = nil
            connection.audioFrameCryptor = nil
            connection.audioSenderCryptor = nil
            
            // Clear video track references
            connection.localVideoTrack = nil
            connection.remoteVideoTrack = nil
            
            await connectionManager.updateConnection(id: connectionId, with: connection)
            logger.log(level: .debug, message: "Cleaned up video and crypto resources for connection: \(connectionId)")
#elseif os(Android)
            // Android cleanup is handled in rtcClient.close(), but ensure video is disabled
            await setVideoTrack(isEnabled: false, connectionId: connectionId)
#endif
        }

        // Remove per-connection identity and any pending ciphertext so the next call
        // starts with a fresh crypto state. This is platform independent.
        if let connectionId {
            await keyManager.removeConnectionIdentity(connectionId: connectionId)
        }
        
        func cleanup(connection: RTCConnection) async {
#if os(Android)
            self.rtcClient.close()
            logger.log(level: .info, message: "Did close AndroidRTCClient for call: \(connection)")
#else
            connection.peerConnection.delegate = nil
            connection.peerConnection.close()
#endif
        }

        // Close peer connection(s).
        //
        // Important: do NOT close an arbitrary "last connection" when the call-specific connection
        // can't be found. Late callbacks from a previous call can arrive after a new call has
        // already created its peer connection; closing the wrong connection breaks subsequent calls.
        if let currentCall {
            if let connection = await connectionManager.findConnection(with: currentCall.sharedCommunicationId) {
                await cleanup(connection: connection)
                logger.log(level: .debug, message: "Closed peer connection for call: \(currentCall.id)")
            } else {
                let activeIds = await connectionManager.findAllConnections().map { $0.id }
                logger.log(
                    level: .warning,
                    message: "No peer connection found to close for call: \(String(describing: currentCall.id)); activeConnections=\(activeIds)"
                )
            }
        } else {
            let remainingConnections = await connectionManager.findAllConnections()
            for connection in remainingConnections {
                await cleanup(connection: connection)
                // Remove per-connection identity so the next call starts clean.
                await keyManager.removeConnectionIdentity(connectionId: connection.id)
            }

            // Remove all connections from the manager so subsequent calls don't accidentally
            // reference stale connections.
            await connectionManager.removeAllConnections()

            // Clear any buffered renderer requests since they are scoped to old connections.
#if !os(Android)
            pendingRemoteVideoRenderersByConnectionId.removeAll()
#endif

            if !remainingConnections.isEmpty {
                logger.log(level: .debug, message: "Closed \(remainingConnections.count) peer connection(s) (no call provided)")
            }
        }
        
        if let currentCall {
            // Remove connection from manager
            await connectionManager.removeConnection(with: currentCall.sharedCommunicationId)
        }
        
        // Reset call state
        await self.callState.resetState()

        // Reset inbound call answer gating
        resetCallAnswerGating()
        
        // Reset connection state
        pcState = PeerConnectionState.none
        pcStateByConnectionId.removeAll()
        readyForCandidates = false

        // Clear any queued outbound candidates.
        iceDeque.removeAll()
        
        // Clean up candidate buffers
        for (_, consumer) in inboundCandidateConsumers {
            await consumer.removeAll()
        }
        inboundCandidateConsumers.removeAll()
        
        // Reset counters and flags
        notRunning = true
        lastId = 0
        iceId = 0
        
        logger.log(level: .info, message: "Successfully finished connection for call: \(String(describing: currentCall?.id))")
    }
    
    /// Returns `true` if the connection manager currently contains a connection with `id`.
    public func hasConnection(id: String) async -> Bool {
        await connectionManager.findConnection(with: id) != nil
    }
}
