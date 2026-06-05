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
/* SKIP @bridge */
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
        let trimmed = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !trimmed.isEmpty else { return }
        guard let waiters = pendingVideoCaptureWrapperWaiters.removeValue(forKey: trimmed), !waiters.isEmpty else { return }
        for waiter in waiters {
            waiter.resume(returning: wrapper)
        }
    }

#if os(iOS) || os(macOS)
    internal func bindLocalPreviewCaptureRenderer(
        _ renderer: PreviewViewRender,
        connectionId: String
    ) async {
        let trimmed = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !trimmed.isEmpty else { return }
        localPreviewCaptureRenderersByConnectionId[trimmed] = renderer

        if let wrapper = await connectionManager.findConnection(with: trimmed)?.rtcVideoCaptureWrapper {
            await renderer.setCapture(wrapper)
        } else if let wrapper = await waitForVideoCaptureWrapper(connectionId: trimmed) {
            await renderer.setCapture(wrapper)
        }
    }

    internal func rebindRegisteredLocalPreviewCaptureIfNeeded(
        connectionId: String,
        wrapper: RTCVideoCaptureWrapper
    ) async {
        let trimmed = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !trimmed.isEmpty else { return }
        guard let renderer = localPreviewCaptureRenderersByConnectionId[trimmed] else { return }
        await renderer.setCapture(wrapper)
        logger.log(level: .info, message: "Rebound local preview capture to fresh WebRTC video source for connectionId=\(trimmed)")
    }
#endif
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

    /// Controls how the session selects ICE transport policy for new outbound attempts.
    public let iceTransportPolicyStrategy: RTCIceTransportPolicyStrategy
    
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
    
    /// Per-connection flag indicating whether ICE candidates can be sent immediately.
    var readyForCandidatesByConnectionId: [String: Bool] = [:]
    
    /// Monotonic identifier used when creating local tracks/transceivers.
    var lastId = 0
    
    /// Monotonic identifier used when creating ICE candidates.
    var iceId = 0
    
    /// Per-connection buffer for ICE candidates generated before the connection is
    /// ready to send them.
    var iceDequeByConnectionId: [String: Deque<IceCandidate>] = [:]
    
    /// The connection id considered "active" for the current call.
    ///
    /// SFU and 1:1 use cases typically have a single active `RTCPeerConnection` at a time.
    /// We use this to avoid acting on late WebRTC callbacks from a previous call after
    /// a new call has already started.
    var activeConnectionId: String?

    /// Normalized active id for in-call UI (mute, etc.) when the view controller’s `Call` isn’t populated yet.
    internal func fallbackConnectionIdForMuteControls() async -> String? {
        guard let raw = activeConnectionId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.normalizedConnectionId
    }
    
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

    /// Per-connection outbound retry state for `.all` -> `.relay` fallback.
    var connectionFallbackStateByConnectionId: [String: RTCConnectionFallbackState] = [:]
    /// Connection ids currently being recycled for relay fallback.
    ///
    /// During `.all` -> `.relay` retry we intentionally close the old peer connection.
    /// Late ICE callbacks from that stale peer can otherwise race and incorrectly fail
    /// the call while the replacement peer is still being created.
    var relayFallbackRetryingConnectionIds: Set<String> = []

    /// Grace period (milliseconds) before treating an ICE `disconnected` event as fatal
    /// on an already-connected call. Allows transient network interruptions (e.g. WiFi ↔
    /// cellular handoff) to recover without tearing down the call.
    let iceDisconnectGracePeriodMs: UInt64

    /// Pending task that will fail the call after the disconnect grace period expires.
    var disconnectGraceTask: Task<Void, Never>?
    
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
    var adaptiveVideoLastAppliedByConnectionId: [String: (bitrateBps: Int, framerate: Int, scaleResolutionDownBy: Double)] = [:]
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
    var adaptiveVideoLastAppliedByConnectionId: [String: (bitrateBps: Int, framerate: Int, scaleResolutionDownBy: Double)] = [:]
#if os(iOS)
    var adaptiveVideoThermalStateByConnectionId: [String: String] = [:]
#endif
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

    /// Connection IDs that currently have an offer being created.
    /// Prevents concurrent `createOffer` calls on the same peer connection,
    /// which would produce mismatched m-line ordering and crash WebRTC.
    var offerInFlightConnectionIds: Set<String> = []

    /// Normalized connection ids for which the first SFU group offer is not sent yet.
    ///
    /// WebRTC emits `negotiationNeeded` as soon as the first sender is attached; the peer-notifications
    /// handler would call ``sendGroupCallOffer`` while ``createPeerConnection`` is still attaching
    /// video, racing the intentional offer and causing "m-lines order" errors on the second
    /// `setLocalDescription`. Suppress auto-offers until ``beginGroupCallMediaAfterSfuRegistrationIfNeeded``
    /// finishes the initial ``sendGroupCallOffer``.
    var pendingInitialSfuGroupOfferConnectionIds: Set<String> = []
    
    /// Normalized connection ids where ``beginGroupCallMediaAfterSfuRegistrationIfNeeded`` already
    /// sent the first encrypted offer via ``sendGroupCallOffer``. ``finishCryptoSessionCreation``
    /// must not call ``createOffer`` again after `call_cipher` or WebRTC can stay in
    /// `have-local-offer` and reject inbound SFU renegotiation offers.
    var initialSfuGroupMediaOfferSentConnectionIds: Set<String> = []

    /// Normalized connection ids currently inside SFU media bootstrap.
    ///
    /// Registration, answer, and retry paths can all discover that identities are ready at nearly
    /// the same time. Without this guard, two tasks can both pass the "connection does not exist"
    /// check and create duplicate Android PeerConnections/camera capture pipelines for one room.
    var sfuGroupMediaBootstrapInFlightConnectionIds: Set<String> = []

    /// Normalized connection ids whose peer `call_cipher` has installed the receive frame key.
    ///
    /// True 1:1-over-SFU calls must not bind receiver FrameCryptors until this is set. Binding
    /// first can permanently attach a cryptor to a room UUID or other placeholder id before the
    /// real remote track owner key exists.
    var oneToOneSfuReceiveKeyReadyConnectionIds: Set<String> = []

    /// Normalized connection ids that have already emitted the post-cipher `.handshakeComplete`.
    ///
    /// For encrypted 1:1-over-SFU calls this readiness signal is sent only after the peer's
    /// `call_cipher` has installed our receive key. When frame encryption is disabled, the same
    /// signal can be sent immediately after the answer path reaches this stage.
    var oneToOneSfuPostCipherHandshakeSentConnectionIds: Set<String> = []

#if canImport(WebRTC)
    /// Delegate that surfaces frame-cryptor events for debugging and monitoring.
    var frameCryptorDelegate = FrameCryptorDelegate()

    /// Last inbound media counters snapshot per connection, used to verify whether remote media is still arriving.
    var lastInboundVideoCountersByConnectionId: [String: InboundVideoCounters] = [:]
    /// Last outbound media counters snapshot per connection, used to verify whether local media is still leaving this client.
    var lastOutboundVideoCountersByConnectionId: [String: OutboundVideoCounters] = [:]
    /// Non-gated periodic inbound video probes for remote-render bring-up diagnostics.
    var inboundVideoFlowProbeTasksByConnectionId: [String: Task<Void, Never>] = [:]
    /// Non-gated periodic outbound video probes (cross-platform caller/callee diagnostics).
    var outboundVideoFlowProbeTasksByConnectionId: [String: Task<Void, Never>] = [:]
    /// Last time we attempted sender-side outbound video self-recovery per connection.
    var lastOutboundVideoRecoveryUptimeNsByConnectionId: [String: UInt64] = [:]
#endif
    
    /// Remote renderers requested by the UI before the remote track exists.
    ///
    /// On iOS/macOS, the UI may call `renderRemoteVideo(...)` as soon as the call is marked
    /// connected, but the remote receiver/track may be delivered slightly later via
    /// `peerConnection(_:didAdd:streams:)`. On Android, the same timing issue can occur.
    /// We buffer the renderer request here and attach it once the remote video track becomes available.
#if os(Android)
    var pendingRemoteVideoRenderersByConnectionId: [String: Any] = [:]
    /// Local preview renderers requested before the local video track exists.
    ///
    /// Android can request preview rendering during `.connecting` before
    /// `addVideoToStream(...)` has created and stored `localVideoTrack`.
    /// Buffer the view so we can attach as soon as the track is available.
    var pendingLocalVideoRenderersByConnectionId: [String: AndroidPreviewCaptureView] = [:]
#else
    var pendingRemoteVideoRenderersByConnectionId: [String: RTCVideoRenderWrapper] = [:]
#if os(iOS) || os(macOS)
    var localPreviewCaptureRenderersByConnectionId: [String: PreviewViewRender] = [:]
#endif
#endif
    
    /// Pending local video enabled state requested by UI before the connection exists.
    ///
    /// Some call flows can present the UI and request video enable/disable before the
    /// `RTCConnection` has been registered (e.g. inbound CallKit answer timing). We buffer
    /// the desired state and apply it once the peer connection is created.
    var pendingVideoEnabledByConnectionId: [String: Bool] = [:]

    /// Pending local audio enabled state when the UI toggles mic before the peer connection exists
    /// (common for SFU / conference while registration and cipher setup are in flight).
    var pendingAudioEnabledByConnectionId: [String: Bool] = [:]

    // MARK: - Screen capture source storage (platform-specific)
#if os(macOS)
    var _macScreenCaptureSourceStorage: MacScreenCaptureSource?
#endif
#if os(iOS) && !os(Android)
    var _iOSScreenCaptureSourceStorage: iOSScreenCaptureSource?
    /// Connections waiting for ReplayKit broadcast start before advertising screen share to the SFU.
    var pendingScreenShareRenegotiationConnectionIds: Set<String> = []
#endif
#if os(iOS) || os(macOS)
    /// Identifies the capture source that currently owns the outgoing screen track.
    /// Late termination callbacks from a stopped source must never stop a replacement share.
    private var platformScreenCaptureGeneration: UInt64 = 0

    func beginPlatformScreenCaptureGeneration() -> UInt64 {
        platformScreenCaptureGeneration &+= 1
        if platformScreenCaptureGeneration == 0 {
            platformScreenCaptureGeneration = 1
        }
        return platformScreenCaptureGeneration
    }

    func isCurrentPlatformScreenCaptureGeneration(_ generation: UInt64) -> Bool {
        generation != 0 && generation == platformScreenCaptureGeneration
    }

    func invalidatePlatformScreenCaptureGeneration(_ generation: UInt64? = nil) {
        guard generation == nil || generation == platformScreenCaptureGeneration else { return }
        platformScreenCaptureGeneration &+= 1
        if platformScreenCaptureGeneration == 0 {
            platformScreenCaptureGeneration = 1
        }
    }
#endif
#if os(Android)
    nonisolated internal let androidMediaProjectionPermission = AndroidMediaProjectionPermissionBox()

    /// Stores the MediaProjection permission result for use by `addScreenTrackToStream`.
    /// Must be called before `startScreenShare(target: .androidScreen)`.
    ///
    /// `nonisolated` keeps Skip’s generated JNI adapter from awaiting into the actor for this
    /// Android-only permission handoff (Swift 6 `Sendable` / `Task` diagnostics).
    /* SKIP @bridge */ public nonisolated func setAndroidMediaProjectionResult(resultCode: Int, data: Any) {
        androidMediaProjectionPermission.store(resultCode: resultCode, intent: data)
    }
#endif

    // MARK: - Remote screen track notifications

    private var localScreenShareStateContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var remoteScreenTrackContinuations: [UUID: AsyncStream<RemoteScreenTrackEvent>.Continuation] = [:]

    /// Returns an async stream that yields local screen-share state transitions.
    func localScreenShareStateStream() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task { await self.storeLocalScreenShareStateContinuation(id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeLocalScreenShareStateContinuation(id) }
            }
        }
    }

    private func storeLocalScreenShareStateContinuation(_ id: UUID, continuation: AsyncStream<Bool>.Continuation) async {
        localScreenShareStateContinuations[id] = continuation
        let connections = await connectionManager.findAllConnections()
        let isSharing = connections.contains { connection in
            connection.localScreenTrack != nil
        }
        continuation.yield(isSharing)
    }

    private func removeLocalScreenShareStateContinuation(_ id: UUID) {
        localScreenShareStateContinuations.removeValue(forKey: id)
    }

    func notifyLocalScreenShareChanged(isSharing: Bool) {
        for (_, continuation) in localScreenShareStateContinuations {
            continuation.yield(isSharing)
        }
    }

    /// Returns an async stream that yields events whenever a remote participant starts or stops
    /// sharing their screen. View controllers subscribe to this stream to create/destroy screen
    /// rendering tiles dynamically.
    public func remoteScreenTrackStream() -> AsyncStream<RemoteScreenTrackEvent> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task { await self.storeRemoteScreenTrackContinuation(id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeRemoteScreenTrackContinuation(id) }
            }
        }
    }

    private func storeRemoteScreenTrackContinuation(_ id: UUID, continuation: AsyncStream<RemoteScreenTrackEvent>.Continuation) async {
        remoteScreenTrackContinuations[id] = continuation
        for connection in await connectionManager.findAllConnections() {
            let localKey = Self.conferenceParticipantIdentityKey(connection.localParticipantId)
            for participantId in connection.remoteScreenTracksByParticipantId.keys {
                let participantKey = Self.conferenceParticipantIdentityKey(participantId)
                guard !participantKey.isEmpty else { continue }
                guard participantKey != localKey else { continue }
                continuation.yield(
                    RemoteScreenTrackEvent(
                        connectionId: connection.id,
                        participantId: participantId,
                        isActive: true
                    )
                )
            }
        }
    }

    private func removeRemoteScreenTrackContinuation(_ id: UUID) {
        remoteScreenTrackContinuations.removeValue(forKey: id)
    }

    func notifyRemoteScreenTrackChanged(_ event: RemoteScreenTrackEvent) {
        for (_, continuation) in remoteScreenTrackContinuations {
            continuation.yield(event)
        }
    }

    func finishAllRemoteScreenTrackStreams() {
        for (_, continuation) in localScreenShareStateContinuations {
            continuation.finish()
        }
        localScreenShareStateContinuations.removeAll()
        for (_, continuation) in remoteScreenTrackContinuations {
            continuation.finish()
        }
        remoteScreenTrackContinuations.removeAll()
    }

    // MARK: - Remote participant track notifications

    private var remoteParticipantTrackContinuations: [UUID: AsyncStream<RemoteParticipantTrackEvent>.Continuation] = [:]

    /// Returns an async stream that yields events whenever a remote participant's camera
    /// video track is added or removed. The Android controller subscribes to assign
    /// renderers to participants dynamically.
    public func remoteParticipantTrackStream() -> AsyncStream<RemoteParticipantTrackEvent> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task { await self.storeRemoteParticipantTrackContinuation(id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeRemoteParticipantTrackContinuation(id) }
            }
        }
    }

    private func storeRemoteParticipantTrackContinuation(_ id: UUID, continuation: AsyncStream<RemoteParticipantTrackEvent>.Continuation) async {
        remoteParticipantTrackContinuations[id] = continuation
        for connection in await connectionManager.findAllConnections() {
            let localKey = Self.conferenceParticipantIdentityKey(connection.localParticipantId)
            for participantId in connection.remoteVideoTracksByParticipantId.keys {
                let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                let participantKey = Self.conferenceParticipantIdentityKey(trimmed)
                guard !participantKey.isEmpty else { continue }
                guard UUID(uuidString: trimmed) == nil else { continue }
                guard participantKey != localKey else { continue }
                continuation.yield(
                    RemoteParticipantTrackEvent(
                        connectionId: connection.id,
                        participantId: participantId,
                        kind: "video",
                        isActive: true
                    )
                )
            }
        }
    }

    private func removeRemoteParticipantTrackContinuation(_ id: UUID) {
        remoteParticipantTrackContinuations.removeValue(forKey: id)
    }

    func notifyRemoteParticipantTrackChanged(_ event: RemoteParticipantTrackEvent) {
        for (_, continuation) in remoteParticipantTrackContinuations {
            continuation.yield(event)
        }
    }

    /// Snapshot of currently mapped remote camera participants for a group/SFU connection.
    public func activeRemoteParticipantIds(connectionId: String) async -> Set<String> {
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await connectionManager.findConnection(with: normalizedId) else {
            return []
        }
        let local = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Set(connection.remoteVideoTracksByParticipantId.keys.compactMap { participant in
            let trimmed = participant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard UUID(uuidString: trimmed) == nil else { return nil }
            guard trimmed.lowercased() != local else { return nil }
            return trimmed
        })
    }

    func finishAllRemoteParticipantTrackStreams() {
        for (_, continuation) in remoteParticipantTrackContinuations {
            continuation.finish()
        }
        remoteParticipantTrackContinuations.removeAll()
    }

    // MARK: - Conference Permissions

    public private(set) var conferencePermissions = ConferencePermissions()
    private var conferencePermissionContinuations: [UUID: AsyncStream<ConferencePermissions>.Continuation] = [:]

    /// Returns an async stream that yields whenever conference permissions change.
    public func conferencePermissionStream() -> AsyncStream<ConferencePermissions> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeConferencePermissionContinuation(id)
                }
            }
            Task { [weak self] in
                await self?.storeConferencePermissionContinuation(id, continuation: continuation)
                if let current = await self?.conferencePermissions {
                    continuation.yield(current)
                }
            }
        }
    }

    private func storeConferencePermissionContinuation(_ id: UUID, continuation: AsyncStream<ConferencePermissions>.Continuation) {
        conferencePermissionContinuations[id] = continuation
    }

    private func removeConferencePermissionContinuation(_ id: UUID) {
        conferencePermissionContinuations.removeValue(forKey: id)
    }

    /// Called by the app layer when a `ConferencePermissionEvent` is received from NeedleTailKit.
    /// Translates the string-based role map into typed `ConferenceRole` values.
    ///
    /// Username matching is case-insensitive because the server keys roles by IRC nick
    /// while the client uses `secretName`, and casing can differ across transports.
    public static func conferenceParticipantIdentityKey(_ participant: String) -> String {
        var normalized = participant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix(screenStreamPrefix) {
            normalized.removeFirst(screenStreamPrefix.count)
        }
        if normalized.hasSuffix("_") {
            normalized.removeLast()
        }
        if let separator = normalized.firstIndex(of: "_") {
            let suffix = normalized[normalized.index(after: separator)...]
            if suffix == "nil" || UUID(uuidString: String(suffix)) != nil {
                normalized = String(normalized[..<separator])
            }
        }
        return normalized
    }

    public func updateConferenceRoles(
        localUsername: String,
        participantRoles: [String: String],
        timing: ConferenceTiming? = nil
    ) {
        var typedRoles: [String: ConferenceRole] = [:]
        for (username, roleString) in participantRoles {
            typedRoles[username] = ConferenceRole(rawValue: roleString) ?? .viewer
        }
        if typedRoles.isEmpty, !conferencePermissions.participantRoles.isEmpty {
            conferencePermissions = ConferencePermissions(
                localRole: conferencePermissions.localRole,
                participantRoles: conferencePermissions.participantRoles,
                raisedHands: conferencePermissions.raisedHands,
                participantAudioEnabled: conferencePermissions.participantAudioEnabled,
                participantVideoEnabled: conferencePermissions.participantVideoEnabled,
                timing: timing ?? conferencePermissions.timing
            )
            notifyConferencePermissionsChanged()
            return
        }
        let localKey = Self.conferenceParticipantIdentityKey(localUsername)
        if typedRoles.first(where: { Self.conferenceParticipantIdentityKey($0.key) == localKey }) == nil,
           let existing = conferencePermissions.participantRoles.first(where: { Self.conferenceParticipantIdentityKey($0.key) == localKey }) {
            typedRoles[existing.key] = existing.value
        }
        let localRole = typedRoles.first(where: { Self.conferenceParticipantIdentityKey($0.key) == localKey })?.value
            ?? .viewer
        conferencePermissions = ConferencePermissions(
            localRole: localRole,
            participantRoles: typedRoles,
            raisedHands: conferencePermissions.raisedHands,
            participantAudioEnabled: conferencePermissions.participantAudioEnabled,
            participantVideoEnabled: conferencePermissions.participantVideoEnabled,
            timing: timing ?? conferencePermissions.timing
        )
        notifyConferencePermissionsChanged()
    }

    /// Seeds/maintains a best-effort participant list from active media while waiting for
    /// the SFU's role NOTICE. Server role updates remain authoritative when they arrive.
    public func mergeConferenceParticipants(
        localUsername: String,
        activeRemoteParticipants: Set<String>,
        localDefaultRole: ConferenceRole
    ) {
        var roles = conferencePermissions.participantRoles

        func existingKey(for participant: String) -> String? {
            let normalized = Self.conferenceParticipantIdentityKey(participant)
            guard !normalized.isEmpty else { return nil }
            return roles.keys.first { Self.conferenceParticipantIdentityKey($0) == normalized }
        }

        let local = localUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty, existingKey(for: local) == nil {
            roles[local] = roles.isEmpty ? localDefaultRole : conferencePermissions.localRole
        }

        for participant in activeRemoteParticipants {
            let trimmed = participant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { continue }
            if existingKey(for: trimmed) == nil {
                roles[trimmed] = .viewer
            }
        }

        let localRole = existingKey(for: local).flatMap { roles[$0] } ?? conferencePermissions.localRole
        let updated = ConferencePermissions(
            localRole: localRole,
            participantRoles: roles,
            raisedHands: conferencePermissions.raisedHands,
            participantAudioEnabled: conferencePermissions.participantAudioEnabled,
            participantVideoEnabled: conferencePermissions.participantVideoEnabled,
            timing: conferencePermissions.timing
        )
        guard updated != conferencePermissions else { return }
        conferencePermissions = updated
        notifyConferencePermissionsChanged()
    }

    /// Removes a departed participant from best-effort conference presence state.
    ///
    /// Server role NOTICEs remain authoritative when they arrive. This cleanup handles the gap where
    /// media has already disappeared but the app is still showing fallback participant state derived
    /// from prior receiver-track activity.
    public func removeConferenceParticipant(_ participantId: String) {
        let participantKey = Self.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return }

        func removingParticipant<Value>(
            from map: [String: Value]
        ) -> [String: Value] {
            map.filter { key, _ in
                Self.conferenceParticipantIdentityKey(key) != participantKey
            }
        }

        let updated = ConferencePermissions(
            localRole: conferencePermissions.localRole,
            participantRoles: removingParticipant(from: conferencePermissions.participantRoles),
            raisedHands: removingParticipant(from: conferencePermissions.raisedHands),
            participantAudioEnabled: removingParticipant(from: conferencePermissions.participantAudioEnabled),
            participantVideoEnabled: removingParticipant(from: conferencePermissions.participantVideoEnabled),
            timing: conferencePermissions.timing
        )
        guard updated != conferencePermissions else { return }
        conferencePermissions = updated
        notifyConferencePermissionsChanged()
    }

    /// Updates the raised-hand indicator for a conference participant.
    public func updateConferenceHandRaised(participantId: String, isRaised: Bool) {
        let rawParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let participantKey = Self.conferenceParticipantIdentityKey(rawParticipantId)
        guard !participantKey.isEmpty else { return }

        var permissions = conferencePermissions
        let existingHandKey = permissions.raisedHands.keys.first {
            Self.conferenceParticipantIdentityKey($0) == participantKey
        }
        let handKey = existingHandKey
            ?? permissions.participantRoles.keys.first { Self.conferenceParticipantIdentityKey($0) == participantKey }
            ?? rawParticipantId

        if isRaised {
            permissions.raisedHands[handKey] = true
            if permissions.participantRoles[handKey] == nil {
                permissions.participantRoles[handKey] = .viewer
            }
        } else if let existingHandKey {
            permissions.raisedHands.removeValue(forKey: existingHandKey)
        } else {
            permissions.raisedHands.removeValue(forKey: handKey)
        }

        guard permissions != conferencePermissions else { return }
        conferencePermissions = permissions
        notifyConferencePermissionsChanged()
    }

    /// Replaces the raised-hand snapshot from the SFU while preserving the current role map.
    public func replaceConferenceRaisedHands(_ raisedHands: [String: Bool]) {
        var permissions = conferencePermissions
        var nextRaisedHands: [String: Bool] = [:]

        for (participantId, isRaised) in raisedHands where isRaised {
            let rawParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
            let participantKey = Self.conferenceParticipantIdentityKey(rawParticipantId)
            guard !participantKey.isEmpty else { continue }
            let handKey = permissions.participantRoles.keys.first {
                Self.conferenceParticipantIdentityKey($0) == participantKey
            } ?? rawParticipantId
            nextRaisedHands[handKey] = true
            if permissions.participantRoles[handKey] == nil {
                permissions.participantRoles[handKey] = .viewer
            }
        }

        permissions.raisedHands = nextRaisedHands
        guard permissions != conferencePermissions else { return }
        conferencePermissions = permissions
        notifyConferencePermissionsChanged()
    }

    /// Replaces participant mic/camera snapshots from the SFU while preserving roles and hands.
    public func replaceConferenceParticipantMediaState(
        audioEnabled: [String: Bool]?,
        videoEnabled: [String: Bool]?
    ) {
        guard audioEnabled != nil || videoEnabled != nil else { return }
        var permissions = conferencePermissions

        func canonicalMap(_ values: [String: Bool]?) -> [String: Bool] {
            guard let values else { return [:] }
            var result: [String: Bool] = [:]
            for (participantId, enabled) in values {
                let rawParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                let participantKey = Self.conferenceParticipantIdentityKey(rawParticipantId)
                guard !participantKey.isEmpty else { continue }
                let stateKey = permissions.participantRoles.keys.first {
                    Self.conferenceParticipantIdentityKey($0) == participantKey
                } ?? rawParticipantId
                result[stateKey] = enabled
            }
            return result
        }

        if audioEnabled != nil {
            permissions.participantAudioEnabled = canonicalMap(audioEnabled)
        }
        if videoEnabled != nil {
            permissions.participantVideoEnabled = canonicalMap(videoEnabled)
        }

        guard permissions != conferencePermissions else { return }
        conferencePermissions = permissions
        notifyConferencePermissionsChanged()
    }

    /// Tracks best-effort participant mic/camera state from moderation commands.
    public func updateConferenceParticipantMediaState(
        targetParticipantId: String?,
        audioEnabled: Bool?,
        videoEnabled: Bool?
    ) {
        guard audioEnabled != nil || videoEnabled != nil else { return }

        var permissions = conferencePermissions
        let trimmedTarget = targetParticipantId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAllParticipantsCommand = trimmedTarget == nil || trimmedTarget?.isEmpty == true || trimmedTarget == "*"

        func existingParticipantKey(for participant: String) -> String? {
            let normalized = Self.conferenceParticipantIdentityKey(participant)
            guard !normalized.isEmpty else { return nil }
            return permissions.participantRoles.keys.first {
                Self.conferenceParticipantIdentityKey($0) == normalized
            } ?? permissions.participantAudioEnabled.keys.first {
                Self.conferenceParticipantIdentityKey($0) == normalized
            } ?? permissions.participantVideoEnabled.keys.first {
                Self.conferenceParticipantIdentityKey($0) == normalized
            }
        }

        let targetKeys: [String]
        if isAllParticipantsCommand {
            targetKeys = permissions.participantRoles
                .filter { $0.value < .cohost }
                .map(\.key)
        } else if let trimmedTarget, let existing = existingParticipantKey(for: trimmedTarget) {
            targetKeys = [existing]
        } else if let trimmedTarget, !trimmedTarget.isEmpty {
            targetKeys = [trimmedTarget]
        } else {
            targetKeys = []
        }

        guard !targetKeys.isEmpty else { return }
        for key in targetKeys {
            if let audioEnabled {
                permissions.participantAudioEnabled[key] = audioEnabled
            }
            if let videoEnabled {
                permissions.participantVideoEnabled[key] = videoEnabled
            }
        }

        guard permissions != conferencePermissions else { return }
        conferencePermissions = permissions
        notifyConferencePermissionsChanged()
    }

    /// Resets conference permissions back to default (viewer) state.
    public func resetConferencePermissions() {
        conferencePermissions = ConferencePermissions()
        notifyConferencePermissionsChanged()
        for (_, continuation) in conferencePermissionContinuations {
            continuation.finish()
        }
        conferencePermissionContinuations.removeAll()
    }

    /// Stores the initial local mic/camera preference so pre-call choices survive SFU registration timing.
    public func prepareInitialLocalMediaState(
        connectionId: String,
        audioEnabled: Bool,
        videoEnabled: Bool
    ) async {
        let normalizedId = connectionId.normalizedConnectionId
        guard !normalizedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        pendingAudioEnabledByConnectionId[normalizedId] = audioEnabled
        pendingVideoEnabledByConnectionId[normalizedId] = videoEnabled

        if await connectionManager.findConnection(with: normalizedId) != nil {
            do {
                try await setAudioTrack(isEnabled: audioEnabled, connectionId: normalizedId)
            } catch {
                logger.log(level: .warning, message: "Failed to apply initial audio enabled=\(audioEnabled) for \(normalizedId): \(error)")
            }
            await setVideoTrack(isEnabled: videoEnabled, connectionId: normalizedId)
        }
    }

    private func notifyConferencePermissionsChanged() {
        for (_, continuation) in conferencePermissionContinuations {
            continuation.yield(conferencePermissions)
        }
    }

#if canImport(WebRTC)
    /// Legacy/test context for Apple receive-key retries.
    ///
    /// The current `call_cipher` path derives and stores the receive key immediately, even when
    /// RTP receivers have not been added yet. Receiver FrameCryptor binding waits for the key,
    /// not the other way around. This context is retained for older retry hooks and tests.
    struct PendingAppleDeferredReceiveFrameKeyContext: Sendable {
        let remoteTrackOwnerParticipantId: String?
    }

    /// Keyed by ``String/normalizedConnectionId`` for legacy/test receive-key retry hooks.
    var pendingAppleDeferredReceiveFrameKeyContextByNormalizedConnectionId: [String: PendingAppleDeferredReceiveFrameKeyContext] = [:]
#endif

    /// Deduplication key for inbound `call_cipher` payloads.
    ///
    /// Duplicates are defined by both connection id and exact ciphertext bytes. A refreshed
    /// `call_cipher` intentionally has different bytes and must be processed, because it can carry
    /// a new sender frame identity and restart the receive media ratchet at key index 0.
    struct InboundCallCiphertextKey: Hashable, Sendable {
        let connectionId: String
        let ciphertext: Data
    }

    /// `call_cipher` payloads currently being processed by this actor.
    var inboundCallCiphertextsInFlight: Set<InboundCallCiphertextKey> = []

    /// `call_cipher` payloads already consumed successfully.
    var processedInboundCallCiphertexts: Set<InboundCallCiphertextKey> = []

    // MARK: - Frame key provisioning state
    //
    // WebRTC FrameCryptors have their own keyIndex in addition to the provider's key ring.
    // Keep the latest provisioned indices here so late-bound sender/receiver cryptors use
    // the same slot that was populated in the provider.
    var lastFrameKeyIndexByParticipantId: [String: Int] = [:]
    var lastSharedFrameKeyIndex: Int = 0

    // Sender frame keys are ratchet-derived. More than one overlapping `setMessageKey` for the
    // same connection advances the sender key index without the peer necessarily installing that
    // new receive slot, which shows up as FrameCryptor `missingKey`.
    var senderFrameKeyProvisioningConnectionIds: Set<String> = []

    /// Connections whose outbound sender frame key has already been derived and installed.
    var senderFrameKeyProvisionedConnectionIds: Set<String> = []

    /// Last remote frame-identity fingerprint used for each sender media ratchet.
    ///
    /// If an inbound `call_cipher` replaces provisional room/SFU identity props with the real peer
    /// props, the fingerprint changes and our sender key must be refreshed so the peer derives the
    /// same receive key at index 0.
    var senderFrameKeyIdentityFingerprintByConnectionId: [String: String] = [:]

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
            appliedVideoMaxFramerate: appliedVideoMaxFramerate)

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
            localIdentity: localIdentity)
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

    /// Normalized id for teardown idempotency and ``RTCConnectionManager`` lookup (`#` stripped + lowercased).
    func teardownConnectionIdKey(_ connectionId: String) -> String {
        connectionId
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .normalizedConnectionId
            .lowercased()
    }

    private func removeFromAuxiliaryTeardownSets(connectionId raw: String) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let variants = Set(
            [
                trimmed,
                trimmed.normalizedConnectionId,
                teardownConnectionIdKey(raw)
            ].filter { !$0.isEmpty })
        for v in variants {
            offerInFlightConnectionIds.remove(v)
            pendingInitialSfuGroupOfferConnectionIds.remove(v)
        }
    }

    func beginEnding(connectionId: String) -> Bool {
        let key = teardownConnectionIdKey(connectionId)
        guard !key.isEmpty else { return false }
        if endedConnectionIds.contains(key) { return false }
        if finishingConnectionIds.contains(key) { return false }
        finishingConnectionIds.insert(key)
        return true
    }

    func endEnding(connectionId: String) {
        let key = teardownConnectionIdKey(connectionId)
        guard !key.isEmpty else { return }
        finishingConnectionIds.remove(key)
        removeFromAuxiliaryTeardownSets(connectionId: connectionId)
        endedConnectionIds.insert(key)
        recentlyEndedConnectionIds.append(key)
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

    func resetTeardownIdempotency(forConnectionId connectionId: String) {
        let rawTrimmed = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedId = rawTrimmed.normalizedConnectionId
        let canonical = teardownConnectionIdKey(connectionId)

        finishingConnectionIds.remove(canonical)
        endedConnectionIds.remove(canonical)
        recentlyEndedConnectionIds.removeAll { $0 == canonical }

        finishingConnectionIds.remove(rawTrimmed)
        endedConnectionIds.remove(rawTrimmed)
        recentlyEndedConnectionIds.removeAll { $0 == rawTrimmed }

        finishingConnectionIds.remove(normalizedId)
        endedConnectionIds.remove(normalizedId)
        recentlyEndedConnectionIds.removeAll { $0 == normalizedId }

        removeFromAuxiliaryTeardownSets(connectionId: connectionId)
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
        let key = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if let existing = inboundCandidateConsumers[key] {
            return existing
        }
        let created = NeedleTailAsyncConsumer<IceCandidate>()
        inboundCandidateConsumers[key] = created
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
        let supportedCodecs = videoEncoderFactory.supportedCodecs()
#if os(iOS)
        // iOS sender freezes are strongly correlated with VideoToolbox/H264 stalls
        // (outbound frames flat while capture continues). Prefer VP8 to avoid VT path.
        if let preferredCodec = supportedCodecs.first(where: { $0.name.uppercased() == "VP8" }) {
            videoEncoderFactory.preferredCodec = preferredCodec
        } else if let preferredCodec = supportedCodecs.first(where: { $0.parameters["profile-level-id"] == kRTCMaxSupportedH264ProfileLevelConstrainedBaseline }) {
            videoEncoderFactory.preferredCodec = preferredCodec
        }
#else
        if let preferredCodec = supportedCodecs.first(where: { $0.parameters["profile-level-id"] == kRTCMaxSupportedH264ProfileLevelConstrainedBaseline }) {
            videoEncoderFactory.preferredCodec = preferredCodec
        }
#endif
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
#endif
    
    public init(
        iceServers: [String],
        username: String,
        password: String,
        iceTransportPolicyStrategy: RTCIceTransportPolicyStrategy = .allThenRelay(timeoutMilliseconds: 4_000),
        iceDisconnectGracePeriodMs: UInt64 = 8_000,
        logger: NeedleTailLogger = NeedleTailLogger("[RTCSession]"),
        cryptorConfig: CryptorConfiguration = .init(),
        delegate: RTCTransportEvents?
    ) async {
        let (notificationStream, notificationContinuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        self.peerConnectionNotificationsStream = notificationStream
        self.peerConnectionNotificationsContinuation = notificationContinuation
        self.iceServers = iceServers
        self.username = username
        self.password = password
        self.iceTransportPolicyStrategy = iceTransportPolicyStrategy
        self.iceDisconnectGracePeriodMs = iceDisconnectGracePeriodMs
        self.logger = logger
        self.ratchetSalt = cryptorConfig.ratchetSalt
        self.frameEncryptionKeyMode = cryptorConfig.mode
        self.enableEncryption = cryptorConfig.mode != .none
        logger.log(
            level: enableEncryption ? .info : .warning,
            message: "FrameCryptor is \(self.enableEncryption ? "ENABLED" : "DISABLED") for this RTCSession.")
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
            discardFrameWhenCryptorNotReady: true)
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


    public struct CryptorConfiguration: Sendable {
        let ratchetSalt: Data
        let mode: RTCFrameEncryptionKeyMode

        public init(
            ratchetSalt: Data = "PQSRTCFrameEncryptionSalt".data(using: .utf8)!,
            mode: RTCFrameEncryptionKeyMode = .perParticipant
        ) {
            self.ratchetSalt = ratchetSalt
            self.mode = mode
        }
    }
}

#if canImport(WebRTC)
extension RTCSession {
    struct InboundVideoCounters: Sendable {
        let audioPacketsReceived: Int64
        let packetsReceived: Int64
        let framesReceived: Int64
        let framesDecoded: Int64
    }

    struct OutboundVideoCounters: Sendable {
        let audioPacketsSent: Int64
        let packetsSent: Int64
        let framesEncoded: Int64
        let framesSent: Int64
    }
}
#endif

extension RTCSession {
    /// Resolves whether the given call should be treated as inbound or outbound for local UI/state.
    ///
    /// We prefer the session participant identity when available so both Apple and Android use the
    /// same shared-state logic regardless of transport details (direct or SFU-relayed 1:1).
    func inferredCallDirection(for call: Call) -> CallStateMachine.CallDirection {
        let callType: CallStateMachine.CallType = call.supportsVideo ? .video : .voice

        guard let sessionParticipant else {
            return .inbound(callType)
        }

        let isLocalSender =
            call.sender.secretName == sessionParticipant.secretName ||
            (!call.sender.deviceId.isEmpty && call.sender.deviceId == sessionParticipant.deviceId)

        return isLocalSender ? .outbound(callType) : .inbound(callType)
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
public enum RTCErrors: Error, LocalizedError, Sendable {
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
    /// An operation was denied due to insufficient conference permissions.
    case permissionDenied(String)
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
        case .permissionDenied(let message):
            return "Permission denied: \(message)"
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
    case none
}

/* SKIP @bridge */ public enum RTCIceTransportPolicyStrategy: Sendable, Equatable {
    case all
    case relayOnly
    case allThenRelay(timeoutMilliseconds: UInt64)
}

/* SKIP @bridge */ public enum RTCIceTransportSelection: String, Sendable, Codable {
    case all
    case relay
}

struct RTCConnectionFallbackState {
    let connectionId: String
    let sender: String
    let recipient: String
    let localIdentity: ConnectionLocalIdentity
    let direction: CallStateMachine.CallDirection
    var latestCall: Call
    var currentPolicy: RTCIceTransportSelection
    var hasRetriedToRelay: Bool
    var timeoutTask: Task<Void, Never>?
}
