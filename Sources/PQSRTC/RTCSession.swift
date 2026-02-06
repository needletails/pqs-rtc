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
    
    // MARK: - Type aliases & executors
    
    /// Resolves a logical `participantId` for a given set of inbound WebRTC stream/track identifiers.
    ///
    /// SFU deployments often encode the participant identity in stream IDs or track metadata.
    /// This resolver lets the app plug in that mapping logic.
    public typealias RemoteParticipantIdResolver = @Sendable (_ streamIds: [String], _ trackId: String, _ trackKind: String) -> String?
    
    /// Serial executor used by the ratchet key managers and other internal async tasks.
    let executor = RatchetExecutor(queue: .init(label: "testable-executor"))
    
    /// Unowned executor view exposed for integration with Swift concurrency.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    // MARK: - Video capture wrapper availability (Apple platforms)
    //
    // The UI preview pipeline (PreviewViewRender) needs the per-connection RTCVideoCaptureWrapper
    // to inject captured frames into the WebRTC video source.
    //
    // That wrapper is created when the local WebRTC video track is created, which may happen
    // after the preview UI starts. We expose an event-driven "await wrapper" API to avoid
    // polling or retry loops in controllers.
#if canImport(WebRTC)
    private var pendingVideoCaptureWrapperWaiters: [String: [CheckedContinuation<RTCVideoCaptureWrapper?, Never>]] = [:]
    
    /// Resolves when the connection's `rtcVideoCaptureWrapper` is available, or returns `nil`
    /// if it never becomes available within the timeout.
    ///
    /// This method is non-throwing and does not poll; it waits on a continuation that is
    /// resumed when the wrapper is created.
    internal func waitForVideoCaptureWrapper(
        connectionId: String,
        timeoutNanoseconds: UInt64 = 3_000_000_000
    ) async -> RTCVideoCaptureWrapper? {
        let trimmed = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !trimmed.isEmpty else { return nil }
        
        if let existing = await connectionManager.findConnection(with: trimmed)?.rtcVideoCaptureWrapper {
            return existing
        }
        
        return await withCheckedContinuation { (continuation: CheckedContinuation<RTCVideoCaptureWrapper?, Never>) in
            pendingVideoCaptureWrapperWaiters[trimmed, default: []].append(continuation)
            
            // Enforce a timeout so we never hang a controller task forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.resumeVideoCaptureWrapperWaiters(connectionId: trimmed, wrapper: nil)
            }
        }
    }
    
    /// Called internally when a wrapper is created (or when timing out) to resume waiters.
    internal func resumeVideoCaptureWrapperWaiters(connectionId: String, wrapper: RTCVideoCaptureWrapper?) {
        let trimmed = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let waiters = pendingVideoCaptureWrapperWaiters.removeValue(forKey: trimmed), !waiters.isEmpty else { return }
        for waiter in waiters {
            waiter.resume(returning: wrapper)
        }
    }
#endif
    
    // MARK: - Core runtime infrastructure
    
    /// Internal loop used to schedule RTC-related work.
    let loop = NTKLoop()
    
    /// Manages the lifecycle and lookup of `RTCConnection` instances.
    let connectionManager = RTCConnectionManager()
    
    /// Key manager used for frame/media encryption identities.
    let keyManager = KeyManager()
    
    /// Key manager used for signaling (SDP/ICE) encryption identities.
    let pcKeyManager = KeyManager()
    
    /// Shared peer-connection notifications stream.
    ///
    /// This stream is consumed by a long-lived task (`handleNotificationsStream`) and is fed by
    /// platform delegates (Apple/Android peer-connection delegates).
    ///
    /// Important: This stream must remain usable across sequential calls. Some teardown paths or
    /// consumer restarts can lead to a finished stream; therefore we keep the ability to recreate
    /// the stream+continuation pair.
    var peerConnectionNotificationsStream: AsyncStream<PeerConnectionNotifications?>
    
    /// Continuation used to push new peer-connection notifications into `peerConnectionNotificationsStream`.
    var peerConnectionNotificationsContinuation: AsyncStream<PeerConnectionNotifications?>.Continuation

    // MARK: - Network quality observation (UI-agnostic)
    //
    // PQSRTC does not own UI, but it can surface a coarse network-quality signal that apps can
    // map to UX (banners, icons, "audio-only" prompts, etc.).
    private struct NetworkQualitySink: Sendable {
        let id: UUID
        let continuation: AsyncStream<RTCNetworkQualityUpdate>.Continuation
    }
    private var networkQualitySinks: [NetworkQualitySink] = []
    private var lastEmittedNetworkQualityByConnectionId: [String: RTCNetworkQuality] = [:]
    private var lastEmittedNetworkQualityUptimeNsByConnectionId: [String: UInt64] = [:]
    
    /// Inbound ICE candidates buffered per `connectionId`.
    ///
    /// Candidates may arrive before `setRemote` completes. Keeping per-connection buffers
    /// prevents cross-call mixing when multiple calls occur back-to-back.
    var inboundCandidateConsumers: [String: NeedleTailAsyncConsumer<IceCandidate>] = [:]
    
    /// The participant that represents "this device/user" for the current session, if known.
    var sessionParticipant: Call.Participant?
    
    // MARK: - Configuration
    
    /// ICE servers used when creating peer connections.
    public let iceServers: [String]
    
    /// TURN/STUN username associated with `iceServers`.
    public let username: String
    
    /// TURN/STUN password associated with `iceServers`.
    public let password: String
    
    /// Logger used for all RTCSession-related logging.
    public let logger: NeedleTailLogger
    
    /// Salt used when deriving frame-level E2EE keys.
    public let ratchetSalt: Data
    
    /// Controls how frame-level E2EE keys are applied to the WebRTC key provider.
    public let frameEncryptionKeyMode: RTCFrameEncryptionKeyMode
    
    let enableEncryption: Bool
    
    // MARK: - Crypto state
    
    /// Manages frame/media ratchet key state.
    let ratchetManager: RatchetKeyStateManager<SHA256>
    
    /// Manages peer-connection/signaling ratchet key state.
    let pcRatchetManager: DoubleRatchetStateManager<SHA256>
    
    /// Task processor for handling encryption/decryption tasks.
    /// Lazy to avoid using self before all stored properties are initialized.
    lazy var taskProcessor: TaskProcessor = {
        TaskProcessor(
            executor: executor,
            keyManager: pcKeyManager,
            logger: logger,
            rtcSession: self,
            ratchetManager: pcRatchetManager)
    }()
    
    // MARK: - Delegates & callbacks
    
    /// Transport delegate used to send encrypted signaling messages.
    var delegate: RTCTransportEvents?
    
    /// Media delegate used for group-call/conference style track notifications.
    var mediaDelegate: RTCSessionMediaEvents?
    
    /// Handler invoked for inbound WebRTC data-channel messages.
    ///
    /// Set this if you want to receive arbitrary app-level messages (e.g. chat, control signals)
    /// delivered over `RTCDataChannel`.
    var dataChannelMessageHandler: (@Sendable (RTCDataChannelMessage) async -> Void)?
    
    /// Controls how inbound receiver events map to a `participantId`.
    var remoteParticipantIdResolver: RemoteParticipantIdResolver?
    
    // MARK: - Call lifecycle & state (grouped by access level)
    
    // MARK: Public
    
    /// Acceptance state for the current inbound call.
    ///
    /// `finishCryptoSessionCreation(recipient:ciphertext:call:)` waits up to ~30 seconds for
    /// this to transition away from `.pending`.
    public var callAnswerState: CallAnswerState = .pending
    
    /// High-level call state machine used by the session.
    public var callState = CallStateMachine()
    
    /// Whether the 1:1 crypto handshake has completed for the active connection.
    public private(set) var handshakeComplete = false
    
    // MARK: Internal
    
    /// Per-call group-call state keyed by `sharedCommunicationId`.
    var groupCalls: [String: RTCGroupCall] = [:]
    
    /// Pending inbound call identifier whose acceptance is being gated.
    var pendingAnswerCallId: UUID?
    
    /// Per-call acceptance state used when multiple inbound calls may be in flight.
    var callAnswerStatesById: [UUID: CallAnswerState] = [:]
    
    /// Whether the current inbound crypto session should generate and send an offer.
    var shouldOffer = false
    
    /// Whether the peer connection/ICE machinery has been started for the current call.
    var notRunning = true
    
    /// Whether the session is ready to send/receive ICE candidates.
    var readyForCandidates = false
    
    /// Monotonic identifier used when creating local tracks/transceivers.
    var lastId = 0
    
    /// Monotonic identifier used when creating ICE candidates.
    var iceId = 0
    
    /// Local buffer for ICE candidates when ordering needs to be preserved.
    var iceDeque = Deque<IceCandidate>()
    
    /// The connection id considered "active" for the current call.
    ///
    /// SFU and 1:1 use cases typically have a single active `RTCPeerConnection` at a time.
    /// We use this to avoid acting on late WebRTC callbacks from a previous call after
    /// a new call has already started.
    var activeConnectionId: String?
    
    /// Legacy/global peer-connection state (kept for compatibility).
    ///
    /// Prefer `pcStateByConnectionId` for correctness across sequential calls.
    var pcState = PeerConnectionState.none
    
    /// Peer-connection state per `connectionId`.
    var pcStateByConnectionId: [String: PeerConnectionState] = [:]
    
    /// Long-lived task that consumes `peerConnectionNotificationsStream`.
    var notificationsTask: Task<Void, Error>?
    
    /// Generation counter for `notificationsTask` used to avoid acting on stale tasks.
    var notificationsTaskGeneration: UInt64 = 0
    
    /// Tracks whether the notifications consumer is currently processing events.
    var notificationsConsumerIsRunning = false
    
    /// Task that mirrors high-level RTC state into `callState`.
    var stateTask: Task<Void, Error>?
#if os(iOS)
    /// Shared `RTCAudioSession` wrapper used to integrate with the platform audio stack.
    nonisolated let audioSession = RTCAudioSession.sharedInstance()
#endif
#if os(macOS)
    /// Optional audio player used for simple audio feedback on macOS.
    var audioPlayer: AVAudioPlayer?
#endif
    
    // MARK: - Android-only session state
    
#if os(Android)
    /// Whether the Android client has started receiving remote frames for the active connection.
    var didStartReceiving: Bool = false
    
    /// Raw remote view snapshots used for logging/cleanup on Android.
    var remoteViewData: [Data] = []

    // MARK: - Adaptive video send control (Android)
    //
    // Mirrors the Apple implementation but uses `org.webrtc.PeerConnection.getStats`.
    var adaptiveVideoSendTasksByConnectionId: [String: Task<Void, Never>] = [:]
    var adaptiveVideoLastAppliedByConnectionId: [String: (bitrateBps: Int, framerate: Int)] = [:]
#endif
    
    // MARK: - Platform-specific RTC clients & encryption
    
#if os(Android)
    
    /// SkipRTC client used to drive WebRTC on Android platforms.
    ///
    /// This is a shared singleton wrapper around the underlying Android WebRTC stack.
    let rtcClient = AndroidRTCClient()
#elseif canImport(WebRTC)
    
    /// WebRTC frame-cryptor key provider used for frame-level E2EE on Apple platforms.
    var keyProvider: RTCFrameCryptorKeyProvider?
    
    /// Tracks whether audio has been activated for the current call on Apple platforms.
    nonisolated(unsafe) var isAudioActivated = false

    // MARK: - RTP egress diagnostics (Apple platforms)
    //
    // These tasks periodically query `getStats` to answer:
    // - are we sending outbound RTP at all?
    // - which candidate pair is selected?
    // - is DTLS connected?
    //
    // This is intentionally keyed per connection id so group-call renegotiations don't mix telemetry.
    var outboundRtpStatsTasksByConnectionId: [String: Task<Void, Never>] = [:]

    // MARK: - Adaptive video send control (Apple platforms)
    //
    // Group calls via SFU do not transcode. We therefore adapt the *sender* egress ceiling
    // using `availableOutgoingBitrate` from the selected ICE candidate pair.
    //
    // This allows:
    // - low bandwidth: keep bitrate/fps low to avoid freezes
    // - good bandwidth: raise bitrate/fps automatically for better quality
    var adaptiveVideoSendTasksByConnectionId: [String: Task<Void, Never>] = [:]
    var adaptiveVideoLastAppliedByConnectionId: [String: (bitrateBps: Int, framerate: Int)] = [:]
#endif
    
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
    
#if canImport(WebRTC)
    /// Delegate that surfaces frame-cryptor events for debugging and monitoring.
    var frameCryptorDelegate = FrameCryptorDelegate()
#endif
    
    /// Remote renderers requested by the UI before the remote track exists.
    ///
    /// On iOS/macOS, the UI may call `renderRemoteVideo(...)` as soon as the call is marked
    /// connected, but the remote receiver/track may be delivered slightly later via
    /// `peerConnection(_:didAdd:streams:)`. On Android, the same timing issue can occur.
    /// We buffer the renderer request here and attach it once the remote video track becomes available.
#if os(Android)
    var pendingRemoteVideoRenderersByConnectionId: [String: Any] = [:]
#else
    var pendingRemoteVideoRenderersByConnectionId: [String: RTCVideoRenderWrapper] = [:]
#endif
    
    /// Pending local video enabled state requested by UI before the connection exists.
    ///
    /// Some call flows can present the UI and request video enable/disable before the
    /// `RTCConnection` has been registered (e.g. inbound CallKit answer timing). We buffer
    /// the desired state and apply it once the peer connection is created.
    var pendingVideoEnabledByConnectionId: [String: Bool] = [:]

    // MARK: - Frame key provisioning diagnostics (DEBUG-only consumers)
    //
    // We track the latest key index provisioned per participant so we can emit targeted diagnostics
    // if a receiver cryptor is created before the app/server has injected keys for that participant.
    // This does not affect crypto correctness; it is purely a guardrail for production operations.
    var lastFrameKeyIndexByParticipantId: [String: Int] = [:]

    public var isGroupCall = false

    /// Controls sender ceilings for SFU/group call video.
    ///
    /// Default: `.standard`.
    public private(set) var sfuVideoQualityProfile: RTCVideoQualityProfile = .standard

    /// Updates the SFU/group-call video quality profile.
    ///
    /// This affects:
    /// - the initial sender ceiling applied when a video sender is created
    /// - adaptive sender ceilings once `availableOutgoingBitrate` is available
    public func setSfuVideoQualityProfile(_ profile: RTCVideoQualityProfile) {
        sfuVideoQualityProfile = profile
    }
    // MARK: - Public configuration & delegate API
    
    /// Sets the transport delegate.
    ///
    /// This is where the session emits outbound signaling/ciphertext via ``RTCTransportEvents``.
    public func setDelegate(_ delegate: RTCTransportEvents) {
        self.delegate = delegate
    }
    
    public func setSessionParticipant(_ participant: Call.Participant) {
        self.sessionParticipant = participant
    }

    /// Sets the media delegate used for group-call/conference style track notifications.
    public func setMediaDelegate(_ delegate: RTCSessionMediaEvents) {
        self.mediaDelegate = delegate
    }
    
    public func setHandshakeComplete(_ handshakeComplete: Bool) {
        self.handshakeComplete = handshakeComplete
    }

    // MARK: - Public network quality API

    /// Creates a stream that emits coarse network quality updates.
    ///
    /// The SDK emits updates only when the quality bucket changes, with a small cooldown to
    /// avoid oscillation spam.
    public func createNetworkQualityStream() -> AsyncStream<RTCNetworkQualityUpdate> {
        let id = UUID()
        let logger = self.logger
        return AsyncStream<RTCNetworkQualityUpdate>(bufferingPolicy: .bufferingNewest(10)) { continuation in
            networkQualitySinks.append(.init(id: id, continuation: continuation))
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    await self.removeNetworkQualitySink(id: id)
                }
                logger.log(level: .debug, message: "Network quality stream terminated (id=\(id))")
            }
        }
    }

    private func removeNetworkQualitySink(id: UUID) {
        networkQualitySinks.removeAll { $0.id == id }
    }

    /// Emits a network-quality update if the bucket changed (and cooldown allows).
    func emitNetworkQualityUpdateIfNeeded(
        connectionId: String,
        quality: RTCNetworkQuality,
        availableOutgoingBitrateBps: Int?,
        rttMs: Int?,
        appliedVideoMaxBitrateBps: Int?,
        appliedVideoMaxFramerate: Int?,
        nowUptimeNs: UInt64
    ) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }

        // Dedupe: only emit when bucket changes.
        let lastQuality = lastEmittedNetworkQualityByConnectionId[normalizedId]
        if lastQuality == quality { return }

        // Cooldown: avoid oscillation spam.
        let lastUptime = lastEmittedNetworkQualityUptimeNsByConnectionId[normalizedId] ?? 0
        if lastUptime > 0, nowUptimeNs >= lastUptime {
            let delta = nowUptimeNs - lastUptime
            if delta < 2_000_000_000 { // 2s
                return
            }
        }

        lastEmittedNetworkQualityByConnectionId[normalizedId] = quality
        lastEmittedNetworkQualityUptimeNsByConnectionId[normalizedId] = nowUptimeNs

        let update = RTCNetworkQualityUpdate(
            connectionId: normalizedId,
            quality: quality,
            availableOutgoingBitrateBps: availableOutgoingBitrateBps,
            rttMs: rttMs,
            appliedVideoMaxBitrateBps: appliedVideoMaxBitrateBps,
            appliedVideoMaxFramerate: appliedVideoMaxFramerate
        )

        for sink in networkQualitySinks {
            sink.continuation.yield(update)
        }
    }

    /// Controls how inbound receiver events map to a `participantId`.
    ///
    /// By default, SFU-style calls use `streamIds.first` as the participant identifier.
    /// If your SFU uses a different convention (e.g., demux IDs or custom stream IDs),
    /// set a resolver here.
    public func setRemoteParticipantIdResolver(_ resolver: @escaping RemoteParticipantIdResolver) {
        self.remoteParticipantIdResolver = resolver
    }

    // MARK: - Public group-call API
    
    /// Creates an SFU group call wrapper that drives SFU signaling through `RTCSession`.
    ///
    /// The returned ``RTCGroupCall`` provides a single ingress for decoded SFU signaling,
    /// roster updates, and key distribution.
    public func createGroupCall(
        call: Call,
        sfuRecipientId: String,
        localIdentity: ConnectionLocalIdentity
    ) -> RTCGroupCall {
        RTCGroupCall(
            call: call,
            sfuRecipientId: sfuRecipientId,
            localIdentity: localIdentity
        )
    }

    // MARK: - Public data-channel API
    
    /// Sets a handler invoked for inbound WebRTC data-channel messages.
    ///
    /// - Note: The handler runs asynchronously and may be called multiple times concurrently.
    public func setDataChannelMessageHandler(
        _ handler: (@escaping @Sendable (RTCDataChannelMessage) async -> Void)
    ) {
        self.dataChannelMessageHandler = handler
    }

    // MARK: - Public inbound call acceptance API
    
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

    // MARK: - Internal teardown idempotency helpers
    
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

    // MARK: - Internal connection & candidate helpers
    
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

    // MARK: - Peer-connection factory & initialization
#if canImport(WebRTC)
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
    
    public init(
        iceServers: [String],
        username: String,
        password: String,
        logger: NeedleTailLogger = NeedleTailLogger("[RTCSession]"),
        ratchetSalt: Data = "PQSRTCFrameEncryptionSalt".data(using: .utf8)!,
        frameEncryptionKeyMode: RTCFrameEncryptionKeyMode = .shared,
        enableEncryption: Bool = false,
        delegate: RTCTransportEvents?
    ) async {
        let (notificationStream, notificationContinuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        self.peerConnectionNotificationsStream = notificationStream
        self.peerConnectionNotificationsContinuation = notificationContinuation
        self.iceServers = iceServers
        self.username = username
        self.password = password
        self.logger = logger
        self.ratchetSalt = ratchetSalt
        self.frameEncryptionKeyMode = frameEncryptionKeyMode
        self.enableEncryption = enableEncryption
        self.delegate = delegate
        self.ratchetManager = RatchetKeyStateManager<SHA256>(executor: executor)
        self.pcRatchetManager = DoubleRatchetStateManager<SHA256>(executor: executor)

#if canImport(WebRTC)
        // FrameCryptor key provider is created lazily when encryption is enabled.
        if enableEncryption {
            ensureFrameKeyProviderIfNeeded()
        }
#endif
        
        // taskProcessor is lazy and will be initialized on first access
        // This avoids using self before all stored properties are initialized
        
        logger.log(level: .trace, message: "Created RTCSession")
    }

#if canImport(WebRTC)
    /// Ensures the WebRTC frame-cryptor key provider exists when frame encryption is enabled.
    ///
    /// This is intentionally idempotent and safe to call repeatedly.
    func ensureFrameKeyProviderIfNeeded() {
        guard enableEncryption else { return }
        if keyProvider != nil { return }
        
        logger.log(level: .debug, message: "Creating FrameCryptorKeyProvider (mode: \(frameEncryptionKeyMode))")
        keyProvider = RTCFrameCryptorKeyProvider(
            ratchetSalt: ratchetSalt,
            ratchetWindowSize: 0,
            sharedKeyMode: frameEncryptionKeyMode == .shared,
            uncryptedMagicBytes: "PQSRTCMagicBytes".data(using: .utf8)!,
            failureTolerance: -1,
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true
        )
    }
#endif

    /// Recreates the peer-connection notifications stream.
    ///
    /// Use this during teardown to ensure subsequent calls start with a fresh, non-terminated
    /// notification pipeline.
    func resetPeerConnectionNotificationsStream() {
        let (notificationStream, notificationContinuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        self.peerConnectionNotificationsStream = notificationStream
        self.peerConnectionNotificationsContinuation = notificationContinuation
    }

    // MARK: - Internal transport helpers
    
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
}


/// Errors related to 1:1 or group-call encryption setup.
public enum EncryptionErrors: Error, Sendable {
    /// A required ciphertext blob was missing.
    case missingCipherText
    /// A required set of identity properties was missing.
    case missingProps
    /// A required crypto payload (e.g., encoded message body) was missing.
    case missingCryptoPayload
    case missingSessionIdentity
    case missingMetadata
    
    public var errorDescription: String? {
        switch self {
        case .missingCipherText:
            return "Missing ciphertext"
        case .missingProps:
            return "Missing encryption/session identity properties"
        case .missingCryptoPayload:
            return "Missing crypto payload"
        case .missingSessionIdentity:
            return "Missing session identity"
        case .missingMetadata:
             return "Missing metadata"
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
    
    case missingGroupCall
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
        case .missingGroupCall:
            return "No group call available"
        }
    }
}

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
