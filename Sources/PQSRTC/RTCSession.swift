//
//  RTCSession.swift
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
import NTKLoop
import NeedleTailLogger
import DoubleRatchetKit
import DequeModule
import NeedleTailAsyncSequence
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif


/// Answer/acceptance state for an incoming call.
///
/// `RTCSession` uses this to gate whether an inbound offer may proceed.
/// See ``RTCSession/setCanAnswer(_:)``.
public enum CallAnswerState: Sendable {
    case pending
    case answered
    case rejected
}

/// Errors surfaced by `RTCSession` when a call cannot proceed.
public enum ConnectionErrors: Error, Sendable {
    /// The remote party rejected the call.
    case rejected
    /// The call was not answered within the configured timeout.
    case unanswered
    /// An operation referenced a connection/call that does not exist.
    case connectionNotFound

    /// A human-readable description suitable for logging/UX.
    public var errorDescription: String? {
        switch self {
        case .rejected:
            return "Call was rejected"
        case .unanswered:
            return "Call was unanswered"
        case .connectionNotFound:
            return "Connection not found"
        }
    }
}

/// Minimal state used when sequencing peer-connection operations.
public enum PeerConnectionState: Sendable {
    case setRemote, none
}

/// A decoded WebRTC data-channel message, annotated with routing metadata.
///
/// `connectionId` and `channelLabel` let your app correlate messages to the
/// right peer and channel when multiple calls/data channels are active.
public struct RTCDataChannelMessage: Sendable {
    /// Connection identifier associated with the underlying PeerConnection.
    public let connectionId: String
    /// WebRTC data channel label.
    public let channelLabel: String
    /// Raw message payload.
    public let data: Data

    /// Creates a new data-channel message container.
    public init(connectionId: String, channelLabel: String, data: Data) {
        self.connectionId = connectionId
        self.channelLabel = channelLabel
        self.data = data
    }
}

/// Configures how frame-level E2EE keys are applied to the WebRTC key provider.
///
/// - `shared`: One shared media key ring (current behavior). This is simplest but does not
///   model multi-sender SFU calls.
/// - `perParticipant`: Keys are set per `participantId`, enabling SFU/group calls where
///   each sender can have a distinct key.
public enum RTCFrameEncryptionKeyMode: Sendable {
    case shared
    case perParticipant
}

/// Primary entry point for 1:1 and SFU group calls.
///
/// `RTCSession` owns WebRTC state and call lifecycle. Your app provides the networking layer
/// via ``RTCTransportEvents`` and routes inbound signaling/ciphertext back into the session.
///
/// Common usage:
///
/// ```swift
/// let session = RTCSession(
///   iceServers: ["stun:stun.l.google.com:19302"],
///   username: "",
///   password: "",
///   frameEncryptionKeyMode: .perParticipant,
///   delegate: transport
/// )
/// ```
///
/// For SFU group calls, prefer ``RTCSession/createGroupCall(call:sfuRecipientId:)``.
public actor RTCSession {
    
    let executor = RatchetExecutor(queue: .init(label: "testable-executor"))
    
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    
    let loop = NTKLoop()
    let connectionManager = RTCConnectionManager()
    let keyManager = KeyManager()
    /// Shared peer-connection notifications stream.
    ///
    /// This stream is consumed by a long-lived task (`handleNotificationsStream`) and is fed by
    /// platform delegates (Apple/Android peer-connection delegates).
    ///
    /// Important: This stream must remain usable across sequential calls. Some teardown paths or
    /// consumer restarts can lead to a finished stream; therefore we keep the ability to recreate
    /// the stream+continuation pair.
    var peerConnectionNotificationsStream: AsyncStream<PeerConnectionNotifications?>
    var peerConnectionNotificationsContinuation: AsyncStream<PeerConnectionNotifications?>.Continuation
    /// Inbound ICE candidates buffered per connectionId.
    ///
    /// Candidates may arrive before `setRemote` completes. Keeping per-connection buffers
    /// prevents cross-call mixing when multiple calls occur back-to-back.
    var inboundCandidateConsumers: [String: NeedleTailAsyncConsumer<IceCandidate>] = [:]
    let iceServers: [String]
    let username: String
    let password: String
    let logger: NeedleTailLogger
    let ratchetSalt: Data
    let ratchetManager: RatchetKeyStateManager<SHA256>
    var delegate: RTCTransportEvents?
    var mediaDelegate: RTCSessionMediaEvents?

    let frameEncryptionKeyMode: RTCFrameEncryptionKeyMode

#if !os(Android)
    /// Remote renderers requested by the UI before the remote track exists.
    ///
    /// On iOS/macOS, the UI may call `renderRemoteVideo(...)` as soon as the call is marked
    /// connected, but the remote receiver/track may be delivered slightly later via
    /// `peerConnection(_:didAdd:streams:)`. We buffer the renderer request here and attach it
    /// once the remote video track becomes available.
    var pendingRemoteVideoRenderersByConnectionId: [String: RTCVideoRenderWrapper] = [:]
#endif

    public typealias RemoteParticipantIdResolver = @Sendable (_ streamIds: [String], _ trackId: String, _ trackKind: String) -> String?
    var remoteParticipantIdResolver: RemoteParticipantIdResolver?
    /// Sets the transport delegate.
    ///
    /// This is where the session emits outbound signaling/ciphertext via ``RTCTransportEvents``.
    public func setDelegate(_ delegate: RTCTransportEvents) {
        self.delegate = delegate
    }

    /// Sets the media delegate used for group-call/conference style track notifications.
    public func setMediaDelegate(_ delegate: RTCSessionMediaEvents) {
        self.mediaDelegate = delegate
    }

    /// Controls how inbound receiver events map to a `participantId`.
    ///
    /// By default, SFU-style calls use `streamIds.first` as the participant identifier.
    /// If your SFU uses a different convention (e.g., demux IDs or custom stream IDs),
    /// set a resolver here.
    public func setRemoteParticipantIdResolver(_ resolver: @escaping RemoteParticipantIdResolver) {
        self.remoteParticipantIdResolver = resolver
    }

    /// Creates an SFU group call wrapper that drives SFU signaling through `RTCSession`.
    ///
    /// The returned ``RTCGroupCall`` provides a single ingress for decoded SFU signaling,
    /// roster updates, and key distribution.
    public func createGroupCall(call: Call, sfuRecipientId: String) -> RTCGroupCall {
        RTCGroupCall(session: self, call: call, sfuRecipientId: sfuRecipientId)
    }

    /// Handler invoked for inbound WebRTC data-channel messages.
    ///
    /// Set this if you want to receive arbitrary app-level messages (e.g. chat, control signals)
    /// delivered over RTCDataChannel.
    var dataChannelMessageHandler: (@Sendable (RTCDataChannelMessage) async -> Void)?

    /// Sets a handler invoked for inbound WebRTC data-channel messages.
    ///
    /// - Note: The handler runs asynchronously and may be called multiple times concurrently.
    public func setDataChannelMessageHandler(
        _ handler: (@escaping @Sendable (RTCDataChannelMessage) async -> Void)
    ) {
        self.dataChannelMessageHandler = handler
    }

#if canImport(WebRTC)
    var frameCryptorDelegate = FrameCryptorDelegate()
#endif
    /// Acceptance state for the current inbound call.
    ///
    /// `finishCryptoSessionCreation(recipient:ciphertext:call:)` waits up to ~30 seconds for
    /// this to transition away from `.pending`.
    public var callAnswerState: CallAnswerState = .pending
    private var pendingAnswerCallId: UUID?
    private var callAnswerStatesById: [UUID: CallAnswerState] = [:]
    /// High-level call state machine used by the session.
    public var callState = CallStateMachine()

    /// Sets whether the current inbound call may proceed.
    ///
    /// This is a convenience wrapper over setting ``callAnswerState`` and is primarily used
    /// by inbound call flows.
    public func setCanAnswer(_ canAnswer: Bool) {
        let state: CallAnswerState = canAnswer ? .answered : .rejected
        callAnswerState = state
        if let pendingAnswerCallId {
            callAnswerStatesById[pendingAnswerCallId] = state
        }
    }

    /// Sets acceptance state for a specific call.
    ///
    /// Use this if your app may receive multiple inbound calls and you need per-call gating.
    public func setCallAnswerState(_ state: CallAnswerState, for callId: UUID) {
        callAnswerStatesById[callId] = state
        if pendingAnswerCallId == callId {
            callAnswerState = state
        }
    }
    var notRunning = true
    var readyForCandidates = false
    var lastId = 0
    var iceId = 0
    var iceDeque = Deque<IceCandidate>()

    /// The connection id considered "active" for the current call.
    ///
    /// SFU and 1:1 use cases typically have a single active PeerConnection at a time.
    /// We use this to avoid acting on late WebRTC callbacks from a previous call after
    /// a new call has already started.
    var activeConnectionId: String?
    /// Legacy/global peer-connection state (kept for compatibility).
    /// Prefer `pcStateByConnectionId` for correctness across sequential calls.
    var pcState = PeerConnectionState.none
    /// Peer-connection state per connectionId.
    var pcStateByConnectionId: [String: PeerConnectionState] = [:]
    var notificationsTask: Task<Void, Error>?
    var notificationsTaskGeneration: UInt64 = 0
    var notificationsConsumerIsRunning = false
    var stateTask: Task<Void, Error>?
    nonisolated(unsafe) var isAudioActivated = false

    // MARK: - Teardown idempotency
    // `finishEndConnection(currentCall:)` can be triggered from multiple async entry points
    // (e.g. remote end-call message + CallKit end action). Track per-call teardown to avoid
    // double-running cleanup.
    private var finishingCallKeys: Set<String> = []
    private var recentlyEndedCallKeys: [String] = []
    private var endedCallKeys: Set<String> = []

    // Some platforms/layers can represent the same underlying call with different `Call.id` values
    // (e.g. CallKit UUID vs signaling UUID). The PeerConnection lifecycle is keyed by
    // `sharedCommunicationId`, so also track idempotency by connection id to avoid double-teardown.
    private var finishingConnectionIds: Set<String> = []
    private var recentlyEndedConnectionIds: [String] = []
    private var endedConnectionIds: Set<String> = []

    func teardownKey(for call: Call) -> String {
        if let sharedMessageId = call.sharedMessageId?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !sharedMessageId.isEmpty {
            // Prefer sharedMessageId because sharedCommunicationId can be reused across
            // sequential calls, and Call.id can differ between CallKit and RTC layers.
            return "msg:\(sharedMessageId)|comm:\(call.sharedCommunicationId)"
        }
        return "id:\(call.id.uuidString)|comm:\(call.sharedCommunicationId)"
    }

    func beginEnding(connectionId: String) -> Bool {
        let trimmed = connectionId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if endedConnectionIds.contains(trimmed) { return false }
        if finishingConnectionIds.contains(trimmed) { return false }
        finishingConnectionIds.insert(trimmed)
        return true
    }

    func endEnding(connectionId: String) {
        let trimmed = connectionId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finishingConnectionIds.remove(trimmed)
        endedConnectionIds.insert(trimmed)
        recentlyEndedConnectionIds.append(trimmed)
        // Prevent unbounded growth in long-lived sessions.
        let maxRemembered = 32
        if recentlyEndedConnectionIds.count > maxRemembered {
            let overflow = recentlyEndedConnectionIds.count - maxRemembered
            for _ in 0..<overflow {
                if let oldest = recentlyEndedConnectionIds.first {
                    recentlyEndedConnectionIds.removeFirst()
                    endedConnectionIds.remove(oldest)
                }
            }
        }
    }

    func resetTeardownIdempotency() {
        finishingCallKeys.removeAll()
        recentlyEndedCallKeys.removeAll()
        endedCallKeys.removeAll()

        finishingConnectionIds.removeAll()
        recentlyEndedConnectionIds.removeAll()
        endedConnectionIds.removeAll()
    }

    func beginEnding(callKey: String) -> Bool {
        if endedCallKeys.contains(callKey) { return false }
        if finishingCallKeys.contains(callKey) { return false }
        finishingCallKeys.insert(callKey)
        return true
    }

    func endEnding(callKey: String) {
        finishingCallKeys.remove(callKey)
        endedCallKeys.insert(callKey)
        recentlyEndedCallKeys.append(callKey)
        // Prevent unbounded growth in long-lived sessions.
        let maxRemembered = 32
        if recentlyEndedCallKeys.count > maxRemembered {
            let overflow = recentlyEndedCallKeys.count - maxRemembered
            for _ in 0..<overflow {
                if let oldest = recentlyEndedCallKeys.first {
                    recentlyEndedCallKeys.removeFirst()
                    endedCallKeys.remove(oldest)
                }
            }
        }
    }

    func inboundCandidateConsumer(for connectionId: String) -> NeedleTailAsyncConsumer<IceCandidate> {
        if let existing = inboundCandidateConsumers[connectionId] {
            return existing
        }
        let created = NeedleTailAsyncConsumer<IceCandidate>()
        inboundCandidateConsumers[connectionId] = created
        return created
    }

    /// Resets inbound call acceptance gating.
    ///
    /// Kept as a method so other files/extensions don't need access to the underlying
    /// `private` storage.
    func resetCallAnswerGating() {
        pendingAnswerCallId = nil
        callAnswerState = .pending
        callAnswerStatesById.removeAll()
    }

#if os(Android)
    // Android-only session state used for renderer/candidate ordering.
    // These are currently used for logging/cleanup and may be expanded later.
    var didStartReceiving: Bool = false
    var remoteViewData: [Data] = []
#endif
#if os(Android)
    // SkipRTC AndroidRTCClient for Android platform - use shared singleton
    let rtcClient = AndroidRTCClient()
#elseif canImport(WebRTC)
    let keyProvider: RTCFrameCryptorKeyProvider
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        if let preferredCodec = videoEncoderFactory.supportedCodecs().first(where: { $0.parameters["profile-level-id"] == kRTCMaxSupportedH264ProfileLevelConstrainedBaseline }) {
            videoEncoderFactory.preferredCodec = preferredCodec
        }
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
#endif
    
#if os(iOS)
    nonisolated let audioSession = RTCAudioSession.sharedInstance()
#endif
#if os(macOS)
    var audioPlayer: AVAudioPlayer?
#endif
    
    public init(
        iceServers: [String],
        username: String,
        password: String,
        logger: NeedleTailLogger = NeedleTailLogger("[RTCSession]"),
        ratchetSalt: Data = "PQSRTCFrameEncryptionSalt".data(using: .utf8)!,
        frameEncryptionKeyMode: RTCFrameEncryptionKeyMode = .shared,
        delegate: RTCTransportEvents?
    ) {
        let (notificationStream, notificationContinuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        self.peerConnectionNotificationsStream = notificationStream
        self.peerConnectionNotificationsContinuation = notificationContinuation
        self.iceServers = iceServers
        self.username = username
        self.password = password
        self.logger = logger
        self.ratchetSalt = ratchetSalt
        self.frameEncryptionKeyMode = frameEncryptionKeyMode
        self.delegate = delegate
        self.ratchetManager = RatchetKeyStateManager<SHA256>(executor: executor)
#if canImport(WebRTC)
        self.keyProvider = RTCFrameCryptorKeyProvider(
            ratchetSalt: ratchetSalt,
            ratchetWindowSize: 0,
            sharedKeyMode: frameEncryptionKeyMode == .shared,
            uncryptedMagicBytes: "PQSRTCMagicBytes".data(using: .utf8)!,
            failureTolerance: -1,
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true)
#endif
        logger.log(level: .info, message: "Created RTCSession")
    }

    /// Recreates the peer-connection notifications stream.
    ///
    /// Use this during teardown to ensure subsequent calls start with a fresh, non-terminated
    /// notification pipeline.
    func resetPeerConnectionNotificationsStream() {
        let (notificationStream, notificationContinuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        self.peerConnectionNotificationsStream = notificationStream
        self.peerConnectionNotificationsContinuation = notificationContinuation
    }

    /// Starts a group call by creating a single PeerConnection intended to connect to an SFU.
    ///
    /// Prefer using ``RTCGroupCall/join()`` unless you are building your own group facade.
    ///
    /// - Important: This intentionally skips the 1:1 Double Ratchet handshake.
    ///   For group calls, frame keys must be distributed via the control plane and applied using
    ///   `setFrameEncryptionKey(_:index:for:)` (control-plane injected keys) or via sender-key
    ///   distribution inside ``RTCGroupCall``.
    public func startGroupCall(call: Call, sfuRecipientId: String) async throws -> Call {
        var call = call

        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId

        // Ensure state streams are created so the UI can observe call state.
        try await createStateStream(with: call, recipientName: sfuRecipientId)

        let localIdentity: ConnectionLocalIdentity
        if let existingIdentity = try await keyManager.fetchCallKeyBundle() {
            localIdentity = existingIdentity
        } else {
            localIdentity = try await generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: call.sender.secretName
            )
        }

        // Use a placeholder session identity: group calls do not use this for key agreement.
        _ = try await createPeerConnection(
            with: call,
            sender: call.sender.secretName,
            recipient: sfuRecipientId,
            localIdentity: localIdentity,
            sessionIdentity: localIdentity.sessionIdentity,
            willFinishNegotiation: true
        )

        // Create and send the offer to the SFU via the app-provided transport.
        call = try await createOffer(call: call)
        await setConnectingIfReady(call: call, callDirection: .outbound(call.supportsVideo ? .video : .voice))
        try await requireTransport().sendOffer(call: call)
        return call
    }
    
    
    // The Call must contain the proper unwrapped session identity props.
    /// Prepares a 1:1 crypto session.
    ///
    /// The call must contain the remote participant's identity props (typically on `call.identityProps`).
    /// After this step, your app can proceed with ciphertext exchange and SDP negotiation.
    ///
    /// See <doc:One-to-One-Calls>.
    public func createCryptoSession(with call: Call) async throws  {
        var call = call
        guard let recipient = call.recipients.first?.secretName else {
            throw EncryptionErrors.missingProps
        }
        guard let identityProps = call.identityProps else {
            logger.log(level: .info, message: "Call will not proceed the session identity for sender is missing")
            throw EncryptionErrors.missingProps
        }
        
        
        var localIdentity: ConnectionLocalIdentity
        if let existingIdentity = try await keyManager.fetchCallKeyBundle() {
            localIdentity = existingIdentity
        } else {
            localIdentity = try await generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: call.sender.secretName)
        }
        
        let connectionIdentity = try await createRecipientIdentity(
            connectionId: call.sharedCommunicationId,
            props: identityProps)
        
        guard let props = await localIdentity.sessionIdentity.props(symmetricKey: localIdentity.symmetricKey) else {
            return
        }
        call.identityProps = props
        
        _ = try await createPeerConnection(
            with: call,
            sender: recipient,
            recipient: call.sender.secretName,
            localIdentity: localIdentity,
            sessionIdentity: connectionIdentity.sessionIdentity)
        
        logger.log(level: .info, message: "Start call created PeerConnection for sharedCommunicationId=\(call.sharedCommunicationId)")
    }
    
    /// Completes the 1:1 crypto handshake after receiving an inbound ciphertext message.
    ///
    /// This method waits for the app to decide whether to accept the call via
    /// ``RTCSession/setCanAnswer(_:)`` or ``RTCSession/setCallAnswerState(_:for:)``.
    /// If accepted, it will create and send an SDP offer via ``RTCTransportEvents/sendOffer(call:)``.
    public func finishCryptoSessionCreation(
        recipient: String,
        ciphertext: Data,
        call: Call
    ) async throws -> Call {
        pendingAnswerCallId = call.id
        if callAnswerStatesById[call.id] == nil {
            callAnswerStatesById[call.id] = .pending
        }
        try await receiveCiphertext(
            recipient: recipient,
            ciphertext: ciphertext,
            call: call)
        
        try await loop.run(30, sleep: .seconds(1)) { [weak self] in
            guard let self else { return false }
            let state: CallAnswerState
            if let perCall = await self.callAnswerStatesById[call.id] {
                state = perCall
            } else {
                state = await self.callAnswerState
            }
            switch state {
            case .pending:
                return true
            case .answered, .rejected:
                return false
            }
        }

        let finalState = callAnswerStatesById[call.id] ?? callAnswerState
        pendingAnswerCallId = nil

        switch finalState {
        case .answered:
            let call = try await createOffer(call: call)
            await self.setConnectingIfReady(call: call, callDirection: .outbound(call.supportsVideo ? .video : .voice))
            try await requireTransport().sendOffer(call: call)
            return call
        case .rejected:
            await shutdown(with: call)
            throw ConnectionErrors.rejected
        case .pending:
            await shutdown(with: call)
            throw ConnectionErrors.unanswered
        }
    }
    
    /// Applies an inbound SDP offer (1:1) and generates/sends an SDP answer.
    ///
    /// This calls ``RTCTransportEvents/sendAnswer(call:metadata:)`` and begins ICE candidate sending.
    public func handleOffer(
        call: Call,
        sdp: SessionDescription,
        metadata: SDPNegotiationMetadata
    ) async throws -> Call {
        
        let modified = await modifySDP(sdp: sdp.sdp, hasVideo: call.supportsVideo)
        
#if os(Android)
        try await rtcClient.setRemoteDescription(RTCSessionDescription(
            typeDescription: "OFFER",
            sdp: modified))
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(
                                    type: sdp.type.rtcSdpType,
                                    sdp: modified),
                            call: call)
#endif
        
        
        let processedCall = try await createAnswer(call: call)
        try await requireTransport().sendAnswer(
            call: processedCall,
            metadata: metadata)
        await setConnectingIfReady(call: call, callDirection: .inbound(call.supportsVideo ? .video : .voice))
        
#if os(iOS) && canImport(AVKit)
        try setExternalAudioSession()
#endif
        try await startSendingCandidates(call: call)
        if var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
            connection.call = processedCall
            await connectionManager.updateConnection(id: call.sharedCommunicationId, with: connection)
        }
        return processedCall
    }
    
    /// Applies an inbound SDP answer (1:1).
    public func handleAnswer(
        call: Call,
        sdp: SessionDescription
    ) async throws {
        
        let modified = await modifySDP(sdp: sdp.sdp, hasVideo: call.supportsVideo)
        
#if os(Android)
        try await rtcClient.setRemoteDescription(RTCSessionDescription(
            typeDescription: "ANSWER",
            sdp: modified))
#else
        try await setRemote(sdp:
                                WebRTC.RTCSessionDescription(type: sdp.type.rtcSdpType, sdp: modified),
                            call: call)
#endif
        if var connection = await connectionManager.findConnection(with: call.sharedCommunicationId) {
            connection.call = call
            await connectionManager.updateConnection(id: call.sharedCommunicationId, with: connection)
        }
    }
    
    /// Applies an inbound ICE candidate.
    public func handleCandidate(
        call: Call,
        candidate: IceCandidate
    ) async throws {
        try await setRemote(candidate: candidate, call: call)
    }
    
    public func generateSenderIdentity(
        connectionId: String,
        secretName: String
    ) async throws -> ConnectionLocalIdentity {
        try await keyManager.generateSenderIdentity(connectionId: connectionId, secretName: secretName)
    }
    
    func createRecipientIdentity(
        connectionId: String,
        props: SessionIdentity.UnwrappedProps
    ) async throws -> ConnectionSessionIdentity {
        try await keyManager.createRecipientIdentity(connectionId: connectionId, props: props)
    }
    
    func fetchLocalIdentity() async throws -> ConnectionLocalIdentity? {
        try await keyManager.fetchCallKeyBundle()
    }

    func requireTransport(
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> RTCTransportEvents {
        guard let delegate else {
            logger.log(level: .error, message: "RTCTransportEvents delegate not set (\(file):\(line))")
            throw RTCErrors.invalidConfiguration("RTCTransportEvents delegate not set")
        }
        return delegate
    }

    /// Sends an opaque ciphertext blob via the app-provided transport.
    ///
    /// This helper exists so non-`RTCSession` actors (like `RTCGroupCall`) can request a send
    /// without violating `RTCSession` actor isolation.
    public func sendCiphertextViaTransport(
        recipient: String,
        connectionId: String,
        ciphertext: Data,
        call: Call
    ) async throws {
        try await requireTransport().sendCiphertext(
            recipient: recipient,
            connectionId: connectionId,
            ciphertext: ciphertext,
            call: call
        )
    }
}


/// Errors related to 1:1 or group-call encryption setup.
public enum EncryptionErrors: Error, Sendable {
    /// A required ciphertext blob was missing.
    case missingCipherText
    /// A required set of identity properties was missing.
    case missingProps
    /// A required crypto payload (e.g., encoded message body) was missing.
    case missingCryptoPayload

    public var errorDescription: String? {
        switch self {
        case .missingCipherText:
            return "Missing ciphertext"
        case .missingProps:
            return "Missing encryption/session identity properties"
        case .missingCryptoPayload:
            return "Missing crypto payload"
        }
    }
}


/// Errors that can occur during RTC operations.
public enum RTCErrors: Error, Sendable {
    /// The session attempted to reconnect but failed.
    case reconnectionFailed
    /// A socket or equivalent underlying transport could not be created.
    case socketCreationFailed
    /// An operation timed out.
    case timeout
    /// An operation required an RTC connection, but none existed.
    case missingRTCConnection
    /// A specific connection could not be found.
    case connectionNotFound
    /// A media track could not be found.
    case trackNotFound
    /// A call object could not be found.
    case callNotFound
    /// Configuration was invalid.
    case invalidConfiguration(String)
    /// A networking error occurred.
    case networkError(String)
    /// A media-related error occurred.
    case mediaError(String)
    
    /// Human-readable description suitable for logging/UX.
    public var errorDescription: String? {
        switch self {
        case .reconnectionFailed:
            return "Failed to reconnect to the network"
        case .socketCreationFailed:
            return "Failed to create network socket"
        case .timeout:
            return "Operation timed out"
        case .missingRTCConnection:
            return "RTC connection is missing"
        case .connectionNotFound:
            return "Connection not found"
        case .trackNotFound:
            return "Media track not found"
        case .callNotFound:
            return "Call not found"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .mediaError(let message):
            return "Media error: \(message)"
        }
    }
}

extension NeedleTailAsyncConsumer {
    func removeAll() async {
        deque.removeAll()
    }
}
