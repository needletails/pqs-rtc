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
        logger.log(level: .info, message: "Rendering local video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let videoTrack: RTCVideoTrack = await manager.findConnection(with: connectionId)?.localVideoTrack else { return }
        logger.log(level: .info, message: "Attaching Local Track to View - Track: \(videoTrack)")
        view.attach(videoTrack)
    }
    
    /// Render remote video to Android view (equivalent to iOS RTCVideoRenderWrapper)
    func renderRemoteVideo(to view: AndroidSampleCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Rendering remote video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        let client: AndroidRTCClient = self.rtcClient
        guard var connection: RTCConnection = await manager.findConnection(with: connectionId) else {
            logger.log(level: .error, message: "No connection found for ID: \(connectionId)")
            return
        }
        
        logger.log(level: .info, message: "Attempting to get remote video track from peer connection")
        connection.remoteVideoTrack = client.getRemoteVideoTrack(peerConnection: connection.peerConnection)
        
        if let videoTrack = connection.remoteVideoTrack {
            logger.log(level: .info, message: "✅ Found remote video track, attaching renderer")
            logger.log(level: .info, message: "📹 Video track - trackId: \(videoTrack.trackId)")
            view.attach(videoTrack)
        } else {
            logger.log(level: .error, message: "Failed to get remote video track from peer connection")
            logger.log(level: .error, message: "Peer connection state: \(connection.peerConnection)")
            logger.log(level: .error, message: "didStartReceiving: \(didStartReceiving)")
            // Don't fatal error, just log and return
            return
        }
        
        await manager.updateConnection(id: connectionId, with: connection)
    }
    
    /// Remove remote video renderer
    func removeRemote(view: AndroidSampleCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Removing remote video renderer for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let remoteTrack: RTCVideoTrack = await manager.findConnection(with: connectionId)?.remoteVideoTrack else { return }
        view.detach(remoteTrack)
    }
    
    /// Remove local video renderer
    func removeLocal(view: AndroidPreviewCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Removing local video renderer for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let localVideoTrack: RTCVideoTrack = await manager.findConnection(with: connectionId)?.localVideoTrack else { return }
        view.detach(localVideoTrack)
    }
#else
    func renderLocalVideo(to renderer: RTCVideoRenderWrapper, connectionId: String) async {
        logger.log(level: .info, message: "Rendering local video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
        connection.localVideoTrack?.add(renderer)
    }
    func renderRemoteVideo(to renderer: RTCVideoRenderWrapper, with connectionId: String) async {
        logger.log(level: .info, message: "Rendering remote video for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard var connection: RTCConnection = await manager.findConnection(with: connectionId) else {
            logger.log(level: .error, message: "Connection not found for: \(connectionId)")
            return
        }
        connection.remoteVideoTrack = connection.peerConnection.transceivers.first { $0.mediaType == .video }?.receiver.track as? WebRTC.RTCVideoTrack
        
        if let videoTrack = connection.remoteVideoTrack {
            logger.log(level: .info, message: "✅ Found remote video track, attaching renderer")
            logger.log(level: .info, message: "📹 Video track details - trackId: \(videoTrack.trackId), enabled: \(videoTrack.isEnabled), readyState: \(videoTrack.readyState.rawValue)")
            
            // Check if the receiver has a track and if it's the same as the video track
            if let videoReceiver = connection.peerConnection.transceivers.first(where: { $0.mediaType == .video })?.receiver {
                logger.log(level: .info, message: "�� Receiver track: \(videoReceiver.track != nil ? "exists" : "nil"), trackId: \(videoReceiver.track?.trackId ?? "nil")")
                logger.log(level: .info, message: "🔍 Video track matches receiver track: \(videoReceiver.track == videoTrack)")
                
                // Check if FrameCryptor is attached to this receiver
                if let frameCryptor = connection.videoFrameCryptor {
                    logger.log(level: .info, message: "🔍 FrameCryptor exists and is attached to receiver")
                    logger.log(level: .info, message: "🔍 FrameCryptor enabled: \(frameCryptor.enabled)")
                } else {
                    logger.log(level: .warning, message: "⚠️ FrameCryptor is nil - frames won't be decrypted!")
                }
            }
            videoTrack.add(renderer)
        } else {
            logger.log(level: .warning, message: "⚠️ Remote video track is nil - transceivers: \(connection.peerConnection.transceivers.count)")
            // Log transceiver details for debugging
            for (index, transceiver) in connection.peerConnection.transceivers.enumerated() {
                logger.log(level: .info, message: "Transceiver \(index): mediaType=\(transceiver.mediaType), receiver.track=\(String(describing: transceiver.receiver.track))")
            }
        }
        await manager.updateConnection(id: connectionId, with: connection)
    }
    func removeRemote(renderer: RTCVideoRenderWrapper, connectionId: String) async {
        logger.log(level: .info, message: "Removing remote video renderer for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
        connection.remoteVideoTrack?.remove(renderer)
    }
    
    func removeLocal(renderer: RTCVideoRenderWrapper, connectionId: String) async {
        logger.log(level: .info, message: "Removing local video renderer for connection: \(connectionId)")
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
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
        let videoTrack = RTCSession.factory.videoTrack(with: videoSource, trackId: "video_\(connection.id)")
        // Apple-specific video capture wrapper
        updatedConnection.rtcVideoCaptureWrapper = RTCVideoCaptureWrapper(delegate: videoSource)
        
        // Update connection in manager
        let manager = connectionManager as RTCConnectionManager
        await manager.updateConnection(id: connection.id, with: updatedConnection)
        
        logger.log(level: .info, message: "Successfully created local video track for connection: \(connection.id)")
        return (.init(track: videoTrack), updatedConnection)
#else
        throw RTCErrors.mediaError("Unsupported platform for local video track creation")
#endif
    }
    
    func setVideoTrack(isEnabled: Bool, connectionId: String) async {
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
#if !os(Android)
        await setTrackEnabled(WebRTC.RTCVideoTrack.self, isEnabled: isEnabled, with: connection)
#elseif os(Android)
        self.rtcClient.setVideoEnabled(isEnabled)
#endif
    }
    
#if !os(Android)
    func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool, with connection: RTCConnection) async {
        connection.peerConnection.transceivers
            .compactMap { $0.sender.track as? T }
            .forEach { $0.isEnabled = isEnabled }
    }
#endif
}
