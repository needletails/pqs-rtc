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

// SKIP INSERT: // Subtle luma smoothing for outgoing camera frames ("soften appearance", Zoom-style).
// SKIP INSERT: // Blur is weighted per pixel by a skin-tone likelihood computed from chroma (Cb/Cr
// SKIP INSERT: // ellipse). Pure function of color: temporally stable, no segmentation flutter. Hair,
// SKIP INSERT: // eyes, clothing, and background keep their sharpness.
// SKIP INSERT: private class VideoAppearanceFrameSoftening {
// SKIP INSERT:     private val blurWeight = 45
// SKIP INSERT:     private var luma = ByteArray(0)
// SKIP INSERT:     private var blurTmp = ByteArray(0)
// SKIP INSERT:     private var rowBuf = ByteArray(0)
// SKIP INSERT:     private var chromaU = ByteArray(0)
// SKIP INSERT:     private var chromaV = ByteArray(0)
// SKIP INSERT:     private var skinWeight = ByteArray(0)
// SKIP INSERT:     // Returns a new frame whose buffer the caller must release after delivery, or null on failure.
// SKIP INSERT:     fun soften(frame: org.webrtc.VideoFrame): org.webrtc.VideoFrame? {
// SKIP INSERT:         val src = frame.buffer.toI420() ?: return null
// SKIP INSERT:         val w = src.width
// SKIP INSERT:         val h = src.height
// SKIP INSERT:         val cw = (w + 1) / 2
// SKIP INSERT:         val ch = (h + 1) / 2
// SKIP INSERT:         val dst = org.webrtc.JavaI420Buffer.allocate(w, h)
// SKIP INSERT:         computeSkinWeights(src.dataU, src.strideU, src.dataV, src.strideV, cw, ch)
// SKIP INSERT:         softenYPlane(src.dataY, src.strideY, dst.dataY, dst.strideY, w, h, cw)
// SKIP INSERT:         copyPlane(src.dataU, src.strideU, dst.dataU, dst.strideU, cw, ch)
// SKIP INSERT:         copyPlane(src.dataV, src.strideV, dst.dataV, dst.strideV, cw, ch)
// SKIP INSERT:         src.release()
// SKIP INSERT:         return org.webrtc.VideoFrame(dst, frame.rotation, frame.timestampNs)
// SKIP INSERT:     }
// SKIP INSERT:     // One weight per chroma sample (2x2 luma block), 0..blurWeight. Skin chroma ellipse:
// SKIP INSERT:     // Cb ~102±25, Cr ~153±20; soft falloff between core (dist<=0.7) and edge (dist>=1.6).
// SKIP INSERT:     private fun computeSkinWeights(
// SKIP INSERT:         u: java.nio.ByteBuffer,
// SKIP INSERT:         uStride: Int,
// SKIP INSERT:         v: java.nio.ByteBuffer,
// SKIP INSERT:         vStride: Int,
// SKIP INSERT:         cw: Int,
// SKIP INSERT:         ch: Int
// SKIP INSERT:     ) {
// SKIP INSERT:         val n = cw * ch
// SKIP INSERT:         if (chromaU.size < n) {
// SKIP INSERT:             chromaU = ByteArray(n)
// SKIP INSERT:             chromaV = ByteArray(n)
// SKIP INSERT:             skinWeight = ByteArray(n)
// SKIP INSERT:         }
// SKIP INSERT:         val us = u.duplicate()
// SKIP INSERT:         val vs = v.duplicate()
// SKIP INSERT:         for (row in 0 until ch) {
// SKIP INSERT:             us.position(row * uStride)
// SKIP INSERT:             us.get(chromaU, row * cw, cw)
// SKIP INSERT:             vs.position(row * vStride)
// SKIP INSERT:             vs.get(chromaV, row * cw, cw)
// SKIP INSERT:         }
// SKIP INSERT:         for (i in 0 until n) {
// SKIP INSERT:             val cb = chromaU[i].toInt() and 0xFF
// SKIP INSERT:             val cr = chromaV[i].toInt() and 0xFF
// SKIP INSERT:             val dcb = cb - 102
// SKIP INSERT:             val dcr = cr - 153
// SKIP INSERT:             // Ellipse distance scaled x100 (100 == boundary); integer math only.
// SKIP INSERT:             val dist = (dcb * dcb * 100) / 625 + (dcr * dcr * 100) / 400
// SKIP INSERT:             val wgt = when {
// SKIP INSERT:                 dist >= 160 -> 0
// SKIP INSERT:                 dist <= 70 -> blurWeight
// SKIP INSERT:                 else -> (blurWeight * (160 - dist)) / 90
// SKIP INSERT:             }
// SKIP INSERT:             skinWeight[i] = wgt.toByte()
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT:     private fun copyPlane(
// SKIP INSERT:         src: java.nio.ByteBuffer,
// SKIP INSERT:         srcStride: Int,
// SKIP INSERT:         dst: java.nio.ByteBuffer,
// SKIP INSERT:         dstStride: Int,
// SKIP INSERT:         width: Int,
// SKIP INSERT:         height: Int
// SKIP INSERT:     ) {
// SKIP INSERT:         val s = src.duplicate()
// SKIP INSERT:         val d = dst.duplicate()
// SKIP INSERT:         if (rowBuf.size < width) { rowBuf = ByteArray(width) }
// SKIP INSERT:         for (row in 0 until height) {
// SKIP INSERT:             s.position(row * srcStride)
// SKIP INSERT:             s.get(rowBuf, 0, width)
// SKIP INSERT:             d.position(row * dstStride)
// SKIP INSERT:             d.put(rowBuf, 0, width)
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT:     private fun softenYPlane(
// SKIP INSERT:         src: java.nio.ByteBuffer,
// SKIP INSERT:         srcStride: Int,
// SKIP INSERT:         dst: java.nio.ByteBuffer,
// SKIP INSERT:         dstStride: Int,
// SKIP INSERT:         width: Int,
// SKIP INSERT:         height: Int,
// SKIP INSERT:         chromaWidth: Int
// SKIP INSERT:     ) {
// SKIP INSERT:         val n = width * height
// SKIP INSERT:         if (luma.size < n) {
// SKIP INSERT:             luma = ByteArray(n)
// SKIP INSERT:             blurTmp = ByteArray(n)
// SKIP INSERT:         }
// SKIP INSERT:         val s = src.duplicate()
// SKIP INSERT:         for (row in 0 until height) {
// SKIP INSERT:             s.position(row * srcStride)
// SKIP INSERT:             s.get(luma, row * width, width)
// SKIP INSERT:         }
// SKIP INSERT:         // Horizontal 5-tap pass: luma -> blurTmp
// SKIP INSERT:         for (row in 0 until height) {
// SKIP INSERT:             val base = row * width
// SKIP INSERT:             for (x in 0 until width) {
// SKIP INSERT:                 var sum = 0
// SKIP INSERT:                 for (dx in -2..2) {
// SKIP INSERT:                     var nx = x + dx
// SKIP INSERT:                     if (nx < 0) nx = 0
// SKIP INSERT:                     if (nx > width - 1) nx = width - 1
// SKIP INSERT:                     sum += luma[base + nx].toInt() and 0xFF
// SKIP INSERT:                 }
// SKIP INSERT:                 blurTmp[base + x] = (sum / 5).toByte()
// SKIP INSERT:             }
// SKIP INSERT:         }
// SKIP INSERT:         // Vertical 5-tap pass + skin-weighted blend, written back into luma in place.
// SKIP INSERT:         // Safe: each pixel's original value is read before being overwritten, and the
// SKIP INSERT:         // vertical pass only reads neighbors from blurTmp.
// SKIP INSERT:         for (row in 0 until height) {
// SKIP INSERT:             val base = row * width
// SKIP INSERT:             val chromaRowBase = (row / 2) * chromaWidth
// SKIP INSERT:             for (x in 0 until width) {
// SKIP INSERT:                 val mask = skinWeight[chromaRowBase + (x / 2)].toInt()
// SKIP INSERT:                 if (mask <= 0) { continue }
// SKIP INSERT:                 var sum = 0
// SKIP INSERT:                 for (dy in -2..2) {
// SKIP INSERT:                     var ny = row + dy
// SKIP INSERT:                     if (ny < 0) ny = 0
// SKIP INSERT:                     if (ny > height - 1) ny = height - 1
// SKIP INSERT:                     sum += blurTmp[ny * width + x].toInt() and 0xFF
// SKIP INSERT:                 }
// SKIP INSERT:                 val blurred = sum / 5
// SKIP INSERT:                 val original = luma[base + x].toInt() and 0xFF
// SKIP INSERT:                 luma[base + x] = ((original * (100 - mask) + blurred * mask) / 100).toByte()
// SKIP INSERT:             }
// SKIP INSERT:         }
// SKIP INSERT:         val d = dst.duplicate()
// SKIP INSERT:         for (row in 0 until height) {
// SKIP INSERT:             d.position(row * dstStride)
// SKIP INSERT:             d.put(luma, row * width, width)
// SKIP INSERT:         }
// SKIP INSERT:     }
// SKIP INSERT: }
// SKIP INSERT: // Capturer observer that normalizes orientation (rotation=0) without resizing.
// SKIP INSERT: // Appearance softening reads a cached Kotlin preference snapshot (not per-frame Swift).
// SKIP INSERT: class CapturerObserverProxy(
// SKIP INSERT:     private val downstream: org.webrtc.CapturerObserver,
// SKIP INSERT:     private val normalizeToUpright: Boolean = true,
// SKIP INSERT:     private val allowAppearanceSoftening: Boolean = true
// SKIP INSERT: ) : org.webrtc.CapturerObserver {
// SKIP INSERT:     private val softening = VideoAppearanceFrameSoftening()
// SKIP INSERT:     override fun onCapturerStarted(success: Boolean) = downstream.onCapturerStarted(success)
// SKIP INSERT:     override fun onCapturerStopped() = downstream.onCapturerStopped()
// SKIP INSERT:     private fun deliverFrame(frame: org.webrtc.VideoFrame) {
// SKIP INSERT:         if (!allowAppearanceSoftening || !AndroidCaptureUIPreferenceCache.isVideoAppearanceSofteningEnabled()) {
// SKIP INSERT:             downstream.onFrameCaptured(frame)
// SKIP INSERT:             return
// SKIP INSERT:         }
// SKIP INSERT:         val softened = softening.soften(frame)
// SKIP INSERT:         if (softened == null) {
// SKIP INSERT:             downstream.onFrameCaptured(frame)
// SKIP INSERT:             return
// SKIP INSERT:         }
// SKIP INSERT:         downstream.onFrameCaptured(softened)
// SKIP INSERT:         softened.release()
// SKIP INSERT:     }
// SKIP INSERT:     override fun onFrameCaptured(frame: org.webrtc.VideoFrame) {
// SKIP INSERT:         val rot = frame.rotation
// SKIP INSERT:         if (!normalizeToUpright || rot == 0) {
// SKIP INSERT:             deliverFrame(frame)
// SKIP INSERT:             return
// SKIP INSERT:         }
// SKIP INSERT:         val src = frame.buffer.toI420() ?: run {
// SKIP INSERT:             deliverFrame(frame); return
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
// SKIP INSERT:         deliverFrame(rotatedFrame)
// SKIP INSERT:         dst.release() // creator-owned ref; downstream retains internally during onFrameCaptured
// SKIP INSERT:     }
// SKIP INSERT: }

// SKIP INSERT: class ScreenCaptureLifecycleObserver(
// SKIP INSERT:     private val downstream: org.webrtc.CapturerObserver,
// SKIP INSERT:     private val onStarted: (Boolean) -> Unit,
// SKIP INSERT:     private val onProjectionStopped: () -> Unit
// SKIP INSERT: ) : org.webrtc.CapturerObserver {
// SKIP INSERT:     override fun onCapturerStarted(success: Boolean) {
// SKIP INSERT:         onStarted(success)
// SKIP INSERT:         downstream.onCapturerStarted(success)
// SKIP INSERT:     }
// SKIP INSERT:     override fun onCapturerStopped() {
// SKIP INSERT:         downstream.onCapturerStopped()
// SKIP INSERT:     }
// SKIP INSERT:     override fun onFrameCaptured(frame: org.webrtc.VideoFrame) {
// SKIP INSERT:         downstream.onFrameCaptured(frame)
// SKIP INSERT:     }
// SKIP INSERT:     fun notifyProjectionStopped() {
// SKIP INSERT:         onProjectionStopped()
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
/// The observer is retained by `AndroidRTCClient` until either set callback fires.
private final class RTCOnSetObserver: NSObject, org.webrtc.SdpObserver, @unchecked Sendable {
    
    private let lock = NSLock()
    /// `nil` indicates success; a non-nil string is the WebRTC set-description failure message.
    private let callback: (String?) -> Void
    init(_ callback: @escaping (String?) -> Void) { self.callback = callback }
    
    override func onSetSuccess() {
        lock.lock()
        defer {
            lock.unlock()
        }
        callback(nil)
    }
    
    override func onCreateSuccess(_ desc: org.webrtc.SessionDescription?) {}
    override func onCreateFailure(_ error: String?) {}
    override func onSetFailure(_ error: String?) {
        lock.lock()
        defer {
            lock.unlock()
        }
        callback(error ?? "set description failed")
    }
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

/// Aggregate inbound remote video counters read from `PeerConnection.getStats`.
/* SKIP @bridge */ public struct AndroidInboundVideoCounters: Sendable {
    public let packetsReceived: Int64
    public let framesDecoded: Int64

    public init(packetsReceived: Int64, framesDecoded: Int64) {
        self.packetsReceived = packetsReceived
        self.framesDecoded = framesDecoded
    }
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
    private typealias OnLocalSDP = @Sendable (RTCSessionDescription) -> Void
    
    // Thread safety
    private let lock = NSLock()
    private var isClosed = false
    private var initializationFailed = false // Track if WebRTC initialization has failed
    
    /// Retained Android `PeerConnection.Observer` bridge instance.
    private var observer: Any? // SKIP INSERT: RTCClientPeerObserver?
    
    private weak var delegate: AndroidPeerConnectionDelegate?
   
    /// Sets callbacks for Android MediaProjection lifecycle events.
    public func setScreenCaptureLifecycleHandlers(
        onCaptureStarted: (@Sendable (Bool) -> Void)?,
        onProjectionStopped: (@Sendable () -> Void)?
    ) {
        lock.lock()
        screenCaptureStartedHandler = onCaptureStarted
        screenProjectionStoppedHandler = onProjectionStopped
        lock.unlock()
    }

    public func clearScreenCaptureLifecycleHandlers() {
        lock.lock()
        screenCaptureStartedHandler = nil
        screenProjectionStoppedHandler = nil
        screenCaptureLifecycleObserver = nil
        lock.unlock()
    }

    /// Invoked when a remote video FrameCryptor reaches the OK state so tiles can rebind once
    /// decryption is actually ready.
    public func setVideoReceiverFrameCryptorReadyHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        videoReceiverFrameCryptorReadyHandler = handler
        lock.unlock()
        frameCryptorSupport.videoReceiverFrameCryptorReadyHandler = { [weak self] participantId in
            self?.dispatchVideoReceiverFrameCryptorReady(participantId)
        }
    }

    private func dispatchVideoReceiverFrameCryptorReady(_ participantId: String) {
        lock.lock()
        let handler = videoReceiverFrameCryptorReadyHandler
        lock.unlock()
        handler?(participantId)
    }

    private func dispatchScreenCaptureStarted(_ success: Bool) {
        lock.lock()
        let handler = screenCaptureStartedHandler
        lock.unlock()
        handler?(success)
    }

    private func dispatchScreenProjectionStopped() {
        lock.lock()
        let handler = screenProjectionStoppedHandler
        lock.unlock()
        handler?()
    }

    /// Sets the delegate that receives `ClientPCEvent` notifications.
    public func setEventDelegate(_ delegate: AndroidPeerConnectionDelegate?) {
        lock.lock()
        defer { lock.unlock() }
        self.delegate = delegate
    }
    
    /// Delivers a WebRTC event to the delegate, if the client is not closed.
    public func triggerRTCEvent(_ event: ClientPCEvent) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        let delegate = delegate
        lock.unlock()
        guard let delegate else { return }
        switch event {
        case .candidate(let candidate):
            delegate.handleIceCandidateEvent(candidate)
        case .videoTrack(let videoTrack):
            delegate.handleRemoteVideoTrackEvent(videoTrack)
        case .audioTrack(let audioTrack):
            delegate.handleRemoteAudioTrackEvent(audioTrack)
        case .signalingStateChange(let stateDesc):
            delegate.handleSignalingStateChangeEvent(stateDesc)
        case .iceConnectionStateChange(let stateDesc):
            delegate.handleIceConnectionStateChangeEvent(stateDesc)
        case .standardizedIceConnectionStateChange(let stateDesc):
            delegate.handleStandardizedIceConnectionStateChangeEvent(stateDesc)
        case .peerConnectionStateChange(let stateDesc):
            delegate.handlePeerConnectionStateChangeEvent(stateDesc)
        case .iceConnectionReceivingChange(let receiving):
            delegate.handleIceConnectionReceivingChangeEvent(receiving)
        case .iceGatheringStateChange(let stateDesc):
            delegate.handleIceGatheringStateChangeEvent(stateDesc)
        case .iceCandidatesRemoved(let count):
            delegate.handleIceCandidatesRemovedEvent(count)
        case .addStream(let streamId):
            delegate.handleAddStreamEvent(streamId)
        case .removeStream(let streamId):
            delegate.handleRemoveStreamEvent(streamId)
        case .dataChannel(let label):
            delegate.handleDataChannelEvent(label)
        case .shouldNegotiate:
            delegate.handleShouldNegotiateEvent()
        case .addTrack(let trackKind):
            delegate.handleAddTrackEvent(trackKind)
        case .removeTrack(let trackKind):
            delegate.handleRemoveTrackEvent(trackKind)
        }
    }
    
    /// Returns whether frame-cryptor key provider has been initialized.
    ///
    /// On Android this can lag media track creation; callers should gate cryptor attachment
    /// on this state and retry after key provisioning.
    public func isFrameKeyProviderReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && !frameCryptorUnavailable && keyProviderReady
    }
    
    // Retain SDP observers until their callbacks fire (avoid premature disposal)
    private var pendingOfferObserver: RTCOnCreateSdpObserver?
    private var pendingAnswerObserver: RTCOnCreateSdpObserver?
    private var pendingSetLocalObserver: RTCOnSetObserver?
    private var pendingSetRemoteObserver: RTCOnSetObserver?
    
    private var iceServers = [String]()
    private var factory: org.webrtc.PeerConnectionFactory?
    /// The current peer connection wrapper, if initialized.
    private var peerConnection: RTCPeerConnection?
    private var eglBase: org.webrtc.EglBase?
    private var videoSource: RTCVideoSource?
    private var audioSource: RTCAudioSource?
    private var localAudioTrack: RTCAudioTrack?
    /// The current local video track wrapper, if created.
    private var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: org.webrtc.Camera2Capturer?
    private var localVideoCaptureStartInFlight = false
    private var surfaceTextureHelper: org.webrtc.SurfaceTextureHelper?

    // Screen capture fields (coexist alongside camera)
    private var screenVideoSource: RTCVideoSource?
    private var screenVideoTrack: RTCVideoTrack?
    private var screenCapturer: org.webrtc.VideoCapturer?
    private var screenSurfaceTextureHelper: org.webrtc.SurfaceTextureHelper?
    private var screenCaptureLifecycleObserver: Any?
    private var screenCaptureStartedHandler: (@Sendable (Bool) -> Void)?
    private var screenProjectionStoppedHandler: (@Sendable () -> Void)?
    private var videoReceiverFrameCryptorReadyHandler: (@Sendable (String) -> Void)?
    
    // Track active surface renderers for proper cleanup
    private var activeSurfaceRenderers: Set<org.webrtc.SurfaceViewRenderer> = []
    
    // MARK: E2EE
    private var keyProvider: org.webrtc.FrameCryptorKeyProvider?
    private var keyProviderIsSharedKeyMode: Bool?
    private let frameCryptorSupport: AndroidFrameCryptorSupport = AndroidFrameCryptorSupport()
    /// Swift-only: true when keyProvider has been set (by Kotlin). Use this instead of reading keyProvider in Swift to avoid triggering JNI method resolution (setKey/setSharedKey) which crashes.
    private var keyProviderReady: Bool = false
    /// Set after Android WebRTC reports that FrameCryptor natives are not linked in this build.
    private var frameCryptorUnavailable: Bool = false

    private var pendingSharedKey: Data?
    private var pendingSharedKeyIndex: Int32?

    private var pendingPerParticipantKeys: [String: [Int32: Data]] = [:]

    /// Mirrors Apple `RTCFrameCryptorKeyProvider.setSharedKey`.
    ///
    /// If the Android `FrameCryptorKeyProvider` hasn't been created yet, we stash the key/index
    /// and apply it as soon as `setSharedKey(..., ratchetSalt:)` (or `setupCryptor`) creates the provider.
    public func setSharedKey(_ key: Data, with index: Int32) {
        lock.lock()
        if isClosed {
            lock.unlock()
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot set shared key: AndroidRTCClient has been closed")
            return
        }
        pendingSharedKey = key
        pendingSharedKeyIndex = index
        // Do NOT hold `lock` past this point: the key installation below can block on the main
        // looper (latch), and the main thread may itself be waiting on this lock.
        lock.unlock()

        // Reflection-only Android path to avoid SwiftJNI method-ID traps.
        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: if (keyProvider == null) {
        // SKIP INSERT:   android.util.Log.w("AndroidRTCClient", "FrameCryptorKeyProvider not ready; stashing shared key index $index")
        // SKIP INSERT: } else {
        // SKIP INSERT:   val keyBytes = ByteArray(key.count) { key.bytes[it].toByte() }
        // SKIP INSERT:   fun invokeSetSharedKeyReflect(i: Int, bytes: ByteArray): Boolean {
        // SKIP INSERT:     return try {
        // SKIP INSERT:       val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setSharedKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:       if (m == null) false
        // SKIP INSERT:       else {
        // SKIP INSERT:         val p0 = m.parameterTypes[0]
        // SKIP INSERT:         val p1 = m.parameterTypes[1]
        // SKIP INSERT:         val r = when {
        // SKIP INSERT:           (p0 == java.lang.Integer.TYPE || p0 == java.lang.Integer::class.java) && p1 == ByteArray::class.java ->
        // SKIP INSERT:             m.invoke(keyProvider, i, bytes)
        // SKIP INSERT:           p0 == ByteArray::class.java && (p1 == java.lang.Integer.TYPE || p1 == java.lang.Integer::class.java) ->
        // SKIP INSERT:             m.invoke(keyProvider, bytes, i)
        // SKIP INSERT:           else -> null
        // SKIP INSERT:         }
        // SKIP INSERT:         (r as? Boolean) ?: false
        // SKIP INSERT:       }
        // SKIP INSERT:     } catch (e: java.lang.Exception) {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "❌ Reflection setSharedKey exception: ${e.message}", e)
        // SKIP INSERT:       false
        // SKIP INSERT:     }
        // SKIP INSERT:   }
        // SKIP INSERT:   val mainLooper = android.os.Looper.getMainLooper()
        // SKIP INSERT:   val apply = { 
        // SKIP INSERT:     val ok = invokeSetSharedKeyReflect(index.toInt(), keyBytes)
        // SKIP INSERT:     if (ok) {
        // SKIP INSERT:       this@AndroidRTCClient.pendingSharedKey = null
        // SKIP INSERT:       this@AndroidRTCClient.pendingSharedKeyIndex = null
        // SKIP INSERT:       android.util.Log.i("AndroidRTCClient", "✅ Shared media key set at index $index")
        // SKIP INSERT:     } else android.util.Log.e("AndroidRTCClient", "❌ Failed to set shared media key at index $index")
        // SKIP INSERT:   }
        // SKIP INSERT:   if (android.os.Looper.myLooper() == mainLooper) apply()
        // SKIP INSERT:   else {
        // SKIP INSERT:     val latch = java.util.concurrent.CountDownLatch(1)
        // SKIP INSERT:     android.os.Handler(mainLooper).post { try { apply() } finally { latch.countDown() } }
        // SKIP INSERT:     latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
        // SKIP INSERT:   }
        // SKIP INSERT: }
    }

    /// Ratchet-salt-aware variant that ensures the Android key provider exists.
    ///
    /// This is the closest equivalent to the Apple behavior where a keyProvider is always present
    /// and `setSharedKey` immediately updates the active key ring.
    public func setSharedKey(_ key: Data, with index: Int32, ratchetSalt: Data) {
        // Ensure the provider exists, but do NOT install a dummy key as a side effect.
        ensureSharedKeyProvider(ratchetSalt: ratchetSalt)

        lock.lock()
        if isClosed {
            lock.unlock()
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot set shared key: AndroidRTCClient has been closed")
            return
        }

        pendingSharedKey = key
        pendingSharedKeyIndex = index
        // Do NOT hold `lock` past this point: the key installation below can block on the main
        // looper (latch), and the main thread may itself be waiting on this lock.
        lock.unlock()

        // Reflection-only Android path to avoid SwiftJNI method-ID traps.
        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: if (keyProvider == null) {
        // SKIP INSERT:   android.util.Log.w("AndroidRTCClient", "FrameCryptorKeyProvider not ready; stashing shared key index $index")
        // SKIP INSERT: } else {
        // SKIP INSERT:   val keyBytes = ByteArray(key.count) { key.bytes[it].toByte() }
        // SKIP INSERT:   fun invokeSetSharedKeyReflect(i: Int, bytes: ByteArray): Boolean {
        // SKIP INSERT:     return try {
        // SKIP INSERT:       val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setSharedKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:       if (m == null) false
        // SKIP INSERT:       else {
        // SKIP INSERT:         val p0 = m.parameterTypes[0]
        // SKIP INSERT:         val p1 = m.parameterTypes[1]
        // SKIP INSERT:         val r = when {
        // SKIP INSERT:           (p0 == java.lang.Integer.TYPE || p0 == java.lang.Integer::class.java) && p1 == ByteArray::class.java ->
        // SKIP INSERT:             m.invoke(keyProvider, i, bytes)
        // SKIP INSERT:           p0 == ByteArray::class.java && (p1 == java.lang.Integer.TYPE || p1 == java.lang.Integer::class.java) ->
        // SKIP INSERT:             m.invoke(keyProvider, bytes, i)
        // SKIP INSERT:           else -> null
        // SKIP INSERT:         }
        // SKIP INSERT:         (r as? Boolean) ?: false
        // SKIP INSERT:       }
        // SKIP INSERT:     } catch (e: java.lang.Exception) {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "❌ Reflection setSharedKey exception: ${e.message}", e)
        // SKIP INSERT:       false
        // SKIP INSERT:     }
        // SKIP INSERT:   }
        // SKIP INSERT:   val mainLooper = android.os.Looper.getMainLooper()
        // SKIP INSERT:   val apply = { 
        // SKIP INSERT:     val ok = invokeSetSharedKeyReflect(index.toInt(), keyBytes)
        // SKIP INSERT:     if (ok) {
        // SKIP INSERT:       this@AndroidRTCClient.pendingSharedKey = null
        // SKIP INSERT:       this@AndroidRTCClient.pendingSharedKeyIndex = null
        // SKIP INSERT:       android.util.Log.i("AndroidRTCClient", "✅ Shared media key set at index $index")
        // SKIP INSERT:     } else android.util.Log.e("AndroidRTCClient", "❌ Failed to set shared media key at index $index")
        // SKIP INSERT:   }
        // SKIP INSERT:   if (android.os.Looper.myLooper() == mainLooper) apply()
        // SKIP INSERT:   else {
        // SKIP INSERT:     val latch = java.util.concurrent.CountDownLatch(1)
        // SKIP INSERT:     android.os.Handler(mainLooper).post { try { apply() } finally { latch.countDown() } }
        // SKIP INSERT:     latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
        // SKIP INSERT:   }
        // SKIP INSERT: }
    }

    /// Ensures `PeerConnectionFactory.initialize` has run before any FrameCryptor JNI entry points.
    ///
    /// Group SFU key provisioning can happen before the first peer connection is created; without
    /// this bootstrap, `FrameCryptorFactory.createFrameCryptorKeyProvider` throws
    /// `UnsatisfiedLinkError` even though the WebRTC `.so` is present in the APK.
    private func ensureProcessWideWebRTCInitialized() -> Bool {
        // SKIP INSERT: if (this@AndroidRTCClient.initializationFailed) return false
        // SKIP INSERT: val ctx = ProcessInfo.processInfo.androidContext
        // SKIP INSERT: val app = ctx?.applicationContext ?: run {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "Android context not available for WebRTC init")
        // SKIP INSERT:   return false
        // SKIP INSERT: }
        // SKIP INSERT: val init = org.webrtc.PeerConnectionFactory.InitializationOptions
        // SKIP INSERT:   .builder(app)
        // SKIP INSERT:   .setEnableInternalTracer(false)
        // SKIP INSERT:   .setFieldTrials("WebRTC-H264HighProfile/Enabled/")
        // SKIP INSERT:   .createInitializationOptions()
        // SKIP INSERT: try {
        // SKIP INSERT:   synchronized(AndroidRTCClient::class.java) {
        // SKIP INSERT:     val alreadyInitialized = java.lang.System.getProperty("pqsrtc.webrtc.initialized") == "1"
        // SKIP INSERT:     if (!alreadyInitialized) {
        // SKIP INSERT:       android.util.Log.i("AndroidRTCClient", "Bootstrapping WebRTC natives before FrameCryptor on ${java.lang.Thread.currentThread().name}")
        // SKIP INSERT:       org.webrtc.PeerConnectionFactory.initialize(init)
        // SKIP INSERT:       java.lang.System.setProperty("pqsrtc.webrtc.initialized", "1")
        // SKIP INSERT:     }
        // SKIP INSERT:   }
        // SKIP INSERT:   return true
        // SKIP INSERT: } catch (e: java.lang.UnsatisfiedLinkError) {
        // SKIP INSERT:   this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "WebRTC native library link error during pre-FrameCryptor bootstrap: ${e.message}", e)
        // SKIP INSERT:   return false
        // SKIP INSERT: } catch (e: Throwable) {
        // SKIP INSERT:   this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "WebRTC bootstrap failed before FrameCryptor: ${e.javaClass.simpleName}: ${e.message}", e)
        // SKIP INSERT:   return false
        // SKIP INSERT: }
        return true
    }

    /// Ensures a shared-key-mode FrameCryptorKeyProvider exists.
    ///
    /// This **must not** install a dummy key. It may apply a previously stashed shared key
    /// (`pendingSharedKey`) if present.
    private func ensureSharedKeyProvider(ratchetSalt: Data) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if frameCryptorUnavailable {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "FrameCryptorKeyProvider unavailable; skipping shared-key provider creation")
            lock.unlock()
            return
        }

        // SKIP INSERT: if (!ensureProcessWideWebRTCInitialized()) {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "WebRTC natives unavailable; deferring shared-key FrameCryptorKeyProvider creation")
        // SKIP INSERT:   lock.unlock()
        // SKIP INSERT:   return
        // SKIP INSERT: }

        // Match RTCSession.ensureFrameKeyProviderIfNeeded() (PBKDF2 = WebRTC default when Apple omits keyDerivationAlgorithm).
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
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderReady = false
        // SKIP INSERT:     keyProvider = null
        // SKIP INSERT:     val ratchetSaltSize = ratchetSalt.count
        // SKIP INSERT:     val ratchetSaltBytes = kotlin.UByteArray(ratchetSaltSize) { ratchetSalt.bytes[it] }
        // SKIP INSERT:     val ratchetSaltByteArray = kotlin.ByteArray(size = ratchetSaltBytes.size) { idx -> ratchetSaltBytes[idx].toByte() }
        // SKIP INSERT:     try {
        // SKIP INSERT:     keyProvider = org.webrtc.FrameCryptorFactory.createFrameCryptorKeyProvider(
        // SKIP INSERT:         sharedKeyMode,
        // SKIP INSERT:         ratchetSaltByteArray,
        // SKIP INSERT:         ratchetWindowSize,
        // SKIP INSERT:         uncryptedMagicBytes,
        // SKIP INSERT:         failureTolerance,
        // SKIP INSERT:         keyRingSize,
        // SKIP INSERT:         discardFrameWhenCryptorNotReady,
        // SKIP INSERT:         org.webrtc.FrameCryptorKeyDerivationAlgorithm.PBKDF2
        // SKIP INSERT:     )
        // SKIP INSERT:     this@AndroidRTCClient.keyProvider = keyProvider
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderReady = true
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderIsSharedKeyMode = sharedKeyMode
        // SKIP INSERT:     this@AndroidRTCClient.frameCryptorSupport.setKeyProvider(keyProvider)
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "🔐 FrameCryptorKeyProvider created (sharedKeyMode=$sharedKeyMode)")
        // SKIP INSERT:     } catch (e: java.lang.UnsatisfiedLinkError) {
        // SKIP INSERT:         this@AndroidRTCClient.keyProvider = null
        // SKIP INSERT:         this@AndroidRTCClient.keyProviderReady = false
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorUnavailable = true
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorSupport.clearKeyProvider()
        // SKIP INSERT:         keyProvider = null
        // SKIP INSERT:         android.util.Log.e("AndroidRTCClient", "FrameCryptor native API unavailable; media E2EE disabled for this Android WebRTC build", e)
        // SKIP INSERT:     } catch (e: java.lang.LinkageError) {
        // SKIP INSERT:         this@AndroidRTCClient.keyProvider = null
        // SKIP INSERT:         this@AndroidRTCClient.keyProviderReady = false
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorUnavailable = true
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorSupport.clearKeyProvider()
        // SKIP INSERT:         keyProvider = null
        // SKIP INSERT:         android.util.Log.e("AndroidRTCClient", "FrameCryptor native linkage failed; media E2EE disabled for this Android WebRTC build", e)
        // SKIP INSERT:     }
        // SKIP INSERT: }

        // Release the lock before applying the pending key: the application below can block on
        // the main looper (latch), and the main thread may itself be waiting on this lock.
        lock.unlock()

        // If we stashed a key earlier, apply it now that a provider exists. JNI requires main thread.
        // SKIP INSERT: val pendingKey = this@AndroidRTCClient.pendingSharedKey
        // SKIP INSERT: val pendingIndex = this@AndroidRTCClient.pendingSharedKeyIndex
        // SKIP INSERT: if (pendingKey != null && pendingIndex != null && keyProvider != null) {
        // SKIP INSERT:   val keySize = pendingKey.count
        // SKIP INSERT:   val keyBytesUInt8 = kotlin.UByteArray(keySize) { pendingKey.bytes[it] }
        // SKIP INSERT:   val keyBytes: ByteArray = kotlin.ByteArray(size = keyBytesUInt8.size) { idx -> keyBytesUInt8[idx].toByte() }
        // SKIP INSERT:   val mainLooper = android.os.Looper.getMainLooper()
        // SKIP INSERT:   fun applyPending() {
        // SKIP INSERT:     val ok = try {
        // SKIP INSERT:       val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setSharedKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:       if (m != null) (m.invoke(keyProvider, pendingIndex.toInt(), keyBytes) as? Boolean) ?: false else false
        // SKIP INSERT:     } catch (e: java.lang.Exception) {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "❌ Exception applying pending shared key: ${e.message}", e)
        // SKIP INSERT:       false
        // SKIP INSERT:     }
        // SKIP INSERT:     if (ok) {
        // SKIP INSERT:       android.util.Log.i("AndroidRTCClient", "✅ Applied stashed shared media key at index $pendingIndex")
        // SKIP INSERT:       this@AndroidRTCClient.pendingSharedKey = null
        // SKIP INSERT:       this@AndroidRTCClient.pendingSharedKeyIndex = null
        // SKIP INSERT:     } else android.util.Log.e("AndroidRTCClient", "❌ Failed to apply stashed shared media key at index $pendingIndex")
        // SKIP INSERT:   }
        // SKIP INSERT:   if (android.os.Looper.myLooper() == mainLooper) applyPending()
        // SKIP INSERT:   else {
        // SKIP INSERT:     val latch = java.util.concurrent.CountDownLatch(1)
        // SKIP INSERT:     android.os.Handler(mainLooper).post { try { applyPending() } finally { latch.countDown() } }
        // SKIP INSERT:     latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
        // SKIP INSERT:   }
        // SKIP INSERT: }
    }

    /// Ensures a key provider exists in the requested mode.
    private func ensureKeyProvider(sharedKeyMode: Bool, ratchetSalt: Data) {
        // We piggy-back on `setSharedKey(..., ratchetSalt:)` for provider creation logic.
        // If we're in per-participant mode, we call a dedicated creation path.
        if sharedKeyMode {
            ensureSharedKeyProvider(ratchetSalt: ratchetSalt)
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return }
        guard !frameCryptorUnavailable else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "FrameCryptorKeyProvider unavailable; skipping per-participant provider creation")
            return
        }

        // SKIP INSERT: if (!ensureProcessWideWebRTCInitialized()) {
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "WebRTC natives unavailable; deferring per-participant FrameCryptorKeyProvider creation")
        // SKIP INSERT:   return
        // SKIP INSERT: }

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
        // SKIP INSERT:     try {
        // SKIP INSERT:     keyProvider = org.webrtc.FrameCryptorFactory.createFrameCryptorKeyProvider(
        // SKIP INSERT:         sharedKeyModeK,
        // SKIP INSERT:         ratchetSaltByteArray,
        // SKIP INSERT:         ratchetWindowSize,
        // SKIP INSERT:         uncryptedMagicBytes,
        // SKIP INSERT:         failureTolerance,
        // SKIP INSERT:         keyRingSize,
        // SKIP INSERT:         discardFrameWhenCryptorNotReady,
        // SKIP INSERT:         org.webrtc.FrameCryptorKeyDerivationAlgorithm.PBKDF2
        // SKIP INSERT:     )
        // SKIP INSERT:     this@AndroidRTCClient.keyProvider = keyProvider
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderReady = true
        // SKIP INSERT:     this@AndroidRTCClient.keyProviderIsSharedKeyMode = sharedKeyModeK
        // SKIP INSERT:     this@AndroidRTCClient.frameCryptorSupport.setKeyProvider(keyProvider)
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "🔐 FrameCryptorKeyProvider created (sharedKeyMode=$sharedKeyModeK)")
        // SKIP INSERT:     } catch (e: java.lang.UnsatisfiedLinkError) {
        // SKIP INSERT:         this@AndroidRTCClient.keyProvider = null
        // SKIP INSERT:         this@AndroidRTCClient.keyProviderReady = false
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorUnavailable = true
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorSupport.clearKeyProvider()
        // SKIP INSERT:         android.util.Log.e("AndroidRTCClient", "FrameCryptor native API unavailable; media E2EE disabled for this Android WebRTC build", e)
        // SKIP INSERT:     } catch (e: java.lang.LinkageError) {
        // SKIP INSERT:         this@AndroidRTCClient.keyProvider = null
        // SKIP INSERT:         this@AndroidRTCClient.keyProviderReady = false
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorUnavailable = true
        // SKIP INSERT:         this@AndroidRTCClient.frameCryptorSupport.clearKeyProvider()
        // SKIP INSERT:         android.util.Log.e("AndroidRTCClient", "FrameCryptor native linkage failed; media E2EE disabled for this Android WebRTC build", e)
        // SKIP INSERT:     }
        // SKIP INSERT: }
    }

    /// Applies any per-participant keys stashed before the FrameCryptor key provider existed.
    private func applyPendingPerParticipantKeysIfReady() {
        lock.lock()
        guard keyProviderReady, !pendingPerParticipantKeys.isEmpty else {
            lock.unlock()
            return
        }
        let pending = pendingPerParticipantKeys
        pendingPerParticipantKeys.removeAll()
        lock.unlock()

        for (participantId, byIndex) in pending {
            for (index, keyData) in byIndex {
                installPerParticipantKey(keyData, index: index, participantId: participantId)
            }
        }
    }

    /// Installs a single per-participant FrameCryptor key (provider must already exist).
    private func installPerParticipantKey(_ key: Data, index: Int32, participantId: String) {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed, keyProviderReady else { return }

        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider ?: return
        // SKIP INSERT: val keyBytes = ByteArray(key.count) { key.bytes[it].toByte() }
        // SKIP INSERT: fun doSetKey() {
        // SKIP INSERT:   try {
        // SKIP INSERT:     val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setKey" && it.parameterTypes.size == 3 }
        // SKIP INSERT:     val success = if (m != null) (m.invoke(keyProvider, participantId, index.toInt(), keyBytes) as? Boolean) ?: false else false
        // SKIP INSERT:     if (!success) android.util.Log.e("AndroidRTCClient", "❌ Failed to set stashed per-participant key for '$participantId' index $index")
        // SKIP INSERT:     else android.util.Log.i("AndroidRTCClient", "✅ Applied stashed per-participant key for '$participantId' index $index")
        // SKIP INSERT:   } catch (e: java.lang.Exception) { android.util.Log.e("AndroidRTCClient", "❌ Exception applying stashed per-participant key: ${e.message}", e) }
        // SKIP INSERT: }
        // SKIP INSERT: val mainLooper = android.os.Looper.getMainLooper()
        // SKIP INSERT: if (android.os.Looper.myLooper() == mainLooper) doSetKey()
        // SKIP INSERT: else android.os.Handler(mainLooper).post { doSetKey() }
    }

    /// Per-participant key setter (participant-scoped key ring).
    /// IMPORTANT: All keyProvider usage MUST be in SKIP INSERT. Swift/JNI bridge crashes when
    /// resolving setKey (wrong signature). Kotlin reflection avoids the bridge entirely.
    public func setKey(
        _ key: Data,
        with index: Int32,
        forParticipant participantId: String,
        ratchetSalt: Data
    ) {
        ensureKeyProvider(sharedKeyMode: false, ratchetSalt: ratchetSalt)
        applyPendingPerParticipantKeysIfReady()

        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return }

        // Do not read keyProvider in Swift: it triggers JNI resolution of setKey and crashes (SIGTRAP). Use keyProviderReady instead.
        guard keyProviderReady else {
            var byIndex = pendingPerParticipantKeys[participantId] ?? [:]
            byIndex[index] = key
            pendingPerParticipantKeys[participantId] = byIndex
            // SKIP INSERT: android.util.Log.w("AndroidRTCClient", "KeyProvider not ready; stashing per-participant key for '$participantId' index $index")
            return
        }

        // JNI method lookup for setKey can crash when invoked through the Swift bridge.
        // Keep the actual setKey call in Kotlin reflection.
        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider ?: return
        // SKIP INSERT: val keyBytes = ByteArray(key.count) { key.bytes[it].toByte() }
        // SKIP INSERT: fun doSetKey() {
        // SKIP INSERT:   try {
        // SKIP INSERT:     val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setKey" && it.parameterTypes.size == 3 }
        // SKIP INSERT:     val success = if (m != null) (m.invoke(keyProvider, participantId, index.toInt(), keyBytes) as? Boolean) ?: false else false
        // SKIP INSERT:     if (!success) android.util.Log.e("AndroidRTCClient", "❌ Failed to set per-participant key for '$participantId' index $index")
        // SKIP INSERT:     else android.util.Log.i("AndroidRTCClient", "✅ Per-participant key set for '$participantId' index $index")
        // SKIP INSERT:   } catch (e: java.lang.Exception) { android.util.Log.e("AndroidRTCClient", "❌ Exception setting per-participant key: ${e.message}", e) }
        // SKIP INSERT: }
        // SKIP INSERT: val mainLooper = android.os.Looper.getMainLooper()
        // SKIP INSERT: if (android.os.Looper.myLooper() == mainLooper) doSetKey()
        // SKIP INSERT: else {
        // SKIP INSERT:   // Do not block the caller waiting on the UI thread here.
        // SKIP INSERT:   // The synchronous wait was causing multi-second stalls during
        // SKIP INSERT:   // call setup on Android, which then delayed offer creation and
        // SKIP INSERT:   // renderer startup. Key installation is safe to complete
        // SKIP INSERT:   // asynchronously on the main looper.
        // SKIP INSERT:   android.os.Handler(mainLooper).post { doSetKey() }
        // SKIP INSERT: }
    }

    /// Best-effort export of the current key. If the underlying WebRTC API doesn't support it,
    /// this returns empty `Data`.
    public func exportKey(forParticipant participantId: String, index: Int32) -> Data {
        lock.lock()
        if isClosed {
            lock.unlock()
            return Data()
        }
        guard keyProviderReady else {
            lock.unlock()
            return Data()
        }

        var result = Data()
        // SKIP INSERT: result = try {
        // SKIP INSERT:   val m = keyProvider?.javaClass?.methods?.firstOrNull { it.name == "exportKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:   val bytes = if (m != null && keyProvider != null) (m.invoke(keyProvider, participantId, index.toInt()) as? ByteArray) else null
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
        // SKIP INSERT:   // `bytes` is a Kotlin `ByteArray` from WebRTC. Wrap it directly as SkipFoundation `Data`.
        // SKIP INSERT:   Data(platformValue = bytes)
        // SKIP INSERT: } ?: Data()

        lock.unlock()
        return result
    }

    /// Best-effort ratchet; returns the newly derived key if available, else empty `Data`.
    public func ratchetKey(forParticipant participantId: String, index: Int32) -> Data {
        lock.lock()
        if isClosed {
            lock.unlock()
            return Data()
        }
        guard keyProviderReady else {
            lock.unlock()
            return Data()
        }

        var result = Data()
        // SKIP INSERT: result = try {
        // SKIP INSERT:   val m = keyProvider?.javaClass?.methods?.firstOrNull { it.name == "ratchetKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:   val bytes = if (m != null && keyProvider != null) (m.invoke(keyProvider, participantId, index.toInt()) as? ByteArray) else null
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
        // SKIP INSERT:   // `bytes` is a Kotlin `ByteArray` from WebRTC. Wrap it directly as SkipFoundation `Data`.
        // SKIP INSERT:   Data(platformValue = bytes)
        // SKIP INSERT: } ?: Data()

        lock.unlock()
        return result
    }

    // MARK: - E2EE (FrameCryptor)

    /// Initializes (or reuses) a WebRTC FrameCryptorKeyProvider and sets the current shared media key.
    ///
    /// Notes:
    /// - We use shared-key mode to mirror the Apple implementation (`RTCFrameCryptorKeyProvider.setSharedKey`).
    /// - `participant` is kept for API symmetry but is not required in shared-key mode.
    private func setupCryptor(key: Data, index: Int, participant: String, ratchetSalt: Data) {
        // Kept for backwards call-sites: create/ensure key provider and set the shared key.
        setSharedKey(key, with: Int32(index), ratchetSalt: ratchetSalt)
    }

    /// Attaches FrameCryptor encryptors to current RTP senders (audio/video) on the active PeerConnection.
    public func createSenderEncryptedFrame(participant: String, connectionId: String) {
        lock.lock()
        let canAttach = !isClosed && !frameCryptorUnavailable && keyProviderReady
        let currentPeerConnection = peerConnection?.platformPeerConnection
        let currentFactory = factory
        lock.unlock()

        guard canAttach, let currentPeerConnection, let currentFactory else { return }
        frameCryptorSupport.attachSenderCryptors(
            factory: currentFactory,
            peerConnection: currentPeerConnection,
            participant: participant
        )
    }

    /// Attaches a dedicated FrameCryptor encryptor to the local screen-share RTP sender.
    ///
    /// This keeps camera and screen outbound encryption independent when both are published.
    public func createScreenSenderEncryptedFrame(participant: String, connectionId: String, trackId: String? = nil) {
        lock.lock()
        let canAttach = !isClosed && !frameCryptorUnavailable && keyProviderReady
        let currentPeerConnection = peerConnection?.platformPeerConnection
        let currentFactory = factory
        lock.unlock()

        guard canAttach, let currentPeerConnection, let currentFactory else { return }
        frameCryptorSupport.attachScreenSenderCryptor(
            factory: currentFactory,
            peerConnection: currentPeerConnection,
            participant: participant,
            trackId: trackId
        )
    }

    /// Attaches FrameCryptor decryptors to current RTP receivers (audio/video) on the active PeerConnection.
    public func createReceiverEncryptedFrame(participant: String, connectionId: String, trackKind: String? = nil, trackId: String? = nil) {
        lock.lock()
        let canAttach = !isClosed && !frameCryptorUnavailable && keyProviderReady
        let currentPeerConnection = peerConnection?.platformPeerConnection
        let currentFactory = factory
        lock.unlock()

        guard canAttach, let currentPeerConnection, let currentFactory else { return }
        frameCryptorSupport.attachReceiverCryptors(
            factory: currentFactory,
            peerConnection: currentPeerConnection,
            participant: participant,
            trackKind: trackKind,
            trackId: trackId
        )
    }

    /// Updates the current shared media key (manual re-key / ratchet advance).
    private func ratchetAdvanced(with newKey: Data, index: Int, participant: String) {
        // Only read state under the lock; the key update below can block on the main looper
        // (latch), and the main thread may itself be waiting on this lock.
        lock.lock()
        let closed = isClosed
        lock.unlock()

        guard !closed else {
            // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Cannot advance ratchet: AndroidRTCClient has been closed")
            return
        }

        // JNI requires main thread.
        // SKIP INSERT: val keyProvider = this@AndroidRTCClient.keyProvider
        // SKIP INSERT: if (keyProvider != null) {
        // SKIP INSERT:   val newKeySize = newKey.count
        // SKIP INSERT:   val newKeyBytesUInt8 = kotlin.UByteArray(newKeySize) { newKey.bytes[it] }
        // SKIP INSERT:   val keyBytes: ByteArray = kotlin.ByteArray(size = newKeyBytesUInt8.size) { idx -> newKeyBytesUInt8[idx].toByte() }
        // SKIP INSERT:   val mainLooper = android.os.Looper.getMainLooper()
        // SKIP INSERT:   fun doRatchet() {
        // SKIP INSERT:     val success = try {
        // SKIP INSERT:       val m = keyProvider.javaClass.methods.firstOrNull { it.name == "setSharedKey" && it.parameterTypes.size == 2 }
        // SKIP INSERT:       if (m != null) (m.invoke(keyProvider, index, keyBytes) as? Boolean) ?: false else false
        // SKIP INSERT:     } catch (e: java.lang.Exception) {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "❌ Exception in ratchet setSharedKey: ${e.message}", e)
        // SKIP INSERT:       false
        // SKIP INSERT:     }
        // SKIP INSERT:     if (success) android.util.Log.i("AndroidRTCClient", "🔑 Updated shared media key index $index")
        // SKIP INSERT:     else android.util.Log.e("AndroidRTCClient", "❌ Failed to update shared media key index $index")
        // SKIP INSERT:   }
        // SKIP INSERT:   if (android.os.Looper.myLooper() == mainLooper) doRatchet()
        // SKIP INSERT:   else {
        // SKIP INSERT:     val latch = java.util.concurrent.CountDownLatch(1)
        // SKIP INSERT:     android.os.Handler(mainLooper).post { try { doRatchet() } finally { latch.countDown() } }
        // SKIP INSERT:     latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
        // SKIP INSERT:   }
        // SKIP INSERT: } else android.util.Log.e("AndroidRTCClient", "KeyProvider not initialized before ratchetAdvanced()")
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
    private func createFactory() -> org.webrtc.PeerConnectionFactory? {
        lock.lock()
        let failed = initializationFailed
        lock.unlock()
        
        guard !failed else {
            return nil
        }
        
        // SKIP INSERT: try {
        // SKIP INSERT:   if (this@AndroidRTCClient.factory == null) {
        // SKIP INSERT:     // Check if initialization has already failed
        // SKIP INSERT:     if (this@AndroidRTCClient.initializationFailed) {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "WebRTC initialization previously failed. Cannot create factory.")
        // SKIP INSERT:       return null
        // SKIP INSERT:     }
        // SKIP INSERT:     
        // SKIP INSERT:     val ctx = ProcessInfo.processInfo.androidContext
        // SKIP INSERT:     val app = ctx?.applicationContext ?: run {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "Android context not available")
        // SKIP INSERT:       return null
        // SKIP INSERT:     }
        // SKIP INSERT:     
        // SKIP INSERT:     val init = org.webrtc.PeerConnectionFactory.InitializationOptions
        // SKIP INSERT:       .builder(app)
        // SKIP INSERT:       .setEnableInternalTracer(false)
        // SKIP INSERT:       .setFieldTrials("WebRTC-H264HighProfile/Enabled/")
        // SKIP INSERT:       .createInitializationOptions()
        // SKIP INSERT:     try {
        // SKIP INSERT:       // WebRTC native bootstrap is process-global; serialize it, but do not
        // SKIP INSERT:       // bounce through the main thread. Blocking on a main-thread Handler here
        // SKIP INSERT:       // can deadlock while Compose is presenting the call UI, leaving the RTC
        // SKIP INSERT:       // actor stuck before offer creation and making end-call teardown ANR.
        // SKIP INSERT:       synchronized(AndroidRTCClient::class.java) {
        // SKIP INSERT:         val alreadyInitialized = java.lang.System.getProperty("pqsrtc.webrtc.initialized") == "1"
        // SKIP INSERT:         if (!alreadyInitialized) {
        // SKIP INSERT:           android.util.Log.i("AndroidRTCClient", "Initializing PeerConnectionFactory on ${java.lang.Thread.currentThread().name}")
        // SKIP INSERT:           org.webrtc.PeerConnectionFactory.initialize(init)
        // SKIP INSERT:           java.lang.System.setProperty("pqsrtc.webrtc.initialized", "1")
        // SKIP INSERT:           android.util.Log.i("AndroidRTCClient", "PeerConnectionFactory process init complete")
        // SKIP INSERT:         }
        // SKIP INSERT:       }
        // SKIP INSERT:     } catch (e: java.lang.ClassNotFoundException) {
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "WebRTC native library not found: ${e.message}", e)
        // SKIP INSERT:       return null
        // SKIP INSERT:     } catch (e: java.lang.UnsatisfiedLinkError) {
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "WebRTC native library link error: ${e.message}", e)
        // SKIP INSERT:       return null
        // SKIP INSERT:     } catch (e: Throwable) {
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "Failed to initialize PeerConnectionFactory: ${e.javaClass.simpleName}: ${e.message}", e)
        // SKIP INSERT:       return null
        // SKIP INSERT:     }
        // SKIP INSERT:     
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "Creating EGL base")
        // SKIP INSERT:     val egl = org.webrtc.EglBase.create() ?: run {
        // SKIP INSERT:       android.util.Log.e("AndroidRTCClient", "Failed to create EGL base")
        // SKIP INSERT:       this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:       return null
        // SKIP INSERT:     }
        // SKIP INSERT:     this@AndroidRTCClient.eglBase = egl
        // SKIP INSERT:
        // SKIP INSERT:     val enc = org.webrtc.DefaultVideoEncoderFactory(egl.eglBaseContext, true, true)
        // SKIP INSERT:     val dec = org.webrtc.DefaultVideoDecoderFactory(egl.eglBaseContext)
        // SKIP INSERT:     
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "Creating PeerConnectionFactory instance")
        // SKIP INSERT:     val fac = org.webrtc.PeerConnectionFactory.builder()
        // SKIP INSERT:         .setVideoEncoderFactory(enc)
        // SKIP INSERT:         .setVideoDecoderFactory(dec)
        // SKIP INSERT:         .createPeerConnectionFactory()
        // SKIP INSERT:     this@AndroidRTCClient.factory = fac
        // SKIP INSERT:     android.util.Log.i("AndroidRTCClient", "PeerConnectionFactory instance ready")
        // SKIP INSERT:   }
        // SKIP INSERT:   return this@AndroidRTCClient.factory
        // SKIP INSERT: } catch (e: Throwable) {
        // SKIP INSERT:   // Mark as failed if not already marked
        // SKIP INSERT:   this@AndroidRTCClient.initializationFailed = true
        // SKIP INSERT:   android.util.Log.e("AndroidRTCClient", "Fatal error creating factory: ${e.javaClass.simpleName}: ${e.message}", e)
        // SKIP INSERT:   return null
        // SKIP INSERT: }
    }
    
    /// Creates an Android `PeerConnection` with Unified Plan semantics and continual ICE gathering.
    private func createPeerConnection(
        iceServers: [String],
        username: String? = nil,
        password: String? = nil,
        iceTransportPolicy: RTCIceTransportSelection = .all
    ) throws -> org.webrtc.PeerConnection? {
        // SKIP INSERT: try {
        // SKIP INSERT:   val factory = createFactory() ?: return null
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
        // SKIP INSERT:   config.iceTransportsType = if (iceTransportPolicy == RTCIceTransportSelection.relay) org.webrtc.PeerConnection.IceTransportsType.RELAY else org.webrtc.PeerConnection.IceTransportsType.ALL
        // SKIP INSERT:   config.enableDscp = true
        // SKIP INSERT:   config.continualGatheringPolicy = org.webrtc.PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        // SKIP INSERT:   val obs = RTCClientPeerObserver(this@AndroidRTCClient)
        // SKIP INSERT:   this@AndroidRTCClient.observer = obs
        // SKIP INSERT:   android.util.Log.i("AndroidRTCClient", "Creating native PeerConnection iceServers=${servers.size} policy=${config.iceTransportsType}")
        // SKIP INSERT:   val pc = factory.createPeerConnection(config, obs)
        // SKIP INSERT:   android.util.Log.i("AndroidRTCClient", "Native PeerConnection created=${pc != null}")
        // SKIP INSERT:   this@AndroidRTCClient.factory = factory
        // SKIP INSERT:   return pc
        // SKIP INSERT: } catch (e: Throwable) {
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
    public func initializeFactory(
        iceServers: [String],
        username: String? = nil,
        password: String? = nil,
        iceTransportPolicy: RTCIceTransportSelection = .all
    ) throws -> org.webrtc.PeerConnection {
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
            let pc = try createPeerConnection(
                iceServers: iceServers,
                username: username,
                password: password,
                iceTransportPolicy: iceTransportPolicy)
            
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
        // SKIP INSERT: return RTCMediaConstraints(c)
        fatalError("createConstraints should only be called on Android")
    }
    
    /// Creates and stores an audio source.
    ///
    /// - Parameter constraints: Platform constraints for the source.
    /// - Returns: The created audio source wrapper.
    @discardableResult
    public func createAudioSource(_ constraints: RTCMediaConstraints) -> RTCAudioSource {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val src = RTCAudioSource(fac.createAudioSource(constraints.platformConstraints))
        // SKIP INSERT: this.audioSource = src
        // SKIP INSERT: return src
        fatalError("createAudioSource should only be called on Android")
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
        // SKIP INSERT: val track = RTCAudioTrack(fac.createAudioTrack("audio_${id}", audioSource.platformSource))
        // SKIP INSERT: this.localAudioTrack = track
        // SKIP INSERT: return track
        fatalError("createAudioTrack should only be called on Android")
    }
    
    /// Creates and stores a video source.
    ///
    /// - Parameter isScreen: Whether the source is intended for screen capture.
    public func createVideoSource(_ isScreen: Bool = false) -> RTCVideoSource {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val src = RTCVideoSource(fac.createVideoSource(isScreen))
        // SKIP INSERT: this.videoSource = src
        // SKIP INSERT: return src
        fatalError("createVideoSource should only be called on Android")
    }
    
    /// Creates and stores a local video track.
    ///
    /// - Parameters:
    ///   - id: An identifier used to label the track.
    ///   - videoSource: The video source wrapper.
    public func createVideoTrack(id: String, _ videoSource: RTCVideoSource) -> RTCVideoTrack {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val track = RTCVideoTrack(fac.createVideoTrack("video_${id}", videoSource.platformSource))
        // SKIP INSERT: this.localVideoTrack = track
        // SKIP INSERT: return track
        fatalError("createVideoTrack should only be called on Android")
    }
    
    // MARK: - Screen Share

    /// Creates a screen-specific video source (stored separately from the camera source).
    private func createScreenVideoSource() -> RTCVideoSource {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val src = RTCVideoSource(fac.createVideoSource(true))
        // SKIP INSERT: this.screenVideoSource = src
        // SKIP INSERT: return src
        fatalError("createScreenVideoSource should only be called on Android")
    }

    /// Creates a screen video track (stored separately from the camera track).
    private func createScreenVideoTrack(id: String, _ videoSource: RTCVideoSource) -> RTCVideoTrack {
        // SKIP INSERT: val fac = factory ?: throw IllegalStateException("Factory not initialized")
        // SKIP INSERT: val track = RTCVideoTrack(fac.createVideoTrack("screen_${id}", videoSource.platformSource))
        // SKIP INSERT: this.screenVideoTrack = track
        // SKIP INSERT: return track
        fatalError("createScreenVideoTrack should only be called on Android")
    }

    /// Returns a trackless video transceiver beyond the camera slot that can carry the
    /// screen sender (the reserved group-call screen slot), if one exists.
    ///
    /// Resolution goes through ``AndroidWebRTCTrackResolver`` because raw
    /// `PeerConnection.getTransceivers()` disposes previously returned wrappers, silently
    /// detaching live renderer sinks.
    private func reusableScreenSlotTransceiver(
        in platformPeerConnection: org.webrtc.PeerConnection
    ) -> org.webrtc.RtpTransceiver? {
        return AndroidWebRTCTrackResolver.reusableScreenSlotTransceiver(peerConnection: platformPeerConnection)
    }

    /// Reserves the group-call screen slot (contract mid=2) with an inactive video
    /// transceiver so SFU relay binding does not require escalating mids mid-call.
    /// No-op when a screen slot already exists (reserved earlier or actively sharing).
    public func reserveScreenShareSlot(streamId: String) throws {
        let platformPeerConnection: org.webrtc.PeerConnection
        do {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
            }
            guard let pc = self.peerConnection?.platformPeerConnection else {
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
            }
            platformPeerConnection = pc
            lock.unlock()
        }

        // Contract layout is audio=0, camera=1, screen=2: any second video transceiver
        // is the screen slot (reserved earlier, or carrying an active share).
        let videoTransceiverCount = AndroidWebRTCTrackResolver.videoTransceiverCount(peerConnection: platformPeerConnection)
        if videoTransceiverCount >= 2 { return }

        var ids = [String]()
        ids.append(streamId)
        let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(
            org.webrtc.RtpTransceiver.RtpTransceiverDirection.INACTIVE,
            ids.toList()
        )
        platformPeerConnection.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, initOpts)
        AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: platformPeerConnection)
    }

    /// Prepares a second video transceiver for screen sharing, creates the screen track,
    /// and starts `ScreenCapturerAndroid` with the MediaProjection result.
    ///
    /// The consent `Intent` never crosses the Swift bridge; the capturer consumes it from
    /// `AndroidMediaProjectionResultHolder` (Kotlin side) when capture starts.
    ///
    /// - Parameters:
    ///   - id: Participant/stream label used for the `screen_<id>` stream ID prefix.
    ///   - resultCode: The `Activity.RESULT_OK` code from the MediaProjection permission grant.
    /// - Returns: The screen video track wrapper.
    public func prepareScreenShareSendRecv(
        id: String,
        resultCode: Int,
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 15
    ) throws -> RTCVideoTrack? {
        let platformPeerConnection: org.webrtc.PeerConnection
        let trackToReturn: RTCVideoTrack?
        let shouldStartCapture: Bool
        do {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
            }
            guard let pc = self.peerConnection?.platformPeerConnection else {
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
            }

            if screenVideoSource == nil {
                _ = createScreenVideoSource()
            }
            if screenVideoTrack == nil, let source = screenVideoSource {
                _ = createScreenVideoTrack(id: id, source)
            }

            platformPeerConnection = pc
            trackToReturn = screenVideoTrack
            shouldStartCapture = (screenCapturer == nil)
            lock.unlock()
        }

        // Ensure a trackless video transceiver exists for the screen track. When the
        // group-call screen slot (contract mid=2) was reserved at join, addTrack below
        // reuses it; adding another transceiver here would leave a stray empty m-line
        // (mid=3) that violates the audio=0/camera=1/screen=2 contract.
        if reusableScreenSlotTransceiver(in: platformPeerConnection) == nil {
            let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_ONLY)
            platformPeerConnection.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, initOpts)
            AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: platformPeerConnection)
        }

        if let track = trackToReturn {
            var ids = [String]()
            ids.append("screen_\(id)")
            _ = platformPeerConnection.addTrack(track.platformTrack, ids.toList())
            AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: platformPeerConnection)
        }

        if shouldStartCapture {
            // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Launching async screen capture startup")
            let capturedResultCode = resultCode
            let capturedWidth = width
            let capturedHeight = height
            let capturedFps = fps
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    try self.startScreenCapture(
                        resultCode: capturedResultCode,
                        width: capturedWidth,
                        height: capturedHeight,
                        fps: capturedFps
                    )
                    // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Screen capture started")
                } catch {
                    // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Failed to start screen capture: ${error}")
                    self.dispatchScreenCaptureStarted(false)
                }
            }
        }

        return trackToReturn
    }

    /// Starts the Android screen capturer using MediaProjection.
    private func startScreenCapture(resultCode: Int, width: Int, height: Int, fps: Int) throws {
        let existingSource: RTCVideoSource
        let staleHelper: org.webrtc.SurfaceTextureHelper?

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        guard let ctx = ProcessInfo.processInfo.androidContext else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("Android context not available")
        }
        guard let source = screenVideoSource else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("Screen video source not initialized")
        }
        if screenCapturer != nil {
            lock.unlock()
            return
        }

        existingSource = source
        staleHelper = screenSurfaceTextureHelper
        screenSurfaceTextureHelper = nil
        lock.unlock()

        do {
            try ensureEglBase()
        } catch {
            throw RTCClientErrors.peerConnectionError("Failed to ensure EGL base: \(error.localizedDescription)")
        }

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        guard let eglBase = eglBase else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("EGL base is nil after ensureEglBase")
        }
        lock.unlock()

        staleHelper?.dispose()

        // SKIP INSERT: if (!AndroidScreenCaptureForeground.startAndAwaitReady(5000)) {
        // SKIP INSERT:     AndroidScreenCaptureForeground.stopIfRunning()
        // SKIP INSERT:     throw IllegalStateException("Media projection foreground service did not become ready")
        // SKIP INSERT: }

        let helper = org.webrtc.SurfaceTextureHelper.create("WebRTCScreenCapture", eglBase.eglBaseContext)
        guard let helper else {
            throw RTCClientErrors.peerConnectionError("Failed to create SurfaceTextureHelper for screen capture")
        }

        let rawDownstream = existingSource.platformSource.getCapturerObserver()
        let orientedObserver = CapturerObserverProxy(
            downstream: rawDownstream,
            normalizeToUpright: true,
            allowAppearanceSoftening: false)

        // SKIP INSERT: val intentData = AndroidMediaProjectionResultHolder.consume()
        // SKIP INSERT:     ?: throw IllegalStateException("MediaProjection consent intent not available; launch the consent flow before starting screen share")
        // SKIP INSERT: var lifecycleObserverRef: ScreenCaptureLifecycleObserver? = null
        // SKIP INSERT: val callback = object : android.media.projection.MediaProjection.Callback() {
        // SKIP INSERT:     override fun onStop() {
        // SKIP INSERT:         android.util.Log.i("AndroidRTCClient", "MediaProjection stopped by system")
        // SKIP INSERT:         lifecycleObserverRef?.notifyProjectionStopped()
        // SKIP INSERT:     }
        // SKIP INSERT: }
        // SKIP INSERT: val capturer = org.webrtc.ScreenCapturerAndroid(intentData, callback)
        // SKIP INSERT: val lifecycleObserver = ScreenCaptureLifecycleObserver(
        // SKIP INSERT:     downstream = orientedObserver,
        // SKIP INSERT:     onStarted = { success -> this@AndroidRTCClient.dispatchScreenCaptureStarted(success) },
        // SKIP INSERT:     onProjectionStopped = { this@AndroidRTCClient.dispatchScreenProjectionStopped() }
        // SKIP INSERT: )
        // SKIP INSERT: lifecycleObserverRef = lifecycleObserver
        // SKIP INSERT: val ctx = ProcessInfo.processInfo.androidContext
        // SKIP INSERT:     ?: throw IllegalStateException("Android context not available")
        // SKIP INSERT: capturer.initialize(helper, ctx, lifecycleObserver)
        // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Starting screen capture at ${width}x${height}@${fps}fps")
        // SKIP INSERT: capturer.startCapture(width, height, fps)

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            helper.dispose()
            // SKIP INSERT: AndroidScreenCaptureForeground.stopIfRunning()
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient closed during screen capture startup")
        }
        if screenCapturer != nil {
            helper.dispose()
            return
        }
        screenSurfaceTextureHelper = helper
        // SKIP INSERT: this.screenCaptureLifecycleObserver = lifecycleObserver
        // SKIP INSERT: this.screenCapturer = capturer
    }

    /// Stops the screen capturer and releases screen-specific resources.
    public func stopScreenCapture() {
        // Snapshot and clear state under the lock, then perform capturer/track teardown outside
        // it. `stopCapture`, `dispose`, and `setEnabled` block on WebRTC internal threads, and the
        // signaling thread takes this same lock in `triggerRTCEvent` — holding it here can
        // deadlock the whole client.
        let capturerToStop: org.webrtc.VideoCapturer?
        let helperToDispose: org.webrtc.SurfaceTextureHelper?
        let trackToDisable: RTCVideoTrack?

        lock.lock()
        capturerToStop = screenCapturer
        helperToDispose = screenSurfaceTextureHelper
        trackToDisable = screenVideoTrack
        screenCapturer = nil
        screenCaptureLifecycleObserver = nil
        screenCaptureStartedHandler = nil
        screenProjectionStoppedHandler = nil
        screenSurfaceTextureHelper = nil
        lock.unlock()

        // SKIP INSERT: (capturerToStop as? org.webrtc.ScreenCapturerAndroid)?.stopCapture()
        // SKIP INSERT: (capturerToStop as? org.webrtc.ScreenCapturerAndroid)?.dispose()
        let _ = capturerToStop

        helperToDispose?.dispose()
        frameCryptorSupport.disposeScreenSender()

        trackToDisable?._isEnabled = false

        // SKIP INSERT: AndroidMediaProjectionResultHolder.clear()
        // SKIP INSERT: AndroidScreenCaptureForeground.stopIfRunning()
    }

    /// Enables or disables the local screen video track.
    public func setScreenVideoEnabled(_ enabled: Bool) {
        // Snapshot under the lock, mutate outside it: `MediaStreamTrack.setEnabled` is a
        // synchronous proxy onto the WebRTC signaling thread, and that thread re-enters
        // `triggerRTCEvent` (which takes this lock) during renegotiation callbacks.
        // Holding the lock across the proxied call deadlocks the whole client (ANR).
        lock.lock()
        let track = isClosed ? nil : screenVideoTrack
        lock.unlock()
        track?._isEnabled = enabled
    }

    /// Returns the first remote screen video track by finding a transceiver whose track ID starts with `screen_`.
    /// For 1:1 calls — group calls should use ``getRemoteScreenVideoTrackById``.
    public func getRemoteScreenVideoTrack(peerConnection: RTCPeerConnection) -> RTCVideoTrack? {
        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()
        guard !isClosedCheck else { return nil }

        guard let pc = peerConnection.platformPeerConnection else { return nil }
        return AndroidWebRTCTrackResolver.firstRemoteScreenTrack(peerConnection: pc)
    }

    /// Enables or disables the local audio track.
    public func setAudioEnabled(_ enabled: Bool) {
        // See setScreenVideoEnabled: never hold `lock` across the proxied setEnabled call.
        lock.lock()
        let track = isClosed ? nil : localAudioTrack
        lock.unlock()
        track?._setEnabled(enabled)
    }
    
    /// Enables or disables the local video track.
    public func setVideoEnabled(_ enabled: Bool) {
        // See setScreenVideoEnabled: never hold `lock` across the proxied setEnabled call.
        lock.lock()
        let track = isClosed ? nil : localVideoTrack
        lock.unlock()
        track?._setEnabled(enabled)
    }

    // MARK: - Adaptive sender control helpers
    //
    // These are Android equivalents of Apple `RTCRtpSender.parameters.encodings` tuning.
    // They are used by `RTCSession` for SFU/group calls so the sender doesn't overshoot uplink,
    // and can ramp up quality on good internet.
    public func setVideoSenderEncodings(maxBitrateBps: Int, maxFramerate: Int, scaleResolutionDownBy: Double) {
        // `pc.senders` / `sender.parameters` are synchronous proxies onto the WebRTC signaling
        // thread. Never hold `lock` across them: the signaling thread takes this same lock in
        // `triggerRTCEvent`, so holding it here deadlocks the client (main-thread ANR at end call).
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { return }
        // SKIP INSERT: val pc = this@AndroidRTCClient.peerConnection?.platformPeerConnection ?: return
        // SKIP INSERT: val senders = pc.senders
        // SKIP INSERT: val videoSender = senders.firstOrNull { it.track()?.kind() == "video" } ?: return
        // SKIP INSERT: val params = videoSender.parameters
        // SKIP INSERT: val encodings = params.encodings
        // SKIP INSERT: if (encodings == null || encodings.isEmpty()) return
        // SKIP INSERT: for (enc in encodings) {
        // SKIP INSERT:   enc.maxBitrateBps = maxBitrateBps
        // SKIP INSERT:   enc.maxFramerate = maxFramerate
        // SKIP INSERT:   enc.scaleResolutionDownBy = scaleResolutionDownBy
        // SKIP INSERT: }
        // SKIP INSERT: videoSender.parameters = params
    }

    public func getAvailableOutgoingBitrateBps() async -> Double? {
        var availableOutgoingBitrate: Double? = nil
        // SKIP INSERT: lock.lock()
        // SKIP INSERT: val closed = isClosed
        // SKIP INSERT: val pc = peerConnection?.platformPeerConnection
        // SKIP INSERT: lock.unlock()
        // SKIP INSERT: val shouldReadStats = !closed && pc != null
        // SKIP INSERT: var best: Double? = null
        // SKIP INSERT: if (shouldReadStats) {
        // SKIP INSERT:   val peer = pc!!
        // SKIP INSERT:   val latch = java.util.concurrent.CountDownLatch(1)
        // SKIP INSERT:   peer.getStats { report ->
        // SKIP INSERT:     val statsMap = report.statsMap
        // SKIP INSERT:     for ((_, stat) in statsMap) {
        // SKIP INSERT:       if (stat.type != "candidate-pair") continue
        // SKIP INSERT:       val selected = (stat.members["selected"] as? Boolean) ?: false
        // SKIP INSERT:       val nominated = (stat.members["nominated"] as? Boolean) ?: false
        // SKIP INSERT:       val state = (stat.members["state"] as? String)?.lowercase() ?: ""
        // SKIP INSERT:       if (!(selected || (nominated && state == "succeeded"))) continue
        // SKIP INSERT:       val v = stat.members["availableOutgoingBitrate"]
        // SKIP INSERT:       val d = when (v) {
        // SKIP INSERT:         is Double -> v
        // SKIP INSERT:         is Long -> v.toDouble()
        // SKIP INSERT:         is Int -> v.toDouble()
        // SKIP INSERT:         is Number -> v.toDouble()
        // SKIP INSERT:         else -> null
        // SKIP INSERT:       }
        // SKIP INSERT:       if (d != null) { best = d; break }
        // SKIP INSERT:     }
        // SKIP INSERT:     latch.countDown()
        // SKIP INSERT:   }
        // SKIP INSERT:   latch.await(1500, java.util.concurrent.TimeUnit.MILLISECONDS)
        // SKIP INSERT: }
        // SKIP INSERT: availableOutgoingBitrate = best
        return availableOutgoingBitrate
    }

    public func getInboundRemoteVideoCounters() async -> AndroidInboundVideoCounters? {
        var packetsReceived: Int64 = 0
        var framesDecoded: Int64 = 0
        var didReadStats = false
        // SKIP INSERT: lock.lock()
        // SKIP INSERT: val closed = isClosed
        // SKIP INSERT: val pc = peerConnection?.platformPeerConnection
        // SKIP INSERT: lock.unlock()
        // SKIP INSERT: val shouldReadStats = !closed && pc != null
        // SKIP INSERT: if (shouldReadStats) {
        // SKIP INSERT:   val peer = pc!!
        // SKIP INSERT:   val latch = java.util.concurrent.CountDownLatch(1)
        // SKIP INSERT:   peer.getStats { report ->
        // SKIP INSERT:     val statsMap = report.statsMap
        // SKIP INSERT:     var videoPackets = 0L
        // SKIP INSERT:     var videoFramesDecoded = 0L
        // SKIP INSERT:     for ((_, stat) in statsMap) {
        // SKIP INSERT:       if (stat.type != "inbound-rtp") continue
        // SKIP INSERT:       val kind = (stat.members["kind"] as? String ?: stat.members["mediaType"] as? String ?: "").lowercase()
        // SKIP INSERT:       if (kind != "video") continue
        // SKIP INSERT:       val packets = when (val v = stat.members["packetsReceived"]) {
        // SKIP INSERT:         is Long -> v
        // SKIP INSERT:         is Int -> v.toLong()
        // SKIP INSERT:         is Number -> v.toLong()
        // SKIP INSERT:         else -> 0L
        // SKIP INSERT:       }
        // SKIP INSERT:       val decoded = when (val v = stat.members["framesDecoded"]) {
        // SKIP INSERT:         is Long -> v
        // SKIP INSERT:         is Int -> v.toLong()
        // SKIP INSERT:         is Number -> v.toLong()
        // SKIP INSERT:         else -> 0L
        // SKIP INSERT:       }
        // SKIP INSERT:       videoPackets += packets
        // SKIP INSERT:       videoFramesDecoded += decoded
        // SKIP INSERT:     }
        // SKIP INSERT:     packetsReceived = videoPackets
        // SKIP INSERT:     framesDecoded = videoFramesDecoded
        // SKIP INSERT:     didReadStats = true
        // SKIP INSERT:     latch.countDown()
        // SKIP INSERT:   }
        // SKIP INSERT:   latch.await(1500, java.util.concurrent.TimeUnit.MILLISECONDS)
        // SKIP INSERT: }
        guard didReadStats else { return nil }
        return AndroidInboundVideoCounters(
            packetsReceived: packetsReceived,
            framesDecoded: framesDecoded
        )
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
        // Only use the lock to read/update local state. Do not hold it while calling WebRTC APIs
        // like `addTrack`/`addTransceiver`, because those can synchronously re-enter our observer
        // callbacks and deadlock on this same lock.
        let platformPeerConnection: org.webrtc.PeerConnection
        let trackToReturn: RTCVideoTrack?
        do {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
            }
            
            guard let pc = self.peerConnection?.platformPeerConnection else {
                lock.unlock()
                throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
            }
            
            if videoSource == nil {
                _ = createVideoSource(false)
            }
            if localVideoTrack == nil, let videoSource {
                _ = createVideoTrack(id: id, videoSource)
            }
            
            platformPeerConnection = pc
            trackToReturn = localVideoTrack
            lock.unlock()
        }
        
        // Ensure a video transceiver exists
        let hasVideo = AndroidWebRTCTrackResolver.videoTransceiverCount(peerConnection: platformPeerConnection) > 0
        if !hasVideo {
            let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
            platformPeerConnection.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, initOpts)
        }
        
        if let track = trackToReturn {
            var ids = [String]()
            ids.append("stream_\(id)")
            _ = platformPeerConnection.addTrack(track.platformTrack, ids.toList())
        }
        AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: platformPeerConnection)
        
        // Keep negotiation lightweight: create and attach the local track now, but defer camera
        // capture until the PeerConnection is actually connected.
        
        return trackToReturn
    }

    /// Starts camera capture after signaling/ICE has reached a stable connected state.
    ///
    /// Creating a sender track is cheap and needed for SDP. Starting Camera2 is not: on Android it
    /// competes with Firebase broadcast handling, EglRenderer, audio, and encrypted signaling during
    /// the fragile `connecting` window.
    public func startLocalVideoCaptureIfNeeded(fps: Int = 15, useFrontCamera: Bool = true) {
        // `track.enabled()` is a proxied WebRTC call; read it outside the lock (see
        // setScreenVideoEnabled for the deadlock this avoids).
        lock.lock()
        guard !isClosed,
              videoCapturer == nil,
              !localVideoCaptureStartInFlight,
              let localVideoTrack = localVideoTrack else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard localVideoTrack._isEnabled else { return }

        lock.lock()
        guard !isClosed, videoCapturer == nil, !localVideoCaptureStartInFlight else {
            lock.unlock()
            return
        }
        localVideoCaptureStartInFlight = true
        lock.unlock()

        // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Launching deferred local video capture startup")
        Task.detached { [weak self] in
            guard let self else { return }
            defer { self.markLocalVideoCaptureStartFinished() }
            do {
                try self.startLocalVideo(fps: fps, useFrontCamera: useFrontCamera)
                // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Deferred local video capture started")
            } catch {
                // SKIP INSERT: android.util.Log.e("AndroidRTCClient", "Failed to start deferred local video capture")
            }
        }
    }

    private func markLocalVideoCaptureStartFinished() {
        lock.lock()
        localVideoCaptureStartInFlight = false
        lock.unlock()
    }
    
    private struct Format: Hashable, Sendable {
        let isLandscape: Bool
        let width: Int
        let height: Int
    }
    
    private var formats = Set<Format>()
    
    /// Starts camera capture and feeds frames into the current local video source.
    ///
    /// - Parameters:
    ///   - fps: Target capture framerate.
    ///   - useFrontCamera: Whether to prefer the front-facing camera.
    /// - Throws: `RTCClientErrors` if capture cannot be started.
    private func startLocalVideo(fps: Int = 15, useFrontCamera: Bool = true) throws {
        let existingVideoSource: RTCVideoSource
        let staleHelper: org.webrtc.SurfaceTextureHelper?

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }

        guard let ctx = ProcessInfo.processInfo.androidContext else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("Android context not available")
        }

        guard let videoSource = videoSource else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("Video source not initialized")
        }

        if videoCapturer != nil {
            lock.unlock()
            return
        }

        existingVideoSource = videoSource
        staleHelper = surfaceTextureHelper
        surfaceTextureHelper = nil
        lock.unlock()

        // Ensure EGL base exists for SurfaceTextureHelper
        do {
            try ensureEglBase()
        } catch {
            throw RTCClientErrors.peerConnectionError("Failed to ensure EGL base: \(error.localizedDescription)")
        }

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        guard let eglBase = eglBase else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("EGL base is nil after ensureEglBase")
        }
        lock.unlock()

        // Dispose old helper outside the lock; disposal can call into EGL/GL code.
        staleHelper?.dispose()

        let helper = org.webrtc.SurfaceTextureHelper.create("WebRTCCapture", eglBase.eglBaseContext)
        guard let helper else {
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

        let downstream = existingVideoSource.platformSource.getCapturerObserver()
        /* Camera only: softening reads the cached prefs; screen share passes allowAppearanceSoftening=false. */
        // SKIP INSERT: AndroidCaptureUIPreferenceCache.refreshFromStoredPreferences()
        let proxy = CapturerObserverProxy(
            downstream: downstream,
            normalizeToUpright: true)
        // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Initializing camera capturer")
        capturer.initialize(helper, ctx, proxy)

        guard let supportedFormats = enumerator.getSupportedFormats(cameraName) else {
            throw RTCClientErrors.peerConnectionError("No supported formats for camera: \(cameraName)")
        }

        formats.removeAll()
        for fmt in supportedFormats {
            formats.insert(Format(
                isLandscape: fmt.width > fmt.height ? true : false,
                width: fmt.width,
                height: fmt.height))
        }
        
        // Start from a usable camera size and let WebRTC/adaptive sender encodings scale down when
        // bandwidth or CPU is constrained. Requiring a rotated format pair can incorrectly pin some
        // Android front cameras to 320x240 even when they support a much better landscape format.
        let preferredMaxPixels = 1280 * 720
        let preferredCandidates = formats.filter { $0.width * $0.height <= preferredMaxPixels }
        let selectableCandidates = preferredCandidates.isEmpty ? formats : preferredCandidates

        if let selectedLandscape = selectableCandidates
            .filter({ $0.isLandscape })
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Starting camera capture: " + selectedLandscape.width + "x" + selectedLandscape.height + "@" + fps + "fps")
            capturer.startCapture(Int32(selectedLandscape.width), Int32(selectedLandscape.height), Int32(fps))
        } else if let selectedPortrait = selectableCandidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            // SKIP INSERT: android.util.Log.i("AndroidRTCClient", "Starting camera capture: " + selectedPortrait.width + "x" + selectedPortrait.height + "@" + fps + "fps")
            capturer.startCapture(Int32(selectedPortrait.width), Int32(selectedPortrait.height), Int32(fps))
        } else {
            throw RTCClientErrors.peerConnectionError("No suitable video format found")
        }

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }

        if videoCapturer != nil {
            helper.dispose()
            return
        }

        surfaceTextureHelper = helper
        videoCapturer = capturer
    }
    
    /// Stops camera capture and releases capture-related resources.
    public func stopLocalVideo() {
        // Snapshot under the lock, tear down outside it: `stopCapture` blocks on the camera
        // thread and `SurfaceTextureHelper.dispose` blocks on its handler thread. The WebRTC
        // signaling thread takes this same lock in `triggerRTCEvent`, so blocking while holding
        // it can deadlock the whole client.
        let capturerToStop: org.webrtc.Camera2Capturer?
        let helperToDispose: org.webrtc.SurfaceTextureHelper?

        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        capturerToStop = videoCapturer
        helperToDispose = surfaceTextureHelper
        videoCapturer = nil
        surfaceTextureHelper = nil
        localVideoCaptureStartInFlight = false
        lock.unlock()

        capturerToStop?.stopCapture()
        helperToDispose?.dispose()
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
        let closed = isClosed
        lock.unlock()
        
        guard !closed else {
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }

        lock.lock()
        let alreadyInitialized = activeSurfaceRenderers.contains(renderer)
        lock.unlock()

        if alreadyInitialized {
            AndroidRTCViewSupport.configureRenderer(renderer: renderer, mirror: mirror)
            return
        }
        
        // Ensure EGL is available prior to renderer init
        do {
            try ensureEglBase()
        } catch {
            throw RTCClientErrors.peerConnectionError("Failed to ensure EGL base: \(error.localizedDescription)")
        }
        
        lock.lock()
        let currentEglBase = eglBase
        lock.unlock()

        guard let currentEglBase else {
            throw RTCClientErrors.peerConnectionError("EGL base is nil after ensureEglBase")
        }

        AndroidRTCViewSupport.initializeSurfaceRenderer(
            renderer: renderer,
            eglBase: currentEglBase,
            mirror: mirror,
            releaseBeforeInit: true,
            logTag: "AndroidRTCClient"
        )

        lock.lock()
        activeSurfaceRenderers.insert(renderer)
        lock.unlock()

        // Remote frames already carry WebRTC rotation metadata (`VideoFrame.rotation`) and
        // SurfaceViewRenderer applies it while preserving aspect ratio.
    }

    /// Best-effort renderer initialization for Compose `AndroidView` factories.
    ///
    /// Compose treats exceptions thrown during view factory creation as fatal. On Android rejoin,
    /// stale surfaces or a just-reset RTC client can briefly make renderer init fail; keep the
    /// activity alive and let the next composition/state update retry.
    public func safelyInitializeSurfaceRenderer(
        _ renderer: org.webrtc.SurfaceViewRenderer,
        mirror: Bool = false
    ) -> Bool {
        do {
            try initializeSurfaceRenderer(renderer, mirror: mirror)
            return true
        } catch {
            AndroidRTCViewSupport.logSurfaceRendererInitFailure()
            return false
        }
    }

    /// Reinitializes a renderer after its Android `SurfaceView` changes dimensions.
    ///
    /// Grid relayout can shrink a tile from full-screen to a split grid cell while the EGL
    /// framebuffer stays at the old size, which rejects swap buffers and stalls remote video.
    public func reinitializeSurfaceRenderer(
        _ renderer: org.webrtc.SurfaceViewRenderer,
        mirror: Bool = false
    ) -> Bool {
        lock.lock()
        let closed = isClosed
        activeSurfaceRenderers.remove(renderer)
        lock.unlock()

        guard !closed else {
            AndroidRTCViewSupport.logSurfaceRendererInitFailure()
            return false
        }

        AndroidRTCViewSupport.releaseRenderer(renderer, "AndroidRTCClient")

        do {
            try ensureEglBase()
        } catch {
            AndroidRTCViewSupport.logSurfaceRendererInitFailure()
            return false
        }

        lock.lock()
        let currentEglBase = eglBase
        lock.unlock()

        guard let currentEglBase else {
            AndroidRTCViewSupport.logSurfaceRendererInitFailure()
            return false
        }

        // Renderer was already released above; init must not release again.
        AndroidRTCViewSupport.initializeSurfaceRenderer(
            renderer: renderer,
            eglBase: currentEglBase,
            mirror: mirror,
            releaseBeforeInit: false,
            logTag: "AndroidRTCClient"
        )

        lock.lock()
        activeSurfaceRenderers.insert(renderer)
        lock.unlock()
        return true
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
        let currentEglBase = eglBase
        lock.unlock()
        
        AndroidRTCViewSupport.safeReleaseRenderer(renderer: renderer, eglBase: currentEglBase)
    }
    
    /// Attempts to fetch the first remote video track from the provided peer connection.
    ///
    /// This uses transceivers (Unified Plan) and returns the receiver's track if present.
    /// For 1:1 calls only — group calls should use ``getRemoteVideoTrackById``.
    public func peerConnectionIsUsableForTrackResolution(_ peerConnection: RTCPeerConnection) -> Bool {
        guard let pc = peerConnection.platformPeerConnection else { return false }
        return AndroidWebRTCTrackResolver.peerConnectionIsUsableForTransceiverLookup(peerConnection: pc)
    }

    public func peerConnectionTransportIsEstablished(_ peerConnection: RTCPeerConnection) -> Bool {
        guard let pc = peerConnection.platformPeerConnection else { return false }
        return AndroidWebRTCTrackResolver.peerConnectionTransportIsEstablished(peerConnection: pc)
    }

    public func getRemoteVideoTrack(peerConnection: RTCPeerConnection) -> RTCVideoTrack? {
        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        guard AndroidWebRTCTrackResolver.peerConnectionIsUsableForTransceiverLookup(peerConnection: pc) else {
            return nil
        }
        return AndroidWebRTCTrackResolver.firstRemoteCameraTrack(peerConnection: pc)
    }

    /// Returns the remote video track matching a specific trackId.
    ///
    /// For SFU group calls where multiple remote participants each have their own video
    /// transceiver, this method finds the exact track rather than returning the first one.
    public func getRemoteVideoTrackById(peerConnection: RTCPeerConnection, trackId: String) -> RTCVideoTrack? {
        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        guard AndroidWebRTCTrackResolver.peerConnectionIsUsableForTransceiverLookup(peerConnection: pc) else {
            return nil
        }
        return AndroidWebRTCTrackResolver.remoteCameraTrackById(peerConnection: pc, trackId: trackId)
    }

    /// Returns the remote video track matching a specific SDP MID.
    ///
    /// Android WebRTC can expose native receiver track ids that differ from the SFU's advertised
    /// `msid` track label after renegotiation. MID fallback still binds to the same negotiated
    /// transceiver, so group/conference tiles keep strict per-source ownership without reusing the
    /// first available video receiver.
    public func getRemoteVideoTrackByMid(peerConnection: RTCPeerConnection, mid: String) -> RTCVideoTrack? {
#if !SKIP
        let wantedMid = mid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wantedMid.isEmpty else { return nil }
#endif

        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        guard AndroidWebRTCTrackResolver.peerConnectionIsUsableForTransceiverLookup(peerConnection: pc) else {
            return nil
        }
        return AndroidWebRTCTrackResolver.remoteCameraTrackByMid(peerConnection: pc, mid: mid)
    }

    /// Returns the remote audio track matching a specific trackId.
    public func getRemoteAudioTrackById(peerConnection: RTCPeerConnection, trackId: String) -> RTCAudioTrack? {
        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        return AndroidWebRTCTrackResolver.remoteAudioTrackById(peerConnection: pc, trackId: trackId)
    }

    /// Returns the remote audio track matching a specific SDP MID.
    public func getRemoteAudioTrackByMid(peerConnection: RTCPeerConnection, mid: String) -> RTCAudioTrack? {
#if !SKIP
        let wantedMid = mid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wantedMid.isEmpty else { return nil }
#endif

        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        return AndroidWebRTCTrackResolver.remoteAudioTrackByMid(peerConnection: pc, mid: mid)
    }

    /// Returns the remote screen video track matching a specific trackId.
    public func getRemoteScreenVideoTrackById(peerConnection: RTCPeerConnection, trackId: String) -> RTCVideoTrack? {
        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        return AndroidWebRTCTrackResolver.remoteScreenTrackById(peerConnection: pc, trackId: trackId)
    }

    /// Returns the remote screen video track on a specific transceiver mid.
    ///
    /// Remote track ids are immutable, so the contract screen mid's receiver never carries a
    /// `screen_` id nor the msid track token from a later renegotiation. Callers resolve the
    /// screen mid from the remote SDP and look the receiver up by mid instead.
    public func getRemoteScreenVideoTrackByMid(peerConnection: RTCPeerConnection, mid: String) -> RTCVideoTrack? {
        lock.lock()
        let isClosedCheck = isClosed
        lock.unlock()

        guard !isClosedCheck else { return nil }
        guard let pc = peerConnection.platformPeerConnection else { return nil }
        return AndroidWebRTCTrackResolver.remoteScreenTrackByMid(peerConnection: pc, mid: mid)
    }
   
    /// Ensures an audio transceiver is present with `SEND_RECV` and attaches a local audio track.
    ///
    /// This is used by `RTCSession` on Android to prepare audio media before negotiation.
    ///
    /// - Parameter id: An identifier used for stream/track labeling.
    public func prepareAudioSendRecv(id: String) async throws {
        // Only use the lock to read/update local state. Do not hold it while calling WebRTC APIs
        // like `addTrack`/`addTransceiver`, because those can synchronously re-enter our observer
        // callbacks and deadlock on this same lock.
        let platformPeerConnection: org.webrtc.PeerConnection
        let audioTrackToAdd: RTCAudioTrack?
        
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("AndroidRTCClient has been closed")
        }
        
        guard let pc = self.peerConnection?.platformPeerConnection else {
            lock.unlock()
            throw RTCClientErrors.peerConnectionError("PeerConnection not yet established")
        }
        
        if audioSource == nil {
            _ = createAudioSource(createConstraints())
        }
        if self.localAudioTrack == nil, let audioSource {
            _ = createAudioTrack(id: id, audioSource)
        }
        
        platformPeerConnection = pc
        audioTrackToAdd = self.localAudioTrack
        lock.unlock()
        
        // Add a transceiver if there isn't already one for audio
        let hasAudio = AndroidWebRTCTrackResolver.hasAudioTransceiver(peerConnection: platformPeerConnection)
        if !hasAudio {
            let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
            platformPeerConnection.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO, initOpts)
        }
        
        if let track = audioTrackToAdd {
            var ids = [String]()
            ids.append("stream_\(id)")
            _ = platformPeerConnection.addTrack(track.platformTrack, ids.toList())
        }
        AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: platformPeerConnection)
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
    
    private func setLocalDescription(_ sdp: RTCSessionDescription, completion: ((String?) -> Void)? = nil) throws {
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
        
        let obs = RTCOnSetObserver { [weak self] failureMessage in
            guard let self else { return }
            // Set-description success is a receiver-rotation boundary: mark the cached
            // transceiver snapshot stale so the next resolution refreshes it exactly once.
            if failureMessage == nil {
                AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: peerConnection)
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            completion?(failureMessage)
            self.pendingSetLocalObserver = nil
        }
        
        lock.lock()
        pendingSetLocalObserver = obs
        lock.unlock()
        
        peerConnection.setLocalDescription(obs, sdp.platform)
    }
    
    private func setRemoteDescription(_ sdp: RTCSessionDescription, completion: ((String?) -> Void)? = nil) throws {
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
        
        let obs = RTCOnSetObserver { [weak self] failureMessage in
            guard let self else { return }
            // Remote-description success is the receiver-rotation boundary after SFU
            // renegotiation: mark the cached transceiver snapshot stale so the rebind
            // sweep resolves fresh wrappers exactly once.
            if failureMessage == nil {
                AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: peerConnection)
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            completion?(failureMessage)
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
        let failureMessage: String? = try await withCheckedThrowingContinuation { continuation in
            try self.setLocalDescription(sdp) { failureMessage in
                continuation.resume(returning: failureMessage)
            }
        }
        if let failureMessage {
            throw RTCClientErrors.peerConnectionError(failureMessage)
        }
    }
    
    /// Sets the peer connection's remote description.
    public func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        let failureMessage: String? = try await withCheckedThrowingContinuation { continuation in
            try self.setRemoteDescription(sdp) { failureMessage in
                continuation.resume(returning: failureMessage)
            }
        }
        if let failureMessage {
            throw RTCClientErrors.peerConnectionError(failureMessage)
        }
    }

    /// Closes the current peer connection so relay fallback can recreate it on the same client.
    ///
    /// Unlike ``close()``, this keeps the factory, EGL base, frame-key provider, and process-global
    /// WebRTC initialization alive. Calling `close()` here makes `initializeFactory` fail forever on
    /// the same `AndroidRTCClient`, which turns an ICE retry into a native bridge crash.
    public func resetPeerConnectionForRetry() {
        let videoCapturerToStop: org.webrtc.Camera2Capturer?
        let screenCapturerToStop: org.webrtc.VideoCapturer?
        let surfaceTextureHelperToDispose: org.webrtc.SurfaceTextureHelper?
        let screenSurfaceTextureHelperToDispose: org.webrtc.SurfaceTextureHelper?
        let renderersToDetach: [org.webrtc.SurfaceViewRenderer]
        let peerConnectionToClose: org.webrtc.PeerConnection?
        let localVideoTrackToDispose: RTCVideoTrack?
        let screenVideoTrackToDispose: RTCVideoTrack?
        let localAudioTrackToDispose: RTCAudioTrack?
        let videoSourceToDispose: RTCVideoSource?
        let screenVideoSourceToDispose: RTCVideoSource?
        let audioSourceToDispose: RTCAudioSource?

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }

        videoCapturerToStop = videoCapturer
        screenCapturerToStop = screenCapturer
        surfaceTextureHelperToDispose = surfaceTextureHelper
        screenSurfaceTextureHelperToDispose = screenSurfaceTextureHelper
        renderersToDetach = Array(activeSurfaceRenderers)
        peerConnectionToClose = peerConnection?.platformPeerConnection
        localVideoTrackToDispose = localVideoTrack
        screenVideoTrackToDispose = screenVideoTrack
        localAudioTrackToDispose = localAudioTrack
        videoSourceToDispose = videoSource
        screenVideoSourceToDispose = screenVideoSource
        audioSourceToDispose = audioSource

        delegate = nil
        pendingOfferObserver = nil
        pendingAnswerObserver = nil
        pendingSetLocalObserver = nil
        pendingSetRemoteObserver = nil
        observer = nil

        activeSurfaceRenderers.removeAll()
        frameCryptorSupport.disposeAll()

        peerConnection = nil
        localVideoTrack = nil
        screenVideoTrack = nil
        localAudioTrack = nil
        videoSource = nil
        screenVideoSource = nil
        audioSource = nil
        videoCapturer = nil
        screenCapturer = nil
        surfaceTextureHelper = nil
        screenSurfaceTextureHelper = nil
        localVideoCaptureStartInFlight = false
        lock.unlock()

        if let videoTrack = localVideoTrackToDispose {
            for renderer in renderersToDetach {
                videoTrack.platformTrack.removeSink(renderer)
            }
        }

        videoCapturerToStop?.stopCapture()
        // SKIP INSERT: (screenCapturerToStop as? org.webrtc.ScreenCapturerAndroid)?.stopCapture()
        // SKIP INSERT: (screenCapturerToStop as? org.webrtc.ScreenCapturerAndroid)?.dispose()

        surfaceTextureHelperToDispose?.dispose()
        screenSurfaceTextureHelperToDispose?.dispose()

        AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: peerConnectionToClose)
        peerConnectionToClose?.close()
        peerConnectionToClose?.dispose()

        localVideoTrackToDispose?.dispose()
        screenVideoTrackToDispose?.dispose()
        localAudioTrackToDispose?.dispose()
        videoSourceToDispose?.dispose()
        screenVideoSourceToDispose?.dispose()
        audioSourceToDispose?.dispose()
    }
    
    /// Closes the peer connection and releases all WebRTC resources owned by this client.
    ///
    /// This method is idempotent; repeated calls are no-ops.
    public func close() {
        let videoCapturerToStop: org.webrtc.Camera2Capturer?
        let screenCapturerToStop: org.webrtc.VideoCapturer?
        let surfaceTextureHelperToDispose: org.webrtc.SurfaceTextureHelper?
        let screenSurfaceTextureHelperToDispose: org.webrtc.SurfaceTextureHelper?
        let renderersToRelease: [org.webrtc.SurfaceViewRenderer]
        let peerConnectionToClose: org.webrtc.PeerConnection?
        let localVideoTrackToDispose: RTCVideoTrack?
        let screenVideoTrackToDispose: RTCVideoTrack?
        let localAudioTrackToDispose: RTCAudioTrack?
        var videoSourceToDispose: RTCVideoSource?
        var screenVideoSourceToDispose: RTCVideoSource?
        var audioSourceToDispose: RTCAudioSource?
        let eglBaseToRelease: org.webrtc.EglBase?
        let factoryToDispose: org.webrtc.PeerConnectionFactory?

        lock.lock()

        // Prevent double cleanup
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true

        videoCapturerToStop = videoCapturer
        screenCapturerToStop = screenCapturer
        surfaceTextureHelperToDispose = surfaceTextureHelper
        screenSurfaceTextureHelperToDispose = screenSurfaceTextureHelper
        renderersToRelease = Array(activeSurfaceRenderers)
        peerConnectionToClose = peerConnection?.platformPeerConnection
        localVideoTrackToDispose = localVideoTrack
        screenVideoTrackToDispose = screenVideoTrack
        localAudioTrackToDispose = localAudioTrack
        videoSourceToDispose = videoSource
        screenVideoSourceToDispose = screenVideoSource
        audioSourceToDispose = audioSource
        eglBaseToRelease = eglBase
        factoryToDispose = factory

        // Clear delegate to prevent callbacks during cleanup
        delegate = nil

        activeSurfaceRenderers.removeAll()

        // Clear pending observers
        pendingOfferObserver = nil
        pendingAnswerObserver = nil
        pendingSetLocalObserver = nil
        pendingSetRemoteObserver = nil
        observer = nil

        frameCryptorSupport.clearKeyProvider()
        keyProvider = nil
        keyProviderIsSharedKeyMode = nil
        keyProviderReady = false
        pendingPerParticipantKeys.removeAll()
        localVideoCaptureStartInFlight = false
        
        // Clear all references
        peerConnection = nil
        localVideoTrack = nil
        screenVideoTrack = nil
        localAudioTrack = nil
        videoSource = nil
        screenVideoSource = nil
        audioSource = nil
        eglBase = nil
        factory = nil
        lock.unlock()

        // WebRTC and EGL teardown can synchronously call observers or block on GL/camera threads.
        // Run it outside the state lock so Android end-call cannot deadlock or trap during cleanup.
        if let videoTrack = localVideoTrackToDispose {
            for renderer in renderersToRelease {
                videoTrack.platformTrack.removeSink(renderer)
            }
        }

        videoCapturerToStop?.stopCapture()
        // SKIP INSERT: (screenCapturerToStop as? org.webrtc.ScreenCapturerAndroid)?.stopCapture()
        // SKIP INSERT: (screenCapturerToStop as? org.webrtc.ScreenCapturerAndroid)?.dispose()

        surfaceTextureHelperToDispose?.dispose()
        screenSurfaceTextureHelperToDispose?.dispose()

        // SKIP INSERT: for (renderer in renderersToRelease) {
        // SKIP INSERT:     try {
        // SKIP INSERT:         val egl = eglBaseToRelease
        // SKIP INSERT:         if (egl != null && egl.eglBaseContext != null) {
        // SKIP INSERT:             renderer.release()
        // SKIP INSERT:         }
        // SKIP INSERT:     } catch (_: Throwable) {
        // SKIP INSERT:         // Ignore teardown-time renderer release failures.
        // SKIP INSERT:     }
        // SKIP INSERT: }

        AndroidWebRTCTrackResolver.invalidateTransceiverSnapshot(peerConnection: peerConnectionToClose)
        peerConnectionToClose?.close()
        peerConnectionToClose?.dispose()

        localVideoTrackToDispose?.dispose()
        screenVideoTrackToDispose?.dispose()
        localAudioTrackToDispose?.dispose()
        videoSourceToDispose?.dispose()
        screenVideoSourceToDispose?.dispose()
        audioSourceToDispose?.dispose()
        eglBaseToRelease?.release()
        factoryToDispose?.dispose()
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

    /// Best-effort track identifier for Android WebRTC callbacks that can race disposal.
    public var trackIdIfAvailable: String? {
        AndroidRTCViewSupport.trackIdIfAvailable(track: self)
    }

    /// Whether the underlying WebRTC track is still live (not disposed/ended).
    public var isLiveVideoTrack: Bool {
        AndroidRTCViewSupport.isLiveVideoTrack(track: self)
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

    /// Best-effort track identifier for Android WebRTC callbacks that can race disposal.
    public var trackIdIfAvailable: String? {
        AndroidRTCViewSupport.trackIdIfAvailable(track: self)
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
