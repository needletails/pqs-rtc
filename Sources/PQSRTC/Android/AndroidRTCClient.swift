//
//  AndroidRTCClient.swift
//  pqs-rtc
//
//  Created by Cole M on 9/9/25.
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

import SkipLib
import Foundation
import Collections
#if SKIP
import org.webrtc.__
import kotlin.__

// SKIP INSERT: // Capturer observer that normalizes orientation (rotation=0) without resizing
// SKIP INSERT: class CapturerObserverProxy(
// SKIP INSERT:     private val downstream: org.webrtc.CapturerObserver,
// SKIP INSERT:     private val normalizeToUpright: Boolean = true
// SKIP INSERT: ) : org.webrtc.CapturerObserver {
// SKIP INSERT:     override fun onCapturerStarted(success: Boolean) = downstream.onCapturerStarted(success)
// SKIP INSERT:     override fun onCapturerStopped() = downstream.onCapturerStopped()
// SKIP INSERT:     override fun onFrameCaptured(frame: org.webrtc.VideoFrame) {
// SKIP INSERT:         val rot = frame.rotation
// SKIP INSERT:         if (!normalizeToUpright || rot == 0) {
// SKIP INSERT:             downstream.onFrameCaptured(frame)
// SKIP INSERT:             return
// SKIP INSERT:         }
// SKIP INSERT:         val src = frame.buffer.toI420() ?: run {
// SKIP INSERT:             downstream.onFrameCaptured(frame); return
// SKIP INSERT:         }
// SKIP INSERT:         val w = src.width
// SKIP INSERT:         val h = src.height
// SKIP INSERT:         val outW = if (rot == 90 || rot == 270) h else w
// SKIP INSERT:         val outH = if (rot == 90 || rot == 270) w else h
// SKIP INSERT:         val dst = org.webrtc.JavaI420Buffer.allocate(outW, outH)
// SKIP INSERT:         org.webrtc.YuvHelper.I420Rotate(
// SKIP INSERT:             src.dataY, src.strideY,
// SKIP INSERT:             src.dataU, src.strideU,
// SKIP INSERT:             src.dataV, src.strideV,
// SKIP INSERT:             dst.dataY, dst.strideY,
// SKIP INSERT:             dst.dataU, dst.strideU,
// SKIP INSERT:             dst.dataV, dst.strideV,
// SKIP INSERT:             w, h, rot // rotate pixels to upright
// SKIP INSERT:         )
// SKIP INSERT:         src.release()
// SKIP INSERT:         val rotatedFrame = org.webrtc.VideoFrame(dst, /*rotation*/ 0, frame.timestampNs)
//android.util.Log.d("NeedleTailRTC", "SEND VideoPacket w=${rotatedFrame.buffer.width} h=${rotatedFrame.buffer.height} rot=${rotatedFrame.rotation} ts=${frame.timestampNs}")
// SKIP INSERT:         downstream.onFrameCaptured(rotatedFrame)
// SKIP INSERT:         dst.release()
// SKIP INSERT:     }
// SKIP INSERT: }

// SKIP INSERT: class RTCClientPeerObserver(
// SKIP INSERT:     private val client: AndroidRTCClient
// SKIP INSERT: ) : org.webrtc.PeerConnection.Observer {
// SKIP INSERT:
// SKIP INSERT:     override fun onSignalingChange(newState: org.webrtc.PeerConnection.SignalingState) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Signaling state changed to: $newState")
// SKIP INSERT:         val state = convertSignalingState(newState)
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.signalingStateChange(state))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onIceConnectionChange(newState: org.webrtc.PeerConnection.IceConnectionState) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "ICE connection state changed to: $newState")
// SKIP INSERT:         val state = convertIceConnectionState(newState)
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.iceConnectionStateChange(state))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onStandardizedIceConnectionChange(newState: org.webrtc.PeerConnection.IceConnectionState) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Standardized ICE connection state changed to: $newState")
// SKIP INSERT:         val state = convertIceConnectionState(newState)
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.standardizedIceConnectionStateChange(state))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onConnectionChange(newState: org.webrtc.PeerConnection.PeerConnectionState) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Peer connection state changed to: $newState")
// SKIP INSERT:         val state = convertPeerConnectionState(newState)
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.peerConnectionStateChange(state))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onIceConnectionReceivingChange(receiving: Boolean) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "ICE connection receiving changed to: $receiving")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.iceConnectionReceivingChange(receiving))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onIceGatheringChange(newState: org.webrtc.PeerConnection.IceGatheringState) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "ICE gathering state changed to: $newState")
// SKIP INSERT:         val state = convertIceGatheringState(newState)
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.iceGatheringStateChange(state))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onIceCandidate(candidate: org.webrtc.IceCandidate) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "ICE candidate generated: ${candidate.sdp}")
// SKIP INSERT:         val ice = RTCIceCandidate(
// SKIP INSERT:             sdp = candidate.sdp,
// SKIP INSERT:             sdpMLineIndex = candidate.sdpMLineIndex.toInt(),
// SKIP INSERT:             sdpMid = candidate.sdpMid
// SKIP INSERT:         )
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.candidate(ice))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onIceCandidatesRemoved(candidates: kotlin.Array<org.webrtc.IceCandidate>) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Removed ${candidates.size} ICE candidates")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.iceCandidatesRemoved(candidates.size))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onAddStream(stream: org.webrtc.MediaStream) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Stream added: ${stream.id}")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.addStream(stream.id))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onRemoveStream(stream: org.webrtc.MediaStream) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Stream removed: ${stream.id}")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.removeStream(stream.id))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onDataChannel(dataChannel: org.webrtc.DataChannel) {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "Data channel opened: ${dataChannel.label()}")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.dataChannel(dataChannel.label()))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onRenegotiationNeeded() {
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "PeerConnection renegotiation needed")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.shouldNegotiate)
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onAddTrack(receiver: org.webrtc.RtpReceiver, mediaStreams: kotlin.Array<org.webrtc.MediaStream>) {
// SKIP INSERT:         val trackKind = receiver.track()?.kind() ?: "unknown"
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "On Add Track: $trackKind")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.addTrack(trackKind))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onRemoveTrack(receiver: org.webrtc.RtpReceiver) {
// SKIP INSERT:         val trackKind = receiver.track()?.kind() ?: "unknown"
// SKIP INSERT:         android.util.Log.d("RTCClientPeerObserver", "On Removed Track: $trackKind")
// SKIP INSERT:         client.triggerRTCEvent(ClientPCEvent.removeTrack(trackKind))
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     override fun onTrack(transceiver: org.webrtc.RtpTransceiver) {
// SKIP INSERT:         val track = transceiver.receiver.track()
// SKIP INSERT:         when (track) {
// SKIP INSERT:             is org.webrtc.AudioTrack -> {
// SKIP INSERT:                 client.triggerRTCEvent(ClientPCEvent.audioTrack(RTCAudioTrack(track)))
// SKIP INSERT:                 android.util.Log.d("RTCClientPeerObserver", "Started receiving on transceiver: audioTrack")
// SKIP INSERT:             }
// SKIP INSERT:             is org.webrtc.VideoTrack -> {
// SKIP INSERT:                 client.triggerRTCEvent(ClientPCEvent.videoTrack(RTCVideoTrack(track)))
// SKIP INSERT:                 android.util.Log.d("RTCClientPeerObserver", "Started receiving on transceiver: videoTrack")
// SKIP INSERT:             }
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     // Helper functions to convert Android WebRTC states to string descriptions
// SKIP INSERT:     private fun convertSignalingState(state: org.webrtc.PeerConnection.SignalingState): String {
// SKIP INSERT:         return when (state) {
// SKIP INSERT:             org.webrtc.PeerConnection.SignalingState.STABLE -> "stable"
// SKIP INSERT:             org.webrtc.PeerConnection.SignalingState.HAVE_LOCAL_OFFER -> "haveLocalOffer"
// SKIP INSERT:             org.webrtc.PeerConnection.SignalingState.HAVE_LOCAL_PRANSWER -> "haveLocalPrAnswer"
// SKIP INSERT:             org.webrtc.PeerConnection.SignalingState.HAVE_REMOTE_OFFER -> "haveRemoteOffer"
// SKIP INSERT:             org.webrtc.PeerConnection.SignalingState.HAVE_REMOTE_PRANSWER -> "haveRemotePrAnswer"
// SKIP INSERT:             org.webrtc.PeerConnection.SignalingState.CLOSED -> "closed"
// SKIP INSERT:             else -> "unknown"
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     private fun convertIceConnectionState(state: org.webrtc.PeerConnection.IceConnectionState): String {
// SKIP INSERT:         return when (state) {
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.NEW -> "new"
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.CHECKING -> "checking"
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.CONNECTED -> "connected"
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.COMPLETED -> "completed"
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.FAILED -> "failed"
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.DISCONNECTED -> "disconnected"
// SKIP INSERT:             org.webrtc.PeerConnection.IceConnectionState.CLOSED -> "closed"
// SKIP INSERT:             else -> "new"
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     private fun convertPeerConnectionState(state: org.webrtc.PeerConnection.PeerConnectionState): String {
// SKIP INSERT:         return when (state) {
// SKIP INSERT:             org.webrtc.PeerConnection.PeerConnectionState.NEW -> "new"
// SKIP INSERT:             org.webrtc.PeerConnection.PeerConnectionState.CONNECTING -> "connecting"
// SKIP INSERT:             org.webrtc.PeerConnection.PeerConnectionState.CONNECTED -> "connected"
// SKIP INSERT:             org.webrtc.PeerConnection.PeerConnectionState.DISCONNECTED -> "disconnected"
// SKIP INSERT:             org.webrtc.PeerConnection.PeerConnectionState.FAILED -> "failed"
// SKIP INSERT:             org.webrtc.PeerConnection.PeerConnectionState.CLOSED -> "closed"
// SKIP INSERT:             else -> "new"
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT:
// SKIP INSERT:     private fun convertIceGatheringState(state: org.webrtc.PeerConnection.IceGatheringState): String {
// SKIP INSERT:         return when (state) {
// SKIP INSERT:             org.webrtc.PeerConnection.IceGatheringState.NEW -> "new"
// SKIP INSERT:             org.webrtc.PeerConnection.IceGatheringState.GATHERING -> "gathering"
// SKIP INSERT:             org.webrtc.PeerConnection.IceGatheringState.COMPLETE -> "complete"
// SKIP INSERT:             else -> "new"
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT: }

/// Android WebRTC `SdpObserver` used to receive the result of `createOffer`/`createAnswer`.
///
/// The Android WebRTC API is callback-based; this helper bridges those callbacks into Swift closures
/// while ensuring thread-safety and keeping the observer alive until completion.
private final class RTCOnCreateSdpObserver: NSObject, org.webrtc.SdpObserver, @unchecked Sendable {
    
    private let lock = NSLock()
    private let callback: (RTCSessionDescription) -> Void
    init(_ callback: @escaping (RTCSessionDescription) -> Void) { self.callback = callback }
    
    override func onCreateSuccess(_ desc: org.webrtc.SessionDescription?) {
        guard let d = desc else { return }
        lock.lock()
        defer {
            lock.unlock()
        }
        callback(RTCSessionDescription(type: d.type, sdp: d.description))
    }
    
    override func onSetSuccess() {}
    override func onCreateFailure(_ error: String?) {}
    override func onSetFailure(_ error: String?) {}
}

/// Android WebRTC `SdpObserver` used to receive the completion of `setLocalDescription`/`setRemoteDescription`.
///
/// The observer is retained by `AndroidRTCClient` until the `onSetSuccess()` callback fires.
private final class RTCOnSetObserver: NSObject, org.webrtc.SdpObserver, @unchecked Sendable {
    
    private let lock = NSLock()
    private let callback: () -> Void
    init(_ callback: (() -> Void)?) { self.callback = callback ?? {} }
    
    override func onSetSuccess() {
        lock.lock()
        defer {
            lock.unlock()
        }
        callback()
    }
    
    override func onCreateSuccess(_ desc: org.webrtc.SessionDescription?) {}
    override func onCreateFailure(_ error: String?) {}
    override func onSetFailure(_ error: String?) {}
}

/// Platform-neutral session description used by the Android client wrapper.
///
/// This mirrors the Apple WebRTC `RTCSessionDescription` shape while wrapping
/// `org.webrtc.SessionDescription` for the Skip/Kotlin backend.
public struct RTCSessionDescription: Sendable {
    public let type: org.webrtc.SessionDescription.`Type`
    public let sdp: String
    public let typeDescription: String
    
    /// Creates an SDP wrapper from the platform description type and raw SDP.
    ///
    /// - Parameters:
    ///   - type: The SDP type (offer/answer/etc).
    ///   - sdp: The raw SDP string.
    public init(type: org.webrtc.SessionDescription.`Type`, sdp: String) {
        switch type {
        case org.webrtc.SessionDescription.`Type`.OFFER:
            self.typeDescription = "OFFER"
        case org.webrtc.SessionDescription.`Type`.ANSWER:
            self.typeDescription = "ANSWER"
        case org.webrtc.SessionDescription.`Type`.PRANSWER:
            self.typeDescription = "PRANSWER"
        case org.webrtc.SessionDescription.`Type`.ROLLBACK:
            self.typeDescription = "ROLLBACK"
        @unknown default:
            // Avoid crashing on unexpected platform enum cases.
            self.typeDescription = "UNKNOWN"
        }
        self.type = type
        self.sdp = sdp
    }
    
    /// Creates an SDP wrapper from a string description.
    ///
    /// This initializer is useful when SDP type metadata comes from external signaling.
    /// Unknown values fall back to `.OFFER` to avoid crashing.
    ///
    /// - Parameters:
    ///   - typeDescription: A string such as `"OFFER"` or `"ANSWER"`.
    ///   - sdp: The raw SDP string.
    public init(typeDescription: String, sdp: String) {
        switch typeDescription {
        case "OFFER":
            self.type = org.webrtc.SessionDescription.`Type`.OFFER
        case "ANSWER":
            self.type = org.webrtc.SessionDescription.`Type`.ANSWER
        case "PRANSWER":
            self.type = org.webrtc.SessionDescription.`Type`.PRANSWER
        case "ROLLBACK":
            self.type = org.webrtc.SessionDescription.`Type`.ROLLBACK
        default:
            // Avoid crashing on unexpected values from external sources.
            self.type = org.webrtc.SessionDescription.`Type`.OFFER
        }
        self.sdp = sdp
        self.typeDescription = typeDescription
    }
    
    /// The underlying platform session description.
    public var platform: org.webrtc.SessionDescription { org.webrtc.SessionDescription(type, sdp) }
}

/// Platform-neutral ICE candidate wrapper used by the Android client.
///
/// This type mirrors the Apple WebRTC `RTCIceCandidate` data model but wraps
/// `org.webrtc.IceCandidate` for the Skip/Kotlin backend.
public struct RTCIceCandidate: Sendable, Equatable {
    
    public let sdp: String
    public let sdpMLineIndex: Int32
    public let sdpMid: String?
    
    /// Creates an ICE candidate wrapper.
    ///
    /// - Parameters:
    ///   - sdp: Candidate SDP string.
    ///   - sdpMLineIndex: Media line index for the candidate.
    ///   - sdpMid: Media identifier.
    public init(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }
    
    /// The underlying platform ICE candidate.
    var platform: org.webrtc.IceCandidate {
        org.webrtc.IceCandidate(sdpMid, Int32(sdpMLineIndex), sdp)
    }
}

/// Errors thrown by `AndroidRTCClient` when the underlying WebRTC stack cannot be used.
public enum RTCClientErrors: Swift.Error, Sendable {
    /// A generic peer-connection failure with context.
    case peerConnectionError(String)
}

/// Events emitted from the Android WebRTC `PeerConnection.Observer` bridge.
///
/// These events are forwarded to `AndroidPeerConnectionDelegate` and then bridged into the
/// platform-neutral notification stream used by `RTCSession`.
public enum ClientPCEvent: Sendable {
    /// A local ICE candidate was gathered.
    case candidate(RTCIceCandidate)
    /// A remote video track was received.
    case videoTrack(RTCVideoTrack)
    /// A remote audio track was received.
    case audioTrack(RTCAudioTrack)
    /// The signaling state changed.
    case signalingStateChange(String)
    /// The ICE connection state changed.
    case iceConnectionStateChange(String)
    /// The standardized ICE connection state changed.
    case standardizedIceConnectionStateChange(String)
    /// The peer connection state changed.
    case peerConnectionStateChange(String)
    /// ICE connection receiving changed.
    case iceConnectionReceivingChange(Bool)
    /// The ICE gathering state changed.
    case iceGatheringStateChange(String)
    /// ICE candidates were removed.
    case iceCandidatesRemoved(Int)
    /// A legacy stream was added (compatibility).
    case addStream(String)
    /// A legacy stream was removed (compatibility).
    case removeStream(String)
    /// A data channel was opened.
    case dataChannel(String)
    /// Renegotiation was requested.
    case shouldNegotiate
    case addTrack(String) // track kind
    case removeTrack(String) // track kind
}

/// Android-side WebRTC client wrapper.
///
/// This class provides a Swift-friendly façade over `org.webrtc.*` APIs (via Skip) and exposes a
/// platform-neutral surface to the rest of the SDK.
///
/// Responsibilities include peer connection creation, local media track/capture setup, EGL/renderer
/// lifecycle, and (when enabled) attaching frame-level E2EE cryptors.
///
/// Thread safety: most methods synchronize internal state with an `NSLock`.
public final class AndroidRTCClient: @unchecked Sendable {
    
    /// Callback used to deliver newly created local SDP.
    public typealias OnLocalSDP = @Sendable (RTCSessionDescription) -> Void
    
    // Thread safety
    private let lock = NSLock()
    private var isClosed = false
    private var initializationFailed = false // Track if WebRTC initialization has failed
    
    /// Retained Android `PeerConnection.Observer` bridge instance.
    private var observer: Any? // SKIP INSERT: RTCClientPeerObserver?
    
    private weak var delegate: AndroidPeerConnectionDelegate?
   
    /// Sets the delegate that receives `ClientPCEvent` notifications.
    public func setEventDelegate(_ delegate: AndroidPeerConnectionDelegate?) {
        lock.lock()
        defer { lock.unlock() }
        self.delegate = delegate
    }
    
    /// Delivers a WebRTC event to the delegate, if the client is not closed.
    func triggerRTCEvent(_ event: ClientPCEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        delegate?.handleRTCEvent(event)
    }
    
    // Retain SDP observers until their callbacks fire (avoid premature disposal)
    private var pendingOfferObserver: RTCOnCreateSdpObserver?
    private var pendingAnswerObserver: RTCOnCreateSdpObserver?
    private var pendingSetLocalObserver: RTCOnSetObserver?
    private var pendingSetRemoteObserver: RTCOnSetObserver?
    
    private var iceServers = [String]()
    private var factory: org.webrtc.PeerConnectionFactory?
    /// The current peer connection wrapper, if initialized.
    public var peerConnection: RTCPeerConnection?
    private var eglBase: org.webrtc.EglBase?
    private var videoSource: RTCVideoSource?
    private var audioSource: RTCAudioSource?
    private var localAudioTrack: RTCAudioTrack?
    /// The current local video track wrapper, if created.
    private(set) var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: org.webrtc.Camera2Capturer?
    private var surfaceTextureHelper: org.webrtc.SurfaceTextureHelper?
    
    // Track active surface renderers for proper cleanup
    private var activeSurfaceRenderers: Set<org.webrtc.SurfaceViewRenderer> = []
    
    // MARK: E2EE
    var keyProvider: org.webrtc.FrameCryptorKeyProvider?
    private var keyProviderIsSharedKeyMode: Bool?
    var videoSenderCryptor: org.webrtc.FrameCryptor?
    var audioSenderCryptor: org.webrtc.FrameCryptor?
    var videoReceiverCryptor: org.webrtc.FrameCryptor?
    var audioReceiverCryptor: org.webrtc.FrameCryptor?

    // Group-call support: multiple remote participants can be received on a single PeerConnection.
    // Keep per-participant receiver cryptors so we don't dispose previous ones.
    var videoReceiverCryptorsByParticipantId: [String: org.webrtc.FrameCryptor] = [:]
    var audioReceiverCryptorsByParticipantId: [String: org.webrtc.FrameCryptor] = [:]

    private var pendingSharedKey: Data?
    private var pendingSharedKeyIndex: Int32?

    private var pendingPerParticipantKeys: [String: [Int32: Data]] = [:]

    /// Mirrors Apple `RTCFrameCryptorKeyProvider.setSharedKey`.
    ///
    /// If the Android `FrameCryptorKeyProvider` hasn't been created yet, we stash the key/index
    /// and apply it as soon as `setSharedKey(..., ratchetSalt:)` (or `setupCryptor`) creates the provider.
    func setSharedKey(_ key: Data, with index: Int32) async {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot set shared key: AndroidRTCClient has been closed")
            return
        }

        guard let keyProvider else {
            pendingSharedKey = key
            pendingSharedKeyIndex = index
            // SKIP INSERT: android.util.Log.w("AndroidRTCClient", "FrameCryptorKeyProvider not ready; stashing shared key index $index")
            return
        }

        // SKIP INSERT: val keySize = key.count
        // SKIP INSERT: val keyBytesUInt8 = kotlin.UByteArray(keySize) { key.bytes[it] }
        // SKIP INSERT: val keyBytes: ByteArray = kotlin.ByteArray(size = keyBytesUInt8.size) { idx -> keyBytesUInt8[idx].toByte() }
        // SKIP INSERT: val success = keyProvider.setSharedKey(index.toInt(), keyBytes)
        // SKIP INSERT: if (!success) {
        // SKIP INSERT:     android.util.Log.e("AndroidRTCClient", "❌ Failed to set shared media key at index $index")
        // SKIP INSERT: } else {
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Shared media key set at index $index")
        // SKIP INSERT: }
    }

    /// Ratchet-salt-aware variant that ensures the Android key provider exists.
    ///
    /// This is the closest equivalent to the Apple behavior where a keyProvider is always present
    /// and `setSharedKey` immediately updates the active key ring.
    func setSharedKey(_ key: Data, with index: Int32, ratchetSalt: Data) async {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot set shared key: AndroidRTCClient has been closed")
            return
        }

        // These should match the Apple-side configuration as closely as possible.
        // SKIP INSERT: val ratchetWindowSize = 0
        // SKIP INSERT: val sharedKeyMode = true
        // SKIP INSERT: val uncryptedMagicBytes: ByteArray? = "PQSRTCMagicBytes".encodeToByteArray()
        // SKIP INSERT: val failureTolerance = -1
        // SKIP INSERT: val keyRingSize = 16
        // SKIP INSERT: val discardFrameWhenCryptorNotReady = true

        // SKIP INSERT: var keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: val modeMatches = (this@AndroidRTCClient.keyProviderIsSharedKeyMode == null) || (this@AndroidRTCClient.keyProviderIsSharedKeyMode == sharedKeyMode)
        // SKIP INSERT: if (keyProvider == null || !modeMatches) {
        // SKIP INSERT:     // If the mode changes (shared vs per-participant), recreate the provider.
        // SKIP INSERT:     this@AndroidRTCClient.keyProvider = null
        // SKIP INSERT:     keyProvider = null
        // SKIP INSERT:     val ratchetSaltSize = ratchetSalt.count
        // SKIP INSERT:     val ratchetSaltBytes = kotlin.UByteArray(ratchetSaltSize) { ratchetSalt.bytes[it] }
        // SKIP INSERT:     val ratchetSaltByteArray = kotlin.ByteArray(size = ratchetSaltBytes.size) { idx -> ratchetSaltBytes[idx].toByte() }
        // SKIP INSERT:     keyProvider = org.webrtc.FrameCryptorFactory.createFrameCryptorKeyProvider(
        // SKIP INSERT:         sharedKeyMode,
        // SKIP INSERT:         ratchetSaltByteArray,
        // SKIP INSERT:         ratchetWindowSize,
        // SKIP INSERT:         uncryptedMagicBytes,
        // SKIP INSERT:         failureTolerance,
        // SKIP INSERT:         keyRingSize,
        // SKIP INSERT:         discardFrameWhenCryptorNotReady
        // SKIP INSERT:     )
        // SKIP INSERT:     this@AndroidRTCClient.keyProvider = keyProvider
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderIsSharedKeyMode = sharedKeyMode
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "🔐 FrameCryptorKeyProvider created (sharedKeyMode=$sharedKeyMode)")
        // SKIP INSERT: }

        // Apply the requested key.
        // SKIP INSERT: val keySize = key.count
        // SKIP INSERT: val keyBytesUInt8 = kotlin.UByteArray(keySize) { key.bytes[it] }
        // SKIP INSERT: val keyBytes: ByteArray = kotlin.ByteArray(size = keyBytesUInt8.size) { idx -> keyBytesUInt8[idx].toByte() }
        // SKIP INSERT: val success = keyProvider?.setSharedKey(index.toInt(), keyBytes) ?: false
        // SKIP INSERT: if (!success) {
        // SKIP INSERT:     android.util.Log.e("AndroidRTCClient", "❌ Failed to set shared media key at index $index")
        // SKIP INSERT: } else {
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Shared media key set at index $index")
        // SKIP INSERT: }

        // If we had an earlier stashed key, prefer the most recent call (this one).
        pendingSharedKey = nil
        pendingSharedKeyIndex = nil
    }

    /// Ensures a key provider exists in the requested mode.
    private func ensureKeyProvider(sharedKeyMode: Bool, ratchetSalt: Data) async {
        // We piggy-back on `setSharedKey(..., ratchetSalt:)` for provider creation logic.
        // If we're in per-participant mode, we call a dedicated creation path.
        if sharedKeyMode {
            // Caller will set actual key separately.
            if keyProvider == nil || keyProviderIsSharedKeyMode != true {
                await setSharedKey(Data(), with: 0, ratchetSalt: ratchetSalt)
            }
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return }

        // SKIP INSERT: val ratchetWindowSize = 0
        // SKIP INSERT: val sharedKeyModeK = false
        // SKIP INSERT: val uncryptedMagicBytes: ByteArray? = "PQSRTCMagicBytes".encodeToByteArray()
        // SKIP INSERT: val failureTolerance = -1
        // SKIP INSERT: val keyRingSize = 16
        // SKIP INSERT: val discardFrameWhenCryptorNotReady = true

        // SKIP INSERT: var keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: val modeMatches = (this@AndroidRTCClient.keyProviderIsSharedKeyMode == null) || (this@AndroidRTCClient.keyProviderIsSharedKeyMode == sharedKeyModeK)
        // SKIP INSERT: if (keyProvider == null || !modeMatches) {
        // SKIP INSERT:     val ratchetSaltSize = ratchetSalt.count
        // SKIP INSERT:     val ratchetSaltBytes = kotlin.UByteArray(ratchetSaltSize) { ratchetSalt.bytes[it] }
        // SKIP INSERT:     val ratchetSaltByteArray = kotlin.ByteArray(size = ratchetSaltBytes.size) { idx -> ratchetSaltBytes[idx].toByte() }
        // SKIP INSERT:     keyProvider = org.webrtc.FrameCryptorFactory.createFrameCryptorKeyProvider(
        // SKIP INSERT:         sharedKeyModeK,
        // SKIP INSERT:         ratchetSaltByteArray,
        // SKIP INSERT:         ratchetWindowSize,
        // SKIP INSERT:         uncryptedMagicBytes,
        // SKIP INSERT:         failureTolerance,
        // SKIP INSERT:         keyRingSize,
        // SKIP INSERT:         discardFrameWhenCryptorNotReady
        // SKIP INSERT:     )
        // SKIP INSERT:     this@AndroidRTCClient.keyProvider = keyProvider
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderIsSharedKeyMode = sharedKeyModeK
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "🔐 FrameCryptorKeyProvider created (sharedKeyMode=$sharedKeyModeK)")
        // SKIP INSERT: }
    }

    /// Per-participant key setter (participant-scoped key ring).
    func setKey(_ key: Data, with index: Int32, forParticipant participantId: String, ratchetSalt: Data) async {
        await ensureKeyProvider(sharedKeyMode: false, ratchetSalt: ratchetSalt)

        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return }

        guard let keyProvider else {
            var byIndex = pendingPerParticipantKeys[participantId] ?? [:]
            byIndex[index] = key
            pendingPerParticipantKeys[participantId] = byIndex
            // SKIP INSERT: android.util.Log.w("AndroidRTCClient", "KeyProvider not ready; stashing per-participant key for '$participantId' index $index")
            return
        }

        // SKIP INSERT: try {
        // SKIP INSERT:   val keySize = key.count
        // SKIP INSERT:   val keyBytesUInt8 = kotlin.UByteArray(keySize) { key.bytes[it] }
        // SKIP INSERT:   val keyBytes: ByteArray = kotlin.ByteArray(size = keyBytesUInt8.size) { idx -> keyBytesUInt8[idx].toByte() }
        // SKIP INSERT:   // Use reflection for compatibility across WebRTC versions.
        // SKIP INSERT:   val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setKey" && it.parameterTypes.size == 3 }
        // SKIP INSERT:   val success = if (m != null) {
        // SKIP INSERT:     (m.invoke(keyProvider, participantId, index.toInt(), keyBytes) as? Boolean) ?: false
        // SKIP INSERT:   } else {
        // SKIP INSERT:     false
        // SKIP INSERT:   }
        // SKIP INSERT:   if (!success) {
        // SKIP INSERT:     android.util.Log.e("AndroidRTCClient", "❌ Failed to set per-participant key for '$participantId' index $index")
        // SKIP INSERT:   } else {
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Per-participant key set for '$participantId' index $index")
        // SKIP INSERT:   }
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "❌ Exception setting per-participant key: ${e.message}", e)
        // SKIP INSERT: }
    }

    /// Best-effort export of the current key. If the underlying WebRTC API doesn't support it,
    /// this returns empty `Data`.
    func exportKey(forParticipant participantId: String, index: Int32) async -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return Data() }
        guard let keyProvider else { return Data() }

        // SKIP INSERT: return try {
        // SKIP INSERT:   val m = keyProvider.javaClass.methods.firstOrNull { it.name == "exportKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:   val bytes = if (m != null) (m.invoke(keyProvider, participantId, index.toInt()) as? ByteArray) else null
        // SKIP INSERT:   if (bytes == null) {
        // SKIP INSERT:     android.util.Log.w("AndroidRTCClient", "exportKey not available for '$participantId' index $index")
        // SKIP INSERT:     null
        // SKIP INSERT:   } else {
        // SKIP INSERT:     bytes
        // SKIP INSERT:   }
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "exportKey failed: ${e.message}", e)
        // SKIP INSERT:   null
        // SKIP INSERT: }?.let { bytes ->
        // SKIP INSERT:   val u = kotlin.UByteArray(bytes.size) { idx -> bytes[idx].toUByte() }
        // SKIP INSERT:   Data(bytes: u)
        // SKIP INSERT: } ?: Data()

        return Data()
    }

    /// Best-effort ratchet; returns the newly derived key if available, else empty `Data`.
    func ratchetKey(forParticipant participantId: String, index: Int32) async -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return Data() }
        guard let keyProvider else { return Data() }

        // SKIP INSERT: return try {
        // SKIP INSERT:   val m = keyProvider.javaClass.methods.firstOrNull { it.name == "ratchetKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:   val bytes = if (m != null) (m.invoke(keyProvider, participantId, index.toInt()) as? ByteArray) else null
        // SKIP INSERT:   if (bytes == null) {
        // SKIP INSERT:     android.util.Log.w("AndroidRTCClient", "ratchetKey not available for '$participantId' index $index")
        // SKIP INSERT:     null
        // SKIP INSERT:   } else {
        // SKIP INSERT:     bytes
        // SKIP INSERT:   }
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "ratchetKey failed: ${e.message}", e)
        // SKIP INSERT:   null
        // SKIP INSERT: }?.let { bytes ->
        // SKIP INSERT:   val u = kotlin.UByteArray(bytes.size) { idx -> bytes[idx].toUByte() }
        // SKIP INSERT:   Data(bytes: u)
        // SKIP INSERT: } ?: Data()

        return Data()
    }

    // MARK: - E2EE (FrameCryptor)

    /// Initializes (or reuses) a WebRTC FrameCryptorKeyProvider and sets the current shared media key.
    ///
    /// Notes:
    /// - We use shared-key mode to mirror the Apple implementation (`RTCFrameCryptorKeyProvider.setSharedKey`).
    /// - `participant` is kept for API symmetry but is not required in shared-key mode.
    func setupCryptor(key: Data, index: Int, participant: String, ratchetSalt: Data) async {
        // Kept for backwards call-sites: create/ensure key provider and set the shared key.
        await setSharedKey(key, with: Int32(index), ratchetSalt: ratchetSalt)
    }

    /// Attaches FrameCryptor encryptors to current RTP senders (audio/video) on the active PeerConnection.
    func createSenderEncryptedFrame(participant: String, connectionId: String) async {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot create sender encrypted frame: AndroidRTCClient has been closed")
            return
        }

        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: val pc = this@AndroidRTCClient.peerConnection?.platformPeerConnection
        // SKIP INSERT: val factory = this@AndroidRTCClient.factory
        // SKIP INSERT: if (keyProvider == null || pc == null || factory == null) {
        // SKIP INSERT:     android.util.Log.e("AndroidRTCClient", "KeyProvider, PeerConnection, or Factory not initialized")
        // SKIP INSERT:     return
        // SKIP INSERT: }
        // SKIP INSERT: val pcNonNull = pc!!
        // SKIP INSERT: val senders = pcNonNull.senders
        // SKIP INSERT: val videoSender = senders.firstOrNull { it.track()?.kind() == "video" }
        // SKIP INSERT: val audioSender = senders.firstOrNull { it.track()?.kind() == "audio" }

        // SKIP INSERT: fun attachObserver(tag: String, cryptor: org.webrtc.FrameCryptor?) {
        // SKIP INSERT:     cryptor?.setObserver(object : org.webrtc.FrameCryptor.Observer {
        // SKIP INSERT:         override fun onFrameCryptionStateChanged(participantId: String, newState: org.webrtc.FrameCryptor.FrameCryptionState) {
        // SKIP INSERT:             val stateDescription = when (newState) {
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.NEW -> "new"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.OK -> "ok"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.MISSINGKEY -> "missingKey"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.KEYRATCHETED -> "keyRatcheted"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.INTERNALERROR -> "internalError"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.ENCRYPTIONFAILED -> "encryptionFailed"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.DECRYPTIONFAILED -> "decryptionFailed"
        // SKIP INSERT:                 else -> "unknown(${newState.ordinal})"
        // SKIP INSERT:             }
        // SKIP INSERT:             val logLevel = if (newState == org.webrtc.FrameCryptor.FrameCryptionState.OK) android.util.Log.INFO else android.util.Log.WARN
        // SKIP INSERT:             android.util.Log.println(logLevel, "AndroidRTCClient", "[$tag] FrameCryptor state for '$participantId': $stateDescription")
        // SKIP INSERT:             if (newState == org.webrtc.FrameCryptor.FrameCryptionState.MISSINGKEY) {
        // SKIP INSERT:                 android.util.Log.e("AndroidRTCClient", "[$tag] ⚠️ Missing key for '$participantId'")
        // SKIP INSERT:             } else if (newState == org.webrtc.FrameCryptor.FrameCryptionState.INTERNALERROR) {
        // SKIP INSERT:                 android.util.Log.e("AndroidRTCClient", "[$tag] ❌ Internal error for '$participantId'")
        // SKIP INSERT:             }
        // SKIP INSERT:         }
        // SKIP INSERT:     })
        // SKIP INSERT: }

        // Video sender encryptor
        // SKIP INSERT: this@AndroidRTCClient.videoSenderCryptor?.dispose()
        // SKIP INSERT: this@AndroidRTCClient.videoSenderCryptor = null
        // SKIP INSERT: if (videoSender != null) {
        // SKIP INSERT:     val cryptor = org.webrtc.FrameCryptorFactory.createFrameCryptorForRtpSender(
        // SKIP INSERT:         factory,
        // SKIP INSERT:         videoSender,
        // SKIP INSERT:         participant,
        // SKIP INSERT:         org.webrtc.FrameCryptorAlgorithm.AES_GCM,
        // SKIP INSERT:         keyProvider
        // SKIP INSERT:     )
        // SKIP INSERT:     attachObserver("video-sender", cryptor)
        // SKIP INSERT:     cryptor?.setEnabled(true)
        // SKIP INSERT:     this@AndroidRTCClient.videoSenderCryptor = cryptor
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Video sender cryptor attached")
        // SKIP INSERT: }

        // Audio sender encryptor
        // SKIP INSERT: this@AndroidRTCClient.audioSenderCryptor?.dispose()
        // SKIP INSERT: this@AndroidRTCClient.audioSenderCryptor = null
        // SKIP INSERT: if (audioSender != null) {
        // SKIP INSERT:     val cryptor = org.webrtc.FrameCryptorFactory.createFrameCryptorForRtpSender(
        // SKIP INSERT:         factory,
        // SKIP INSERT:         audioSender,
        // SKIP INSERT:         participant,
        // SKIP INSERT:         org.webrtc.FrameCryptorAlgorithm.AES_GCM,
        // SKIP INSERT:         keyProvider
        // SKIP INSERT:     )
        // SKIP INSERT:     attachObserver("audio-sender", cryptor)
        // SKIP INSERT:     cryptor?.setEnabled(true)
        // SKIP INSERT:     this@AndroidRTCClient.audioSenderCryptor = cryptor
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Audio sender cryptor attached")
        // SKIP INSERT: }
    }

    /// Attaches FrameCryptor decryptors to current RTP receivers (audio/video) on the active PeerConnection.
    func createReceiverEncryptedFrame(participant: String, connectionId: String, trackKind: String? = nil, trackId: String? = nil) async {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot create receiver encrypted frame: AndroidRTCClient has been closed")
            return
        }

        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: val pc = this@AndroidRTCClient.peerConnection?.platformPeerConnection
        // SKIP INSERT: val factory = this@AndroidRTCClient.factory
        // SKIP INSERT: if (keyProvider == null || pc == null || factory == null) {
        // SKIP INSERT:     android.util.Log.e("AndroidRTCClient", "KeyProvider, PeerConnection, or Factory not initialized")
        // SKIP INSERT:     return
        // SKIP INSERT: }
        // SKIP INSERT: val pcNonNull = pc!!
        // SKIP INSERT: val receivers = pcNonNull.receivers
        // SKIP INSERT: val videoReceiver = receivers.firstOrNull { it.track()?.kind() == "video" && (trackId == null || it.track()?.id() == trackId) }
        // SKIP INSERT: val audioReceiver = receivers.firstOrNull { it.track()?.kind() == "audio" && (trackId == null || it.track()?.id() == trackId) }

        // SKIP INSERT: fun attachObserver(tag: String, cryptor: org.webrtc.FrameCryptor?) {
        // SKIP INSERT:     cryptor?.setObserver(object : org.webrtc.FrameCryptor.Observer {
        // SKIP INSERT:         override fun onFrameCryptionStateChanged(participantId: String, newState: org.webrtc.FrameCryptor.FrameCryptionState) {
        // SKIP INSERT:             val stateDescription = when (newState) {
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.NEW -> "new"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.OK -> "ok"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.MISSINGKEY -> "missingKey"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.KEYRATCHETED -> "keyRatcheted"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.INTERNALERROR -> "internalError"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.ENCRYPTIONFAILED -> "encryptionFailed"
        // SKIP INSERT:                 org.webrtc.FrameCryptor.FrameCryptionState.DECRYPTIONFAILED -> "decryptionFailed"
        // SKIP INSERT:                 else -> "unknown(${newState.ordinal})"
        // SKIP INSERT:             }
        // SKIP INSERT:             val logLevel = if (newState == org.webrtc.FrameCryptor.FrameCryptionState.OK) android.util.Log.INFO else android.util.Log.WARN
        // SKIP INSERT:             android.util.Log.println(logLevel, "AndroidRTCClient", "[$tag] FrameCryptor state for '$participantId': $stateDescription")
        // SKIP INSERT:             if (newState == org.webrtc.FrameCryptor.FrameCryptionState.MISSINGKEY) {
        // SKIP INSERT:                 android.util.Log.e("AndroidRTCClient", "[$tag] ⚠️ Missing key for '$participantId'")
        // SKIP INSERT:             } else if (newState == org.webrtc.FrameCryptor.FrameCryptionState.INTERNALERROR) {
        // SKIP INSERT:                 android.util.Log.e("AndroidRTCClient", "[$tag] ❌ Internal error for '$participantId'")
        // SKIP INSERT:             }
        // SKIP INSERT:         }
        // SKIP INSERT:     })
        // SKIP INSERT: }

        // Video receiver decryptor (keep one per participant)
        // SKIP INSERT: if (videoReceiver != null) {
        // SKIP INSERT:     this@AndroidRTCClient.videoReceiverCryptorsByParticipantId[participant]?.dispose()
        // SKIP INSERT:     val cryptor = org.webrtc.FrameCryptorFactory.createFrameCryptorForRtpReceiver(
        // SKIP INSERT:         factory,
        // SKIP INSERT:         videoReceiver,
        // SKIP INSERT:         participant,
        // SKIP INSERT:         org.webrtc.FrameCryptorAlgorithm.AES_GCM,
        // SKIP INSERT:         keyProvider
        // SKIP INSERT:     )
        // SKIP INSERT:     attachObserver("video-receiver", cryptor)
        // SKIP INSERT:     cryptor?.setEnabled(true)
        // SKIP INSERT:     this@AndroidRTCClient.videoReceiverCryptorsByParticipantId[participant] = cryptor
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Video receiver cryptor attached")
        // SKIP INSERT: }

        // Audio receiver decryptor (keep one per participant)
        // SKIP INSERT: if (audioReceiver != null) {
        // SKIP INSERT:     this@AndroidRTCClient.audioReceiverCryptorsByParticipantId[participant]?.dispose()
        // SKIP INSERT:     val cryptor = org.webrtc.FrameCryptorFactory.createFrameCryptorForRtpReceiver(
        // SKIP INSERT:         factory,
        // SKIP INSERT:         audioReceiver,
        // SKIP INSERT:         participant,
        // SKIP INSERT:         org.webrtc.FrameCryptorAlgorithm.AES_GCM,
        // SKIP INSERT:         keyProvider
        // SKIP INSERT:     )
        // SKIP INSERT:     attachObserver("audio-receiver", cryptor)
        // SKIP INSERT:     cryptor?.setEnabled(true)
        // SKIP INSERT:     this@AndroidRTCClient.audioReceiverCryptorsByParticipantId[participant] = cryptor
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "✅ Audio receiver cryptor attached")
        // SKIP INSERT: }
    }

    /// Updates the current shared media key (manual re-key / ratchet advance).
    func ratchetAdvanced(with newKey: Data, index: Int, participant: String) {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot advance ratchet: AndroidRTCClient has been closed")
            return
        }

        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: if (keyProvider != null) {
        // SKIP INSERT:     val newKeySize = newKey.count
        // SKIP INSERT:     val newKeyBytesUInt8 = kotlin.UByteArray(newKeySize) { newKey.bytes[it] }
        // SKIP INSERT:     val keyBytes: ByteArray = kotlin.ByteArray(size = newKeyBytesUInt8.size) { idx -> newKeyBytesUInt8[idx].toByte() }
        // SKIP INSERT:     val success = keyProvider.setSharedKey(index, keyBytes)
        // SKIP INSERT:     if (success) {
        // SKIP INSERT:         android.util.Log.i("AndroidRTCClient", "🔑 Updated shared media key index $index")
        // SKIP INSERT:     } else {
        // SKIP INSERT:         android.util.Log.e("AndroidRTCClient", "❌ Failed to update shared media key index $index")
        // SKIP INSERT:     }
        // SKIP INSERT: } else {
        // SKIP INSERT:     android.util.Log.e("AndroidRTCClient", "KeyProvider not initialized before ratchetAdvanced()")
        // SKIP INSERT: }
    }
    
    /// Creates a new Android RTC client instance.
    ///
    /// The peer connection is not created until `initializeFactory(iceServers:username:password:)` is called.
    init() {}

    /// Ensures an EGL base exists before any renderer/capture initialization.
    private func ensureEglBase() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        if eglBase == nil {
            eglBase = org.webrtc.EglBase.create()
            if eglBase == nil {
                throw RTCClientErrors.peerConnectionError("Failed to create EGL base")
            }
        }
    }
    
    /// Creates (or returns) the `PeerConnectionFactory` for this client.
    ///
    /// If initialization fails (missing native library, linkage issues, etc.), this method records that
    /// failure so future calls fail fast with a clearer error.
    private func createFactory() throws -> org.webrtc.PeerConnectionFactory {
        lock.lock()
        let failed = initializationFailed
        lock.unlock()
        
        guard !failed else {
            throw RTCClientErrors.peerConnectionError("WebRTC initialization previously failed. Cannot create factory.")
        }
        
        // SKIP INSERT: try {
        // SKIP INSERT:   if (this@AndroidRTCClient.factory == null) {
        // SKIP INSERT:     // Check if initialization has already failed
        // SKIP INSERT:     if (this@AndroidRTCClient.initializationFailed) {
        // SKIP INSERT:       throw IllegalStateException("WebRTC initialization previously failed. Cannot create factory.")
        // SKIP INSERT:     }
        // SKIP INSERT:     
        // SKIP INSERT:     val ctx = ProcessInfo.processInfo.androidContext
        // SKIP INSERT:     val app = ctx?.applicationContext ?: throw IllegalStateException("Android context not available")
        // SKIP INSERT:     
        // SKIP INSERT:     val init = org.webrtc.PeerConnectionFactory.InitializationOptions
        // SKIP INSERT:       .builder(app)
        // SKIP INSERT:       .setEnableInternalTracer(false)
        // SKIP INSERT:       .setFieldTrials("WebRTC-H264HighProfile/Enabled/")
        // SKIP INSERT:       .createInitializationOptions()
        // SKIP INSERT:     try {
        // SKIP INSERT:       org.webrtc.PeerConnectionFactory.initialize(init)
        // SKIP INSERT:     } catch (e: java.lang.ClassNotFoundException) {
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "WebRTC native library not found: ${e.message}", e)
        // SKIP INSERT:       throw IllegalStateException("WebRTC native library missing. Check dependencies: ${e.message}", e)
        // SKIP INSERT:     } catch (e: java.lang.UnsatisfiedLinkError) {
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "WebRTC native library link error: ${e.message}", e)
        // SKIP INSERT:       throw IllegalStateException("WebRTC native library link failed: ${e.message}", e)
        // SKIP INSERT:     } catch (e: java.lang.Exception) {
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "Failed to initialize PeerConnectionFactory: ${e.javaClass.simpleName}: ${e.message}", e)
        // SKIP INSERT:       throw IllegalStateException("Failed to initialize WebRTC: ${e.message}", e)
        // SKIP INSERT:     }
        // SKIP INSERT:     
        // SKIP INSERT:     val egl = org.webrtc.EglBase.create() ?: throw IllegalStateException("Failed to create EGL base")
        // SKIP INSERT:     this@AndroidRTCClient.eglBase = egl
        // SKIP INSERT:
        // SKIP INSERT:     val enc = org.webrtc.DefaultVideoEncoderFactory(egl.eglBaseContext, true, true)
        // SKIP INSERT:     val dec = org.webrtc.DefaultVideoDecoderFactory(egl.eglBaseContext)
        // SKIP INSERT:     
        // SKIP INSERT:     val fac = org.webrtc.PeerConnectionFactory.builder()
        // SKIP INSERT:         .setVideoEncoderFactory(enc)
        // SKIP INSERT:         .setVideoDecoderFactory(dec)
        // SKIP INSERT:         .createPeerConnectionFactory()
        // SKIP INSERT:     this@AndroidRTCClient.factory = fac
        // SKIP INSERT:   }
        // SKIP INSERT:   return this@AndroidRTCClient.factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:   // Mark as failed if not already marked
        // SKIP INSERT:   if (!this@AndroidRTCClient.initializationFailed && e is IllegalStateException) {
        // SKIP INSERT:     this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:   }
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "Fatal error creating factory: ${e.javaClass.simpleName}: ${e.message}", e)
        // SKIP INSERT:   throw IllegalStateException("WebRTC initialization failed: ${e.message}", e)
        // SKIP INSERT: }
    }
    
    /// Creates an Android `PeerConnection` with Unified Plan semantics and continual ICE gathering.
    private func createPeerConnection(iceServers: [String], username: String? = nil, password: String? = nil) throws -> org.webrtc.PeerConnection? {
        // SKIP INSERT: try {
        // SKIP INSERT:   val factory = createFactory()
        // SKIP INSERT:   val servers = kotlin.collections.mutableListOf<org.webrtc.PeerConnection.IceServer>()
        // SKIP INSERT:   for (url in iceServers) {
        // SKIP INSERT:     val builder = org.webrtc.PeerConnection.IceServer.builder(url)
        // SKIP INSERT:     if (username != null && password != null) {
        // SKIP INSERT:       builder.setUsername(username)
        // SKIP INSERT:       builder.setPassword(password)
        // SKIP INSERT:     }
        // SKIP INSERT:     val server = builder.createIceServer()
        // SKIP INSERT:     servers.add(server)
        // SKIP INSERT:   }
        // SKIP INSERT:   val config = org.webrtc.PeerConnection.RTCConfiguration(servers)
        // SKIP INSERT:   config.sdpSemantics = org.webrtc.PeerConnection.SdpSemantics.UNIFIED_PLAN
        // SKIP INSERT:   config.enableDscp = true
        // SKIP INSERT:   config.continualGatheringPolicy = org.webrtc.PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        // SKIP INSERT:   val obs = RTCClientPeerObserver(this@AndroidRTCClient)
        // SKIP INSERT:   this@AndroidRTCClient.observer = obs
        // SKIP INSERT:   val pc = factory.createPeerConnection(config, obs)
        // SKIP INSERT:   this@AndroidRTCClient.factory = factory
        // SKIP INSERT:   return pc
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "Error creating peer connection", e)
        // SKIP INSERT:   return null
        // SKIP INSERT: }
    }
    
    /// Initializes the WebRTC stack and creates a peer connection.
    ///
    /// This must be called before creating tracks or generating offers/answers.
    ///
    /// - Parameters:
    ///   - iceServers: ICE server URLs.
    ///   - username: Optional ICE username.
    ///   - password: Optional ICE credential/password.
    /// - Returns: The underlying `org.webrtc.PeerConnection` instance.
    /// - Throws: `RTCClientErrors` if initialization fails or the client is closed.
    public func initializeFactory(iceServers: [String], username: String? = nil, password: String? = nil) throws -> org.webrtc.PeerConnection {
        lock.lock()
        let closed = isClosed
        let failed = initializationFailed
        lock.unlock()
        
        guard !closed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard !failed else {
            throw RTCClientErrors.peerConnectionError("WebRTC initialization previously failed. Cannot create peer connection. Check WebRTC dependencies.")
        }
        
        do {
            let pc = try createPeerConnection(iceServers: iceServers, username: username, password: password)
            
            guard let peerConnection = pc else {
                // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Failed to create PeerConnection - returned null")
                lock.lock()
                initializationFailed = true
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("Failed to create PeerConnection - factory returned nil")
            }
            
            lock.lock()
            self.peerConnection = RTCPeerConnection(peerConnection)
            lock.unlock()
            return peerConnection
        } catch {
            // Mark initialization as failed on any error
            lock.lock()
            initializationFailed = true
            lock.unlock()
            if let rtcError = error as? RTCClientErrors {
                throw rtcError
            }
            throw RTCClientErrors.peerConnectionError("Failed to initialize factory: \(error.localizedDescription)")
        }
    }
    
    
    /// Creates media constraints for WebRTC operations (offer/answer, audio, etc.).
    ///
    /// - Parameters:
    ///   - mandatory: Mandatory key/value pairs.
    ///   - optional: Optional key/value pairs.
    public func createConstraints(_ mandatory: [String: String] = [:], optional: [String: String] = [:]) -> RTCMediaConstraints {
        // SKIP INSERT: val c = org.webrtc.MediaConstraints()
        // SKIP INSERT: for ((k, v) in mandatory) { c.mandatory.add(org.webrtc.MediaConstraints.KeyValuePair(k, v)) }
        // SKIP INSERT: for ((k, v) in optional)  { c.optional.add(org.webrtc.MediaConstraints.KeyValuePair(k, v)) }
        // SKIP INSERT: return needle.tail.rtc.RTCMediaConstraints(c)
    }
    
    /// Creates and stores an audio source.
    ///
    /// - Parameter constraints: Platform constraints for the source.
    /// - Returns: The created audio source wrapper.
    @discardableResult
    public func createAudioSource(_ constraints: RTCMediaConstraints) -> RTCAudioSource {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val src = needle.tail.rtc.RTCAudioSource(fac.createAudioSource(constraints.platformConstraints))
        // SKIP INSERT: this.audioSource = src
        // SKIP INSERT: return src
    }
    
    /// Creates and stores a local audio track.
    ///
    /// - Parameters:
    ///   - id: An identifier used to label the track.
    ///   - audioSource: The audio source wrapper.
    /// - Returns: The created audio track wrapper.
    @discardableResult
    public func createAudioTrack(id: String, _ audioSource: RTCAudioSource) -> RTCAudioTrack {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val track = needle.tail.rtc.RTCAudioTrack(fac.createAudioTrack("audio_${id}", audioSource.platformSource))
        // SKIP INSERT: this.localAudioTrack = track
        // SKIP INSERT: return track
    }
    
    /// Creates and stores a video source.
    ///
    /// - Parameter isScreen: Whether the source is intended for screen capture.
    public func createVideoSource(_ isScreen: Bool = false) -> RTCVideoSource {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val src = needle.tail.rtc.RTCVideoSource(fac.createVideoSource(isScreen))
        // SKIP INSERT: this.videoSource = src
        // SKIP INSERT: return src
    }
    
    /// Creates and stores a local video track.
    ///
    /// - Parameters:
    ///   - id: An identifier used to label the track.
    ///   - videoSource: The video source wrapper.
    public func createVideoTrack(id: String, _ videoSource: RTCVideoSource) -> RTCVideoTrack {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val track = needle.tail.rtc.RTCVideoTrack(fac.createVideoTrack("video_${id}", videoSource.platformSource))
        // SKIP INSERT: this.localVideoTrack = track
        // SKIP INSERT: return track
    }
    
    /// Enables or disables the local audio track.
    public func setAudioEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        localAudioTrack?._setEnabled(enabled)
    }
    
    /// Enables or disables the local video track.
    public func setVideoEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        localVideoTrack?._setEnabled(enabled)
    }
    
    // MARK: - Public Video APIs (no org.webrtc exposure)
    /// Ensures a video transceiver exists and attaches a local video track for send/receive.
    ///
    /// This is used by `RTCSession` on Android to prepare video media before negotiation.
    ///
    /// - Parameters:
    ///   - id: An identifier used for stream/track labeling.
    ///   - useFrontCamera: Whether to prefer the front-facing camera when starting capture.
    /// - Returns: The local video track wrapper (if created).
    /// - Throws: `RTCClientErrors` if the peer connection is unavailable or the client is closed.
    public func prepareVideoSendRecv(id: String = UUID().uuidString, useFrontCamera: Bool = true) throws -> RTCVideoTrack? {
        // First, do all the setup work while holding the lock
        let trackToReturn: RTCVideoTrack?
        do {
            lock.lock()
            defer { lock.unlock() }
            
            guard !isClosed else {
                throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
            }
            
            guard let peerConnection = peerConnection?.platformPeerConnection else {
                throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
            }
            
            if videoSource == nil {
                _ = createVideoSource(false)
            }
            if localVideoTrack == nil, let videoSource {
                _ = createVideoTrack(id: id, videoSource)
            }
            
            // Ensure a video transceiver exists
            let transceivers = peerConnection.getTransceivers()
            let hasVideo = transceivers.firstOrNull { t in t.mediaType == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO } != nil
            if !hasVideo {
                let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
                peerConnection.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, initOpts)
            }
            
            if let track = localVideoTrack {
                var ids = [String]()
                ids.append("stream_\(id)")
                _ = peerConnection.addTrack(track.platformTrack, ids.toList())
            }
            
            trackToReturn = localVideoTrack
        }
        
        // Now call startLocalVideo (it will lock internally)
        do {
            try startLocalVideo(useFrontCamera: useFrontCamera)
        } catch {
            throw RTCClientErrors.peerConnectionError("Failed to start local video: \(error.localizedDescription)")
        }
        
        return trackToReturn
    }
    
    struct Format: Hashable, Sendable {
        let isLandscape: Bool
        let width: Int
        let height: Int
    }
    
    var formats = Set<Format>()
    
    /// Starts camera capture and feeds frames into the current local video source.
    ///
    /// - Parameters:
    ///   - fps: Target capture framerate.
    ///   - useFrontCamera: Whether to prefer the front-facing camera.
    /// - Throws: `RTCClientErrors` if capture cannot be started.
    public func startLocalVideo(fps: Int = 30, useFrontCamera: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let ctx = ProcessInfo.processInfo.androidContext else {
            throw RTCClientErrors.peerConnectionError("Android context not available")
        }
        
        guard let videoSource = videoSource else {
            throw RTCClientErrors.peerConnectionError("Video source not initialized")
        }
        
        // Ensure EGL base exists for SurfaceTextureHelper
        do {
            try ensureEglBase()
        } catch {
            throw RTCClientErrors.peerConnectionError("Failed to ensure EGL base: \(error.localizedDescription)")
        }
        
        // Dispose old helper if any
        surfaceTextureHelper?.dispose()
        
        guard let eglBase = eglBase else {
            throw RTCClientErrors.peerConnectionError("EGL base is nil after ensureEglBase")
        }
        
        surfaceTextureHelper = org.webrtc.SurfaceTextureHelper.create("WebRTCCapture", eglBase.eglBaseContext)
        
        guard let helper = surfaceTextureHelper else {
            throw RTCClientErrors.peerConnectionError("Failed to create SurfaceTextureHelper")
        }
        
        // Select camera
        let enumerator = org.webrtc.Camera2Enumerator(ctx)
        let deviceNames = enumerator.deviceNames
        var selectedName: String? = nil
        for name in deviceNames where (useFrontCamera ? enumerator.isFrontFacing(name) : enumerator.isBackFacing(name)) {
            selectedName = name
            break
        }
        if selectedName == nil, let first = deviceNames.firstOrNull() { selectedName = first }
        
        guard let cameraName = selectedName else {
            throw RTCClientErrors.peerConnectionError("No camera available")
        }
        
        // Initialize capturer
        let events = createCameraEventsHandler()
        let capturer = org.webrtc.Camera2Capturer(ctx, cameraName, events)
        
        let downstream = videoSource.platformSource.getCapturerObserver()
        let proxy = CapturerObserverProxy(downstream: downstream, normalizeToUpright: true)
        capturer.initialize(helper, ctx, proxy)
        
        guard let supportedFormats = enumerator.getSupportedFormats(cameraName) else {
            throw RTCClientErrors.peerConnectionError("No supported formats for camera: \(cameraName)")
        }
        
        for fmt in supportedFormats {
            formats.insert(Format(
                isLandscape: fmt.width > fmt.height ? true : false,
                width: fmt.width,
                height: fmt.height))
        }
        
        let available = Set(formats.map { ($0.width, $0.height) })
        let candidates = formats.filter { available.contains(($0.height, $0.width)) }
        
        if let largestLandscape = candidates.filter({ $0.isLandscape }).max(by: { $0.width * $0.height < $1.width * $1.height }) {
            capturer.startCapture(Int32(largestLandscape.width), Int32(largestLandscape.height), Int32(fps))
        } else if let largestPortrait = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            capturer.startCapture(Int32(largestPortrait.width), Int32(largestPortrait.height), Int32(fps))
        } else {
            throw RTCClientErrors.peerConnectionError("No suitable video format found")
        }
        
        videoCapturer = capturer
    }
    
    /// Stops camera capture and releases capture-related resources.
    public func stopLocalVideo() {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else { return }
        
        if let capturer = videoCapturer {
            capturer.stopCapture()
            videoCapturer = nil
        }
        surfaceTextureHelper?.dispose()
        surfaceTextureHelper = nil
    }
    
    /// Ensures a local video track exists, creating a source/track if needed.
    ///
    /// - Parameter id: An identifier used for the track label.
    /// - Returns: The local video track wrapper, or `nil` if the client is closed.
    public func ensureLocalVideoTrack(id: String = "default") -> RTCVideoTrack? {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else { return nil }
        
        // If we don't have a local video track, create one
        if localVideoTrack == nil {
            if videoSource == nil {
                _ = createVideoSource(false)
            }
            if let videoSource = videoSource {
                _ = createVideoTrack(id: id, videoSource)
            }
        }
        return localVideoTrack
    }
    
    // Helper to create CameraEventsHandler without exposing org.webrtc publicly
    private func createCameraEventsHandler() -> org.webrtc.CameraVideoCapturer.CameraEventsHandler {
        // SKIP INSERT: return object : org.webrtc.CameraVideoCapturer.CameraEventsHandler {
        // SKIP INSERT:     override fun onCameraError(error: String) {}
        // SKIP INSERT:     override fun onCameraDisconnected() {}
        // SKIP INSERT:     override fun onCameraFreezed(error: String) {}
        // SKIP INSERT:     override fun onCameraOpening(cameraName: String) {}
        // SKIP INSERT:     override fun onFirstFrameAvailable() {}
        // SKIP INSERT:     override fun onCameraClosed() {}
        // SKIP INSERT: }
    }
    
    // MARK: - Android Renderer Helpers (Unified Plan)
    /// Initializes an Android `SurfaceViewRenderer` with the client's EGL context.
    ///
    /// The renderer is tracked for cleanup in `close()`.
    ///
    /// - Parameters:
    ///   - renderer: The renderer to initialize.
    ///   - mirror: Whether to mirror frames (commonly used for local preview).
    /// - Throws: `RTCClientErrors` if EGL cannot be created or the client is closed.
    public func initializeSurfaceRenderer(_ renderer: org.webrtc.SurfaceViewRenderer, mirror: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        // Ensure EGL is available prior to renderer init
        do {
            try ensureEglBase()
        } catch {
            throw RTCClientErrors.peerConnectionError("Failed to ensure EGL base: \(error.localizedDescription)")
        }
        
        guard let eglBase = eglBase else {
            throw RTCClientErrors.peerConnectionError("EGL base is nil after ensureEglBase")
        }

        // Safely release any previous EGL state only if already initialized
        // This prevents "eglBase context null" errors on first init
        // SKIP INSERT: try {
        // SKIP INSERT:    renderer.clearImage()
        // SKIP INSERT: renderer.release()
        // SKIP INSERT: } catch (_: Throwable) {
        // SKIP INSERT:     // No-op: safe to ignore if renderer wasn't initialized yet
        // SKIP INSERT: }

        // SKIP INSERT: val egl = eglBase ?: throw IllegalStateException("EGL base not initialized")
        // SKIP INSERT: renderer.init(
        // SKIP INSERT: egl.eglBaseContext,
        // SKIP INSERT: object : org.webrtc.RendererCommon.RendererEvents {
        // SKIP INSERT: override fun onFirstFrameRendered() {
        // SKIP INSERT: android.util.Log.d("AndroidRTCClient", "Renderer first frame rendered")
        // SKIP INSERT: }

        // SKIP INSERT: override fun onFrameResolutionChanged(width: Int, height: Int, rotation: Int) {
        // SKIP INSERT: android.util.Log.d("AndroidRTCClient", "Renderer resolution: ${width}x${height}, rot=${rotation}")
        // SKIP INSERT: }
        // SKIP INSERT: }
        // SKIP INSERT: )

        // SKIP INSERT: // Basic visual configuration
        // SKIP INSERT: renderer.setMirror(mirror)
        // SKIP INSERT: renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL)

        // SKIP INSERT: // Track renderer for centralized cleanup
        // SKIP INSERT: activeSurfaceRenderers.insert(renderer)

        // SKIP INSERT: try {
        // SKIP INSERT:     if (renderer is CustomSurfaceViewRenderer) {
        // SKIP INSERT:         val ctx = ProcessInfo.processInfo.androidContext
        // SKIP INSERT:         val activity = ctx as? android.app.Activity
        // SKIP INSERT:         val rotation = activity?.windowManager?.defaultDisplay?.rotation ?: android.view.Surface.ROTATION_0
        // SKIP INSERT:         val degrees = when (rotation) {
        // SKIP INSERT:             android.view.Surface.ROTATION_0 -> 0
        // SKIP INSERT:             android.view.Surface.ROTATION_90 -> 90
        // SKIP INSERT:             android.view.Surface.ROTATION_180 -> 180
        // SKIP INSERT:             android.view.Surface.ROTATION_270 -> 270
        // SKIP INSERT:             else -> 0
        // SKIP INSERT:         }
        // SKIP INSERT:         renderer.setExtraRotation(degrees)
        // SKIP INSERT:     }
        // SKIP INSERT: } catch (_: Throwable) { }
    }

    
    /// Removes a renderer from internal tracking.
    ///
    /// This does not release the renderer; call `safeReleaseRenderer(_:)` if you also want to release.
    public func removeRenderer(_ renderer: org.webrtc.SurfaceViewRenderer) {
        lock.lock()
        defer { lock.unlock() }
        // Remove from tracking
        activeSurfaceRenderers.remove(renderer)
    }
    
    /// Safely releases a renderer, handling cases where the OpenGL context may already be destroyed.
    ///
    /// - Parameter renderer: The renderer to release.
    public func safeReleaseRenderer(_ renderer: org.webrtc.SurfaceViewRenderer) {
        lock.lock()
        defer { lock.unlock() }
        
        // SKIP INSERT: try {
        // SKIP INSERT:     // Check if EGL context is still valid before releasing
        // SKIP INSERT:     val egl = eglBase
        // SKIP INSERT:     if (egl != null && egl.eglBaseContext != null) {
        // SKIP INSERT:         renderer.release()
        // SKIP INSERT:     } else {
        // SKIP INSERT:         android.util.Log.w("AndroidRTCClient", "Skipping renderer release - EGL context already destroyed")
        // SKIP INSERT:     }
        // SKIP INSERT: } catch (e: java.lang.Exception) {
        // SKIP INSERT:     android.util.Log.w("AndroidRTCClient", "Error releasing renderer (context may be destroyed): ${e.message}")
        // SKIP INSERT: }
    }
    
    /// Attempts to fetch the first remote video track from the provided peer connection.
    ///
    /// This uses transceivers (Unified Plan) and returns the receiver's track if present.
    public func getRemoteVideoTrack(peerConnection: RTCPeerConnection) -> RTCVideoTrack? {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else { return nil }
        
        guard
            let pc = peerConnection.platformPeerConnection,
            let transceiver = pc.getTransceivers().firstOrNull({ t in
                t.mediaType == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO
            }),
            let videoTrack = transceiver.getReceiver()?.track() as? org.webrtc.VideoTrack
        else { return nil }
        return RTCVideoTrack(videoTrack)
    }
   
    /// Ensures an audio transceiver is present with `SEND_RECV` and attaches a local audio track.
    ///
    /// This is used by `RTCSession` on Android to prepare audio media before negotiation.
    ///
    /// - Parameter id: An identifier used for stream/track labeling.
    public func prepareAudioSendRecv(id: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isClosed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let peerConnection = peerConnection?.platformPeerConnection else {
            throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
        }
        
        if audioSource == nil {
            _ = createAudioSource(createConstraints())
        }
        if localAudioTrack == nil, let audioSource {
            _ = createAudioTrack(id: id, audioSource)
        }
        
        // Add a transceiver if there isn't already one for audio
        let transceivers = peerConnection.getTransceivers()
        let hasAudio = transceivers.firstOrNull { t in t.mediaType == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO } != nil
        if !hasAudio {
            let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
            peerConnection.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO, initOpts)
        }
        
        if let track = localAudioTrack {
            var ids = [String]()
            ids.append("stream_\(id)")
            _ = peerConnection.addTrack(track.platformTrack, ids.toList())
        }
    }
    
    private func createOffer(constraints: RTCMediaConstraints, completion: @escaping OnLocalSDP) throws {
        lock.lock()
        let isClosedCheck = isClosed
        let pc = peerConnection?.platformPeerConnection
        lock.unlock()
        
        guard !isClosedCheck else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let peerConnection = pc else {
            throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
        }
        
        let obs = RTCOnCreateSdpObserver { [weak self] sdp in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.pendingOfferObserver = nil
            completion(sdp)
        }
        
        lock.lock()
        pendingOfferObserver = obs
        lock.unlock()
        
        peerConnection.createOffer(obs, constraints.platformConstraints)
    }
    
    private func createAnswer(constraints: RTCMediaConstraints, completion: @escaping OnLocalSDP) throws {
        lock.lock()
        let isClosedCheck = isClosed
        let pc = peerConnection?.platformPeerConnection
        lock.unlock()
        
        guard !isClosedCheck else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let peerConnection = pc else {
            throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
        }
        
        let obs = RTCOnCreateSdpObserver { [weak self] sdp in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            completion(sdp)
            self.pendingAnswerObserver = nil
        }
        
        lock.lock()
        pendingAnswerObserver = obs
        lock.unlock()
        
        peerConnection.createAnswer(obs, constraints.platformConstraints)
    }
    
    private func setLocalDescription(_ sdp: RTCSessionDescription, completion: (() -> Void)? = nil) throws {
        lock.lock()
        let isClosedCheck = isClosed
        let pc = peerConnection?.platformPeerConnection
        lock.unlock()
        
        guard !isClosedCheck else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let peerConnection = pc else {
            throw RTCClientErrors.peerConnectionError("PeerConnection has not been initialized")
        }
        
        let obs = RTCOnSetObserver { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            completion?()
            self.pendingSetLocalObserver = nil
        }
        
        lock.lock()
        pendingSetLocalObserver = obs
        lock.unlock()
        
        peerConnection.setLocalDescription(obs, sdp.platform)
    }
    
    private func setRemoteDescription(_ sdp: RTCSessionDescription, completion: (() -> Void)? = nil) throws {
        lock.lock()
        let isClosedCheck = isClosed
        let pc = peerConnection?.platformPeerConnection
        lock.unlock()
        
        guard !isClosedCheck else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let peerConnection = pc else {
            throw RTCClientErrors.peerConnectionError("PeerConnection has not been initialized")
        }
        
        let obs = RTCOnSetObserver { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            completion?()
            self.pendingSetRemoteObserver = nil
        }
        
        lock.lock()
        pendingSetRemoteObserver = obs
        lock.unlock()
        
        peerConnection.setRemoteDescription(obs, sdp.platform)
    }
    
    /// Adds an ICE candidate to the underlying peer connection.
    ///
    /// - Parameter candidate: The candidate to add.
    /// - Throws: `RTCClientErrors` if the peer connection is unavailable or the client is closed.
    public func addIceCandidate(_ candidate: RTCIceCandidate) throws {
        lock.lock()
        let isClosedCheck = isClosed
        let pc = peerConnection?.platformPeerConnection
        lock.unlock()
        
        guard !isClosedCheck else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let peerConnection = pc else {
            throw RTCClientErrors.peerConnectionError("PeerConnection has not been initialized")
        }
        _ = peerConnection.addIceCandidate(candidate.platform)
    }
    
    // MARK: - Public Offer/Answer Creation
    /// Creates a local SDP offer.
    public func createOffer(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            try self.createOffer(constraints: constraints) {
                sdp in continuation.resume(returning: sdp)
            }
        }
    }
    
    /// Creates a local SDP answer.
    public func createAnswer(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            try self.createAnswer(constraints: constraints) {
                sdp in continuation.resume(returning: sdp)
            }
        }
    }
    
    /// Sets the peer connection's local description.
    public func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            try self.setLocalDescription(sdp) {
                continuation.resume(returning: ())
            }
        }
    }
    
    /// Sets the peer connection's remote description.
    public func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            try self.setRemoteDescription(sdp) {
                continuation.resume(returning: ())
            }
        }
    }
    
    /// Closes the peer connection and releases all WebRTC resources owned by this client.
    ///
    /// This method is idempotent; repeated calls are no-ops.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        
        // Prevent double cleanup
        guard !isClosed else { return }
        isClosed = true
        
        // Clear delegate to prevent callbacks during cleanup
        delegate = nil
        
        // Stop and dispose camera capturer
        if let capturer = videoCapturer {
            capturer.stopCapture()
            videoCapturer = nil
        }
        
        // Dispose surface texture helper
        surfaceTextureHelper?.dispose()
        surfaceTextureHelper = nil
        
        // Detach video tracks from renderers first, then release renderers
        // This ensures no video frames are being sent to renderers during cleanup
        if let videoTrack = localVideoTrack {
            for renderer in activeSurfaceRenderers {
                videoTrack.platformTrack.removeSink(renderer)
            }
        }
        
        // Also detach any remote video tracks that might be attached
        // Note: Remote tracks are typically managed by the session, but we ensure cleanup here
        
        // Release all active surface renderers to stop OpenGL rendering
        // Use safe release to handle cases where OpenGL context may already be destroyed
        for renderer in activeSurfaceRenderers {
            safeReleaseRenderer(renderer)
        }
        activeSurfaceRenderers.removeAll()
        
        // Clear pending observers
        pendingOfferObserver = nil
        pendingAnswerObserver = nil
        pendingSetLocalObserver = nil
        pendingSetRemoteObserver = nil
        observer = nil
        
        // Close peer connection and release tracks/sources
        // Use optional chaining to safely handle nil cases
        if let pc = peerConnection?.platformPeerConnection {
            pc.close()
            pc.dispose()
        }
        
        localVideoTrack?.dispose()
        localAudioTrack?.dispose()
        videoSource?.dispose()
        audioSource?.dispose()
        eglBase?.release()
        factory?.dispose()
        
        // Clean up E2EE resources
        videoSenderCryptor?.dispose()
        audioSenderCryptor?.dispose()
        videoReceiverCryptor?.dispose()
        audioReceiverCryptor?.dispose()

        for (_, cryptor) in videoReceiverCryptorsByParticipantId {
            cryptor.dispose()
        }
        for (_, cryptor) in audioReceiverCryptorsByParticipantId {
            cryptor.dispose()
        }
        videoReceiverCryptorsByParticipantId.removeAll()
        audioReceiverCryptorsByParticipantId.removeAll()

        keyProvider = nil
        keyProviderIsSharedKeyMode = nil
        pendingPerParticipantKeys.removeAll()
        
        // Clear all references
        peerConnection = nil
        localVideoTrack = nil
        localAudioTrack = nil
        videoSource = nil
        audioSource = nil
        eglBase = nil
        factory = nil
        videoSenderCryptor = nil
        audioSenderCryptor = nil
        videoReceiverCryptor = nil
        audioReceiverCryptor = nil
    }
}

/// Platform-neutral wrapper around an Android WebRTC `VideoTrack`.
public final class RTCVideoTrack: @unchecked Sendable, Equatable {
    public let platformTrack: org.webrtc.VideoTrack
    
    public init(_ platformTrack: org.webrtc.VideoTrack) {
        self.platformTrack = platformTrack
    }
    
    /// Gets/sets whether the underlying track is enabled.
    public var _isEnabled: Bool {
        get {
            return platformTrack.enabled()
        }
        set {
            platformTrack.setEnabled(newValue)
        }
    }
    
    /// The track identifier.
    public var trackId: String {
        return platformTrack.id()
    }
    
    /// Sets whether the track is enabled.
    public func _setEnabled(_ enabled: Bool) {
        // SKIP INSERT: platformTrack.setEnabled(enabled)
    }
    
    /// Releases platform resources for this track.
    public func dispose() {
        platformTrack.dispose()
    }
}

/// Platform-neutral wrapper around an Android WebRTC `AudioTrack`.
public final class RTCAudioTrack: @unchecked Sendable {
    public let platformTrack: org.webrtc.AudioTrack
    
    public init(_ platformTrack: org.webrtc.AudioTrack) {
        self.platformTrack = platformTrack
    }
    
    /// The track identifier.
    public var trackId: String {
        return platformTrack.id()
    }
    
    /// Sets whether the track is enabled.
    public func _setEnabled(_ enabled: Bool) {
        // SKIP INSERT: platformTrack.setEnabled(enabled)
    }
    
    /// Releases platform resources for this track.
    public func dispose() {
        platformTrack.dispose()
    }
    
    /// Gets/sets whether the underlying track is enabled.
    public var _isEnabled: Bool {
        get {
            return platformTrack.enabled()
        }
        set {
            platformTrack.setEnabled(newValue)
        }
    }
}

/// Platform-neutral wrapper around an Android WebRTC `VideoSource`.
public struct RTCVideoSource: Sendable {
    public let platformSource: org.webrtc.VideoSource
    
    public init(_ platformSource: org.webrtc.VideoSource) {
        self.platformSource = platformSource
    }
    
    /// Releases platform resources for this source.
    mutating public func dispose() {
        platformSource.dispose()
    }
}

/// Platform-neutral wrapper around an Android WebRTC `AudioSource`.
public struct RTCAudioSource: Sendable {
    public let platformSource: org.webrtc.AudioSource
    
    public init(_ platformSource: org.webrtc.AudioSource) {
        self.platformSource = platformSource
    }
    
    /// Releases platform resources for this source.
    mutating public func dispose() {
        platformSource.dispose()
    }
}

/// Platform-neutral wrapper around Android WebRTC `MediaConstraints`.
public struct RTCMediaConstraints: Sendable{
    public let platformConstraints: org.webrtc.MediaConstraints
    
    public init(_ platformConstraints: org.webrtc.MediaConstraints) {
        self.platformConstraints = platformConstraints
    }
}

/// Platform-neutral wrapper around an Android WebRTC `PeerConnection`.
public final class RTCPeerConnection: @unchecked Sendable {
    public let platformPeerConnection: org.webrtc.PeerConnection?
    
    public init(_ platformPeerConnection: org.webrtc.PeerConnection?) {
        self.platformPeerConnection = platformPeerConnection
    }
}
#endif
