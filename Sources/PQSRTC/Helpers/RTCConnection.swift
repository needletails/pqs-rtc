//
//  RTCConnection.swift
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

#if !os(Android)
@preconcurrency import WebRTC
#endif
import NeedleTailLogger
import Foundation
import DoubleRatchetKit
import NTKLoop
#if canImport(FoundationEssentials)
import FoundationEssentials
#endif

/// Cipher negotiation lifecycle for frame-level encryption.
///
/// This is a small internal state machine used while establishing per-connection frame
/// encryption parameters (e.g., setting sender/receiver keys) before media can be decrypted.
/* SKIP @bridge */ public enum CipherNegotiationState: Sendable {
    /// Initial state; key negotiation has not started.
    case waiting
    /// Local sender key has been set/announced.
    case setSenderKey
    /// Remote recipient key has been received and set.
    case setRecipientKey
    /// Key negotiation is complete and media can be processed.
    case complete
}

/// A single WebRTC PeerConnection plus associated routing, identity, and crypto state.
///
/// `RTCSession` stores one `RTCConnection` per active peer (1:1) or per SFU endpoint
/// (group calls), and uses it to manage tracks, data channels, and frame cryptors.
/* SKIP @bridge */ public struct RTCConnection: TaskObjectProtocol {
    // Shared properties for both platforms
    /// Stable identifier for this connection (used for routing/correlation).
    public let id: String
    let delegateWrapper: RTCPeerConnectionDelegateWrapper
    let sender: String
    let recipient: String
    let localKeys: LocalKeys
    let symmetricKey: SymmetricKey
    var sessionIdentity: SessionIdentity
    var call: Call
    let logger = NeedleTailLogger()

    /// Semantic alias: the local participant identity for this connection.
    ///
    /// Note: Historically this SDK stored the local id in `sender`.
    public var localParticipantId: String { sender }

    /// Semantic alias: the remote participant identity for this connection.
    ///
    /// Note: Historically this SDK stored the remote id in `recipient`.
    public var remoteParticipantId: String { recipient }
    
    /// Current cipher negotiation state for this connection.
    private(set) var cipherNegotiationState: CipherNegotiationState = .waiting
    
#if os(Android)
#else
    var videoFrameCryptor: RTCFrameCryptor?
    var videoSenderCryptor: RTCFrameCryptor?
    var audioFrameCryptor: RTCFrameCryptor?
    var audioSenderCryptor: RTCFrameCryptor?
#endif
    
    
    
    /// Transitions the cipher negotiation state, emitting a log.
    ///
    /// The transition is ignored if the state is already `nextState`.
    mutating func transition(to nextState: CipherNegotiationState) {
        if cipherNegotiationState == nextState {
            logger.log(level: .info, message: "State transition skipped - already in state: \(nextState)")
            return
        }
        cipherNegotiationState = nextState
        logger.log(level: .info, message: "State transition to state: \(nextState)")
    }
    
    // Platform-specific properties
#if os(Android)
    public let peerConnection: RTCPeerConnection
    public var localVideoTrack: RTCVideoTrack?
    public var localScreenTrack: RTCVideoTrack?
    public var remoteVideoTrack: RTCVideoTrack?
    public var remoteScreenTrack: RTCVideoTrack?

    /// Group-call support (SFU / conference): multiple remote participants on a single PeerConnection.
    public var remoteVideoTracksByParticipantId: [String: RTCVideoTrack] = [:]
    /// Screen share tracks received from remote participants, keyed by participant ID.
    public var remoteScreenTracksByParticipantId: [String: RTCVideoTrack] = [:]
#elseif canImport(WebRTC)
    public let peerConnection: WebRTC.RTCPeerConnection
    internal var rtcVideoCaptureWrapper: RTCVideoCaptureWrapper?
    internal var screenCaptureWrapper: RTCVideoCaptureWrapper?
    public var localVideoTrack: WebRTC.RTCVideoTrack?
    public var localScreenTrack: WebRTC.RTCVideoTrack?
    /// Local mic publish track (Apple). Stored so mute can target the same object WebRTC captures from when `RTCRtpSender.track` is nil or swapped during negotiation.
    public var localAudioTrack: WebRTC.RTCAudioTrack?
    public var remoteVideoTrack: WebRTC.RTCVideoTrack?
    /// Extra sinks (e.g. PiP) attached via ``RTCSession/addAuxiliaryRemoteVideoRenderer``; kept on the connection so SFU renegotiation can move them to a replaced inbound track.
    var auxiliaryRemoteVideoRenderers: [RTCVideoRenderWrapper] = []
    var dataChannels: [String: RTCDataChannel] = [:]

    /// Group-call support (SFU / conference): multiple remote participants can be received on a single PeerConnection.
    ///
    /// The SDK maps stable sender `participantId` -> track/cryptor. Apple receivers can appear first
    /// under UUID-like SFU placeholders, so `RTCSession` later reconciles these maps from SDP `msid`
    /// lines before binding receiver FrameCryptors.
    public var remoteVideoTracksByParticipantId: [String: WebRTC.RTCVideoTrack] = [:]
    public var remoteAudioTracksByParticipantId: [String: WebRTC.RTCAudioTrack] = [:]
    /// Screen share tracks received from remote participants, keyed by participant ID.
    public var remoteScreenTracksByParticipantId: [String: WebRTC.RTCVideoTrack] = [:]
    var videoReceiverCryptorsByParticipantId: [String: RTCFrameCryptor] = [:]
    var audioReceiverCryptorsByParticipantId: [String: RTCFrameCryptor] = [:]
    var videoReceiverCryptorBindingsByParticipantId: [String: RTCReceiverCryptorBinding] = [:]
    var audioReceiverCryptorBindingsByParticipantId: [String: RTCReceiverCryptorBinding] = [:]
    var screenSenderCryptor: RTCFrameCryptor?
    var screenReceiverCryptorsByParticipantId: [String: RTCFrameCryptor] = [:]
    var screenReceiverCryptorBindingsByParticipantId: [String: RTCReceiverCryptorBinding] = [:]
#endif
    
#if os(Android)
    internal init(
        id: String,
        peerConnection: RTCPeerConnection,
        delegateWrapper: RTCPeerConnectionDelegateWrapper,
        localVideoTrack: RTCVideoTrack? = nil,
        remoteVideoTrack: RTCVideoTrack? = nil,
        sender: String,
        recipient: String,
        localKeys: LocalKeys,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity,
        call: Call
    ) {
        // Shared initialization
        self.id = id
        self.peerConnection = peerConnection
        self.delegateWrapper = delegateWrapper
        self.localVideoTrack = localVideoTrack
        self.remoteVideoTrack = remoteVideoTrack
        self.sender = sender
        self.recipient = recipient
        self.localKeys = localKeys
        self.symmetricKey = symmetricKey
        self.sessionIdentity = sessionIdentity
        self.call = call
    }
#else
    internal init(
        id: String,
        peerConnection: WebRTC.RTCPeerConnection,
        delegateWrapper: RTCPeerConnectionDelegateWrapper,
        localVideoTrack: WebRTC.RTCVideoTrack? = nil,
        localAudioTrack: WebRTC.RTCAudioTrack? = nil,
        remoteVideoTrack: WebRTC.RTCVideoTrack? = nil,
        rtcVideoCaptureWrapper: RTCVideoCaptureWrapper? = nil,
        sender: String,
        recipient: String,
        localKeys: LocalKeys,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity,
        call: Call
    ) {
        // Shared initialization
        self.id = id
        self.peerConnection = peerConnection
        self.delegateWrapper = delegateWrapper
        self.localVideoTrack = localVideoTrack
        self.localAudioTrack = localAudioTrack
        self.remoteVideoTrack = remoteVideoTrack
        self.sender = sender
        self.recipient = recipient
        self.localKeys = localKeys
        self.symmetricKey = symmetricKey
        self.sessionIdentity = sessionIdentity
        self.call = call
        // iOS-specific initialization
        self.rtcVideoCaptureWrapper = rtcVideoCaptureWrapper
    }
#endif
}

/// Stores and updates active `RTCConnection` instances.
///
/// This actor is used to ensure connection mutations are serialized and safe across
/// concurrent tasks (negotiation, ICE callbacks, UI, etc.).
actor RTCConnectionManager {
    
    private var connections = [RTCConnection]()
    let logger: NeedleTailLogger
    
    init(logger: NeedleTailLogger = NeedleTailLogger("[RTCConnectionManager]")) {
        self.logger = logger
        logger.log(level: .debug, message: "RTCConnectionManager initialized")
    }

    /// Group / SFU connections keep `Call.sharedCommunicationId` as stored `RTCConnection.id`, often with a `#` prefix.
    /// Many APIs (mute, render helpers) pass ``String/normalizedConnectionId`` without `#`. Match both forms.
    /// Case-insensitive: conference room IDs can arrive in varying case from different code paths.
    private func normalizedLookupKey(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId.lowercased()
    }

    private func indexOfConnection(matchingLookupId lookupId: String) -> Int? {
        let key = normalizedLookupKey(lookupId)
        return connections.firstIndex {
            normalizedLookupKey($0.id) == key
        }
    }
    
    func addConnection(_ connection: RTCConnection) {
        if let index = indexOfConnection(matchingLookupId: connection.id) {
            let previous = connections[index].id
            logger.log(level: .warning, message: "Replacing existing connection id=\(previous) (new id=\(connection.id), same normalized key)")
            connections.remove(at: index)
        }
        connections.append(connection)
    }
    
    func updateConnection(id: String, with connection: RTCConnection) {
        if let index = indexOfConnection(matchingLookupId: id) {
            connections[index] = connection
            logger.log(level: .info, message: "Updated connection with id \(connection.id)")
        } else {
            logger.log(level: .warning, message: "updateConnection: no match for lookup id=\(id) (normalized=\(normalizedLookupKey(id)))")
        }
    }
    
    func findConnection(with id: String) -> RTCConnection? {
        guard let index = indexOfConnection(matchingLookupId: id) else { return nil }
        return connections[index]
    }
    
    func findAllConnections() -> [RTCConnection] {
        connections
    }
    
    func removeConnection(with id: String) {
        guard let index = indexOfConnection(matchingLookupId: id) else { return }
        connections.remove(at: index)
    }
    
    func removeAllConnections() {
        connections.removeAll()
    }
    
#if os(Android)
    // Unified method for finding connection ID by peer connection
    func findConnectionId(for peerConnection: AndroidRTCClient) -> String? {
        connections.first(where: { $0.peerConnection === peerConnection })?.id
    }
#else
    // Unified method for finding connection ID by peer connection
    func findConnectionId(for peerConnection: RTCPeerConnection) -> String? {
        connections.first(where: { $0.peerConnection === peerConnection })?.id
    }
#endif
}


/// Holds the platform-specific PeerConnection delegate.
///
/// This wrapper allows `RTCConnection` to store a single value while compiling different
/// delegate implementations per platform.
struct RTCPeerConnectionDelegateWrapper: Sendable {
    
#if os(Android)
    var delegate: AndroidPeerConnectionDelegate?
#elseif canImport(WebRTC)
    var delegate: ApplePeerConnectionDelegate?
#endif
    
#if canImport(WebRTC)
    init(
        connectionId: String,
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        delegate = ApplePeerConnectionDelegate(
            connectionId: connectionId,
            logger: logger,
            continuation: continuation)
    }
#endif
    
#if os(Android)
    init(
        connectionId: String,
        logger: NeedleTailLogger,
        continuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    ) {
        delegate = AndroidPeerConnectionDelegate(
            connectionId: connectionId,
            logger: logger,
            continuation: continuation)
    }
#endif
}

#if canImport(WebRTC) && !os(Android)
/// Stable metadata for an Apple receiver FrameCryptor binding.
///
/// `RTCFrameCryptor` itself owns the native receiver attachment. We keep this
/// lightweight value so rebinding is idempotent across renegotiation and so a
/// stale cryptor is disabled before a new participant id or receiver binding is
/// attached to the same media track.
struct RTCReceiverCryptorBinding: Sendable, Equatable {
    let participantId: String
    let trackId: String
    let receiverId: String
}
#endif
