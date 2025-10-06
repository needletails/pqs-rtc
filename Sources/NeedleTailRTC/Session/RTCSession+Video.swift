//
//  RTCSession+Video.swift
//  needle-tail-rtc
//
//  Created by Cole M on 9/11/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
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
    @MainActor
    func renderLocalVideo(to view: AndroidPreviewCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Rendering local video for connection: \(connectionId)")
        let client: RTCClient = Self.rtcClient
        if let localTrack = client.getLocalVideoTrack() {
            view.attach(localTrack)
        }
    }
    
    /// Render remote video to Android view (equivalent to iOS RTCVideoRenderWrapper)
    @MainActor
    func renderRemoteVideo(to view: AndroidSampleCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Rendering remote video for connection: \(connectionId)")
        let client: RTCClient = Self.rtcClient
        if let remoteTrack = client.observable.remoteVideoTrack {
            view.attach(remoteTrack)
        }
    }
    
    /// Remove remote video renderer
    @MainActor
    func removeRemote(view: AndroidSampleCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Removing remote video renderer for connection: \(connectionId)")
        let client: RTCClient = Self.rtcClient
        if let remoteTrack = client.observable.remoteVideoTrack {
            view.detach(remoteTrack)
        }
    }
    
    /// Remove local video renderer
    @MainActor
    func removeLocal(view: AndroidPreviewCaptureView, connectionId: String) async {
        logger.log(level: .info, message: "Removing local video renderer for connection: \(connectionId)")
        let client: RTCClient = Self.rtcClient
        if let localTrack = client.getLocalVideoTrack() {
            view.detach(localTrack)
        }
    }
#else
    func renderLocalVideo(to renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
        connection.localVideoTrack?.add(renderer)
    }
    func renderRemoteVideo(to renderer: RTCVideoRenderWrapper, with connectionId: String) async {
        let manager = connectionManager as RTCConnectionManager
        guard var connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
        connection.remoteVideoTrack = connection.peerConnection.transceivers.first { $0.mediaType == .video }?.receiver.track as? WebRTC.RTCVideoTrack
        connection.remoteVideoTrack?.add(renderer)
        await manager.updateConnection(id: connectionId, with: connection)
    }
    func removeRemote(renderer: RTCVideoRenderWrapper, connectionId: String) async {
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
        connection.remoteVideoTrack?.remove(renderer)
    }
    
    func removeLocal(renderer: RTCVideoRenderWrapper, connectionId: String) async {
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
        let videoSource = Self.rtcClient.createVideoSource()
        let videoTrack = Self.rtcClient.createVideoTrack(id: connection.id, videoSource)
        
        // Update connection in manager
        let manager = connectionManager as RTCConnectionManager
        await manager.updateConnection(id: connection.id, with: updatedConnection)
        
        logger.log(level: .info, message: "Successfully created local video track for connection: \(connection.id)")
        return (.init(track: videoTrack), updatedConnection)
#elseif canImport(WebRTC)
        // Create video source
        let videoSource = RTCSession.factory.videoSource()
        // Create video track
        let videoTrack = RTCSession.factory.videoTrack(with: videoSource, trackId: "video0")
        // iOS-specific video capture wrapper
        updatedConnection.rtcVideoCaptureWrapper = RTCVideoCaptureWrapper(delegate: videoSource)
        
        // Update connection in manager
        let manager = connectionManager as RTCConnectionManager
        await manager.updateConnection(id: connection.id, with: updatedConnection)
        
        logger.log(level: .info, message: "Successfully created local video track for connection: \(connection.id)")
        return (.init(track: videoTrack), updatedConnection)
#else
        fatalError("Must Be Running on iOS, macOS or Android")
#endif
    }
    
    func setVideoTrack(isEnabled: Bool, connectionId: String) async {
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else { return }
#if !os(Android)
        await setTrackEnabled(WebRTC.RTCVideoTrack.self, isEnabled: isEnabled, with: connection)
#elseif os(Android)
        Self.rtcClient.setVideoEnabled(isEnabled)
#endif
    }
}
