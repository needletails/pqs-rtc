//
//  RTCConnectionManager.swift
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
#if !os(Android)
@preconcurrency import WebRTC
#endif
import NeedleTailLogger

/// A structure representing an RTC connection with all associated components
public struct RTCConnection: @unchecked Sendable {
    // Shared properties for both platforms
    public let id: String
    public let delegateWrapper: RTCPeerConnectionDelegateWrapper
    
    // Platform-specific properties
#if os(Android)
    public let peerConnection: RTCClient
    public var localVideoTrack: RTCVideoTrack?
    public var remoteVideoTrack: RTCVideoTrack?
#else
    public let peerConnection: WebRTC.RTCPeerConnection
    internal var rtcVideoCaptureWrapper: RTCVideoCaptureWrapper?
    public var localVideoTrack: WebRTC.RTCVideoTrack?
    public var remoteVideoTrack: WebRTC.RTCVideoTrack?
#endif
    
#if os(Android)
    internal init(
        id: String,
        peerConnection: RTCClient,
        delegateWrapper: RTCPeerConnectionDelegateWrapper,
        localVideoTrack: RTCVideoTrack? = nil,
        remoteVideoTrack: RTCVideoTrack? = nil
    ) {
        // Shared initialization
        self.id = id
        self.peerConnection = peerConnection
        self.delegateWrapper = delegateWrapper
        self.localVideoTrack = localVideoTrack
        self.remoteVideoTrack = remoteVideoTrack
    }
#else
    internal init(
        id: String,
        peerConnection: WebRTC.RTCPeerConnection,
        delegateWrapper: RTCPeerConnectionDelegateWrapper,
        localVideoTrack: WebRTC.RTCVideoTrack? = nil,
        remoteVideoTrack: WebRTC.RTCVideoTrack? = nil,
        rtcVideoCaptureWrapper: RTCVideoCaptureWrapper? = nil
    ) {
        // Shared initialization
        self.id = id
        self.peerConnection = peerConnection
        self.delegateWrapper = delegateWrapper
        self.localVideoTrack = localVideoTrack
        self.remoteVideoTrack = remoteVideoTrack
        
        // iOS-specific initialization
        self.rtcVideoCaptureWrapper = rtcVideoCaptureWrapper
    }
#endif
}

/// Manages RTC connections with proper error handling and logging
actor RTCConnectionManager {
    
    private var connections = [RTCConnection]()
    let logger: NeedleTailLogger
    
    init(logger: NeedleTailLogger = NeedleTailLogger("[RTCConnectionManager]")) {
        self.logger = logger
        logger.log(level: .debug, message: "RTCConnectionManager initialized")
    }
    
    func addConnection(_ connection: RTCConnection) {
        if connections.contains(where: { $0.id == connection.id }) {
            logger.log(level: .warning, message: "Replacing existing connection with id: \(connection.id)")
            connections.removeAll(where: { $0.id == connection.id })
        }
        connections.append(connection)
    }
    
    func updateConnection(id: String, with connection: RTCConnection) {
        if let index = connections.firstIndex(where: { $0.id == id }) {
            connections[index] = connection
        }
    }
    
    func findConnection(with id: String) -> RTCConnection? {
        connections.first(where: { $0.id == id })
    }

    func findAllConnections() -> [RTCConnection] {
        connections
    }
    
    func removeConnection(with id: String) {
        connections.removeAll(where: { $0.id == id })
    }
    
    func removeAllConnections() {
        connections.removeAll()
    }

#if os(Android)
    // Unified method for finding connection ID by peer connection
    func findConnectionId(for peerConnection: RTCClient) -> String? {
        connections.first(where: { $0.peerConnection === peerConnection })?.id
    }
#else
    // Unified method for finding connection ID by peer connection
    func findConnectionId(for peerConnection: RTCPeerConnection) -> String? {
        connections.first(where: { $0.peerConnection === peerConnection })?.id
    }
#endif
}


public struct RTCPeerConnectionDelegateWrapper: Sendable {
    
#if os(Android)
    public var delegate: AndroidPeerConnectionDelegate?
#elseif canImport(WebRTC)
    public var delegate: ApplePeerConnectionDelegate?
#endif
    // Public accessor for Skip compatibility
    public func getDelegate() -> Any? {
#if os(Android)
        return delegate
#elseif canImport(WebRTC)
        return delegate
#else
        return nil
#endif
    }
    
    // Public setters for Skip compatibility
    public func setConnectionId(_ id: String) {
#if os(Android)
        delegate?.connectionId = id
#elseif canImport(WebRTC)
        delegate?.connectionId = id
#endif
    }
    
    public func setNotifications(_ notifications: @escaping (@Sendable (PeerConnectionNotifications?) -> Void)) {
#if os(Android)
        delegate?.notifications = notifications
#elseif canImport(WebRTC)
        delegate?.notifications = notifications
#endif
    }
    
    public init(
        connectionId: String = "",
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        
#if os(Android)
        delegate = AndroidPeerConnectionDelegate(
            logger: logger,
            continuation: continuation)
#elseif canImport(WebRTC)
        delegate = ApplePeerConnectionDelegate(
            logger: logger,
            continuation: continuation)
#endif
        
    }
}
