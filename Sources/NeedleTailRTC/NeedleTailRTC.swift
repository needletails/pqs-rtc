//
//  RTCClient.swift
//  needle-tail-rtc
//
//  Created by Cole M on 9/9/25.
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
import Foundation
#if SKIP
import org.webrtc.__
import kotlin.__

// (Removed) Custom renderer protocol not required for SurfaceViewRenderer path

private final class RTCClientPeerObserver: NSObject, org.webrtc.PeerConnection.Observer, @unchecked Sendable {
    
    private unowned let client: RTCClient
    
    init(client: RTCClient) {
        self.client = client
    }
    
    override func onSignalingChange(newState: org.webrtc.PeerConnection.SignalingState) {
        // Minimal observer - only handle what's needed
    }
    
    override func onIceConnectionChange(newState: org.webrtc.PeerConnection.IceConnectionState) {
        // Minimal observer - only handle what's needed
    }
    
    override func onIceConnectionReceivingChange(receiving: Bool) {}
    
    override func onIceGatheringChange(observable: org.webrtc.PeerConnection.IceGatheringState) {
        // Minimal observer - only handle what's needed
    }
    
    override func onIceCandidate(candidate: org.webrtc.IceCandidate) {
        let ice = RTCIceCandidate(
            sdp: candidate.sdp,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex),
            sdpMid: candidate.sdpMid)
        client.observable.setLastIceCandidate(ice)
    }
    
    // Required no-op implementations to satisfy Observer interface
    override func onIceCandidatesRemoved(candidates: kotlin.Array<org.webrtc.IceCandidate>) {}
    override func onAddStream(stream: org.webrtc.MediaStream) {}
    override func onRemoveStream(stream: org.webrtc.MediaStream) {}
    override func onDataChannel(dc: org.webrtc.DataChannel) {}
    override func onRenegotiationNeeded() {}
    
    override func onAddTrack(receiver: org.webrtc.RtpReceiver, mediaStreams: kotlin.Array<org.webrtc.MediaStream>) {}
    
    override func onTrack(transceiver: org.webrtc.RtpTransceiver) {
        if let track = transceiver.receiver.track() {
            if let audioTrack = track as? org.webrtc.AudioTrack {
                let wrapped = RTCAudioTrack(audioTrack)
                client.observable.setRemoteAudioTrack(wrapped)
            } else if let videoTrack = track as? org.webrtc.VideoTrack {
                let custom = RTCVideoTrack(videoTrack)
                client.observable.setRemoteVideoTrack(custom)
            }
        }
    }
}

private final class RTCOnCreateSdpObserver: NSObject, org.webrtc.SdpObserver {
    
    private let callback: (RTCSessionDescription) -> Void
    init(_ callback: @escaping (RTCSessionDescription) -> Void) { self.callback = callback }
    
    override func onCreateSuccess(_ desc: org.webrtc.SessionDescription?) {
        guard let d = desc else { return }
        let s = RTCSessionDescription(type: d.type, sdp: d.description)
        callback(s)
    }
    
    override func onSetSuccess() {}
    override func onCreateFailure(_ error: String?) {}
    override func onSetFailure(_ error: String?) {}
}

private final class RTCOnSetObserver: NSObject, org.webrtc.SdpObserver {
    private let callback: () -> Void
    init(_ callback: (() -> Void)?) { self.callback = callback ?? {} }
    
    override func onSetSuccess() {
        callback()
    }
    
    override func onCreateSuccess(_ desc: org.webrtc.SessionDescription?) {}
    override func onCreateFailure(_ error: String?) {}
    override func onSetFailure(_ error: String?) {}
}

public struct RTCSessionDescription: Sendable {
    public let type: org.webrtc.SessionDescription.`Type`
    public let sdp: String
    
    public init(type: org.webrtc.SessionDescription.`Type`, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
    
    public var platform: org.webrtc.SessionDescription { org.webrtc.SessionDescription(type, sdp) }
}

public struct RTCIceCandidate: Sendable, Equatable {
    
    public let sdp: String
    public let sdpMLineIndex: Int32
    public let sdpMid: String?
    
    public init(sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }
    
    var platform: org.webrtc.IceCandidate {
        org.webrtc.IceCandidate(sdpMid, Int32(sdpMLineIndex), sdp)
    }
}

// Simplified observable - only what NeedleTailRTC actually uses
@MainActor
public final class RTCClientObservable {
    // Only keep properties that are actually used
    public var lastIceCandidate: RTCIceCandidate?
    public var remoteVideoTrack: RTCVideoTrack?
    public var remoteAudioTrack: RTCAudioTrack?
    
    public init() {}
    
    func setLastIceCandidate(_ candidate: RTCIceCandidate?) {
        self.lastIceCandidate = candidate
    }
    
    func setRemoteVideoTrack(_ track: RTCVideoTrack) {
        self.remoteVideoTrack = track
    }
    
    func setRemoteAudioTrack(_ track: RTCAudioTrack?) {
        self.remoteAudioTrack = track
    }
}

public final class RTCClient: @unchecked Sendable {
    
    public static let shared = RTCClient()
    
    public typealias OnLocalSDP = @Sendable (RTCSessionDescription) -> Void
    
    public let observable: RTCClientObservable = RTCClientObservable()
    private var observer: RTCClientPeerObserver?
    
    private var iceServers = [String]()
    private var factory: org.webrtc.PeerConnectionFactory?
    private var peerConnection: org.webrtc.PeerConnection?
    private var eglBase: org.webrtc.EglBase?
    private var videoSource: RTCVideoSource?
    private var audioSource: RTCAudioSource?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: org.webrtc.Camera2Capturer?
    private var surfaceTextureHelper: org.webrtc.SurfaceTextureHelper?
    
    private init() {}
    
    public func initializeFactory(iceServers: [String]) {
        self.iceServers = iceServers
        let initOptions = org.webrtc.PeerConnectionFactory.InitializationOptions
            .builder(ProcessInfo.processInfo.androidContext)
            .setEnableInternalTracer(false)
            .createInitializationOptions()
        org.webrtc.PeerConnectionFactory.initialize(initOptions)
        
        let egl = org.webrtc.EglBase.create()
        self.eglBase = egl
        
        let encoderFactory = org.webrtc.DefaultVideoEncoderFactory(egl.eglBaseContext, true, true)
        let decoderFactory = org.webrtc.DefaultVideoDecoderFactory(egl.eglBaseContext)
        let ctx = ProcessInfo.processInfo.androidContext
        let admBuilder = org.webrtc.audio.JavaAudioDeviceModule.builder(ctx)
        admBuilder.setUseHardwareAcousticEchoCanceler(true)
        admBuilder.setUseHardwareNoiseSuppressor(true)
        let audioModule = admBuilder.createAudioDeviceModule()
        let f = org.webrtc.PeerConnectionFactory
            .builder()
            .setOptions(org.webrtc.PeerConnectionFactory.Options())
            .setAudioDeviceModule(audioModule)
            .setVideoEncoderFactory(encoderFactory)
            .setVideoDecoderFactory(decoderFactory)
            .createPeerConnectionFactory()
        audioModule.release()
        self.factory = f
    }
    
    func createConstraints(_ mandatory: [String: String] = [:], optional: [String: String] = [:]) -> RTCMediaConstraints {
        let c = org.webrtc.MediaConstraints()
        for (k, v) in mandatory {
            c.mandatory.add(org.webrtc.MediaConstraints.KeyValuePair(k, v))
        }
        for (k, v) in optional {
            c.optional.add(org.webrtc.MediaConstraints.KeyValuePair(k, v))
        }
        return RTCMediaConstraints(c)
    }
    
    @discardableResult
    func createAudioSource(_ constraints: RTCMediaConstraints) -> RTCAudioSource {
        guard let factory else {
            fatalError("PeerConnectionFactory not initialized")
        }
        let src = RTCAudioSource(factory.createAudioSource(constraints.platformConstraints))
        self.audioSource = src
        return src
    }
    
    @discardableResult
    func createAudioTrack(id: String, _ audioSource: RTCAudioSource) -> RTCAudioTrack {
        guard let factory else {
            fatalError("PeerConnectionFactory not initialized")
        }
        let audioTrack = RTCAudioTrack(factory.createAudioTrack("audio_\(id)", audioSource.platformSource))
        self.localAudioTrack = audioTrack
        return audioTrack
    }
    
    func createVideoSource(_ isScreen: Bool = false) -> RTCVideoSource {
        guard let factory else {
            fatalError("PeerConnectionFactory not initialized")
        }
        let src = RTCVideoSource(factory.createVideoSource(isScreen))
        self.videoSource = src
        return src
    }
    
    func createVideoTrack(id: String, _ videoSource: RTCVideoSource) -> RTCVideoTrack {
        guard let factory else {
            fatalError("PeerConnectionFactory not initialized")
        }
        let track = RTCVideoTrack(factory.createVideoTrack("video_\(id)", videoSource.platformSource))
        self.localVideoTrack = track
        return track
    }
    
    public func setAudioEnabled(_ enabled: Bool) {
        localAudioTrack?._setEnabled(enabled)
    }
    
    public func setVideoEnabled(_ enabled: Bool) {
        localVideoTrack?._setEnabled(enabled)
    }
    
    // MARK: - Public Video APIs (no org.webrtc exposure)
    public func prepareVideoSendRecv(id: String = UUID().uuidString, useFrontCamera: Bool = true) {
        ensurePeerConnection()
        guard let pc = peerConnection else { return }
        
        if videoSource == nil {
            _ = createVideoSource(false)
        }
        if localVideoTrack == nil, let videoSource {
            _ = createVideoTrack(id: id, videoSource)
        }
        
        // Ensure a video transceiver exists
        let transceivers = pc.getTransceivers()
        let hasVideo = transceivers.firstOrNull { t in t.mediaType == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO } != nil
        if !hasVideo {
            let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
            pc.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, initOpts)
        }
        
        if let track = localVideoTrack {
            _ = pc.addTrack(track.platformTrack)
        }
        
        // Start capture with defaults
        startLocalVideo(useFrontCamera: useFrontCamera)
    }
    
    public func startLocalVideo(width: Int = 1280, height: Int = 720, fps: Int = 30, useFrontCamera: Bool = true) {
        guard let ctx = ProcessInfo.processInfo.androidContext else { return }
        guard let videoSource else { return }
        // Dispose old helper if any
        surfaceTextureHelper?.dispose()
        surfaceTextureHelper = org.webrtc.SurfaceTextureHelper.create("WebRTCCapture", eglBase?.eglBaseContext)
        
        // Select camera
        let enumerator = org.webrtc.Camera2Enumerator(ctx)
        let deviceNames = enumerator.deviceNames
        var selectedName: String? = nil
        for name in deviceNames where (useFrontCamera ? enumerator.isFrontFacing(name) : enumerator.isBackFacing(name)) {
            selectedName = name
            break
        }
        if selectedName == nil, let first = deviceNames.firstOrNull() { selectedName = first }
        guard let cameraName = selectedName else { return }
        
        // Initialize capturer
        let events = createCameraEventsHandler()
        let capturer = org.webrtc.Camera2Capturer(ctx, cameraName, events)
        videoCapturer = capturer
        if let helper = surfaceTextureHelper {
            capturer.initialize(helper, ctx, videoSource.platformSource.getCapturerObserver())
            capturer.startCapture(width, height, fps)
        }
    }
    
    public func stopLocalVideo() {
        if let capturer = videoCapturer {
            capturer.stopCapture()
        }
        surfaceTextureHelper?.dispose()
        surfaceTextureHelper = nil
        videoCapturer = nil
    }
    
    public func getLocalVideoTrack() -> RTCVideoTrack? {
        localVideoTrack
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
    
    private func ensurePeerConnection() {
        if factory == nil {
            fatalError("Factory must Be initialized before using")
        }
        guard peerConnection == nil, let factory else { return }
        var config = org.webrtc.PeerConnection.RTCConfiguration(
            iceServers.map { org.webrtc.PeerConnection.IceServer.builder($0).createIceServer() }.toList()
        )
        config.sdpSemantics = org.webrtc.PeerConnection.SdpSemantics.UNIFIED_PLAN
        config.continualGatheringPolicy = org.webrtc.PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        let obs = RTCClientPeerObserver(client: self)
        observer = obs
        peerConnection = factory.createPeerConnection(config, obs)
    }
    
    // MARK: - Android Renderer Helpers (Unified Plan)
    func initializeSurfaceRenderer(_ renderer: org.webrtc.SurfaceViewRenderer, mirror: Bool = false) {
        guard let eglBase else { return }
        // SKIP INSERT: renderer.init(eglBase!!.eglBaseContext, object : org.webrtc.RendererCommon.RendererEvents {
        // SKIP INSERT:     override fun onFirstFrameRendered() {}
        // SKIP INSERT:     override fun onFrameResolutionChanged(width: Int, height: Int, rotation: Int) {}
        // SKIP INSERT: })
        renderer.setMirror(mirror)
        renderer.setScalingType(org.webrtc.RendererCommon.ScalingType.SCALE_ASPECT_FILL)
    }
    
    func attach(_ track: RTCVideoTrack, to renderer: org.webrtc.SurfaceViewRenderer) {
        track.platformTrack.addSink(renderer)
    }
    
    func detach(_ track: RTCVideoTrack, from renderer: org.webrtc.SurfaceViewRenderer) {
        track.platformTrack.removeSink(renderer)
    }
    
    /// Ensure an audio transceiver is present with SEND_RECV and attach local track if available
    public func prepareAudioSendRecv(id: String = UUID().uuidString) {
        ensurePeerConnection()
        guard let pc = peerConnection else { return }
        
        if audioSource == nil {
            _ = createAudioSource(createConstraints())
        }
        if localAudioTrack == nil, let audioSource {
            _ = createAudioTrack(id: id, audioSource)
        }
        
        // Add a transceiver if there isn't already one for audio
        let transceivers = pc.getTransceivers()
        let hasAudio = transceivers.firstOrNull { t in t.mediaType == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO } != nil
        if !hasAudio {
            let initOpts = org.webrtc.RtpTransceiver.RtpTransceiverInit(org.webrtc.RtpTransceiver.RtpTransceiverDirection.SEND_RECV)
            pc.addTransceiver(org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO, initOpts)
        }
        
        if let track = localAudioTrack {
            // Optionally also addTrack for broader compatibility
            _ = pc.addTrack(track.platformTrack)
        }
    }
    
    private func createOffer(constraints: RTCMediaConstraints, completion: @escaping OnLocalSDP) {
        ensurePeerConnection()
        let obs = RTCOnCreateSdpObserver { [weak self] sdp in
            completion(sdp)
        }
        peerConnection?.createOffer(obs, constraints.platformConstraints)
    }
    
    private func createAnswer(constraints: RTCMediaConstraints, completion: @escaping OnLocalSDP) {
        ensurePeerConnection()
        let obs = RTCOnCreateSdpObserver { [weak self] sdp in
            completion(sdp)
        }
        peerConnection?.createAnswer(obs, constraints.platformConstraints)
    }
    
    private func setLocalDescription(_ sdp: RTCSessionDescription, completion: (() -> Void)? = nil) {
        let obs = RTCOnSetObserver(completion)
        peerConnection?.setLocalDescription(obs, sdp.platform)
    }
    
    private func setRemoteDescription(_ sdp: RTCSessionDescription, completion: (() -> Void)? = nil) {
        let obs = RTCOnSetObserver(completion)
        peerConnection?.setRemoteDescription(obs, sdp.platform)
    }
    
    public func addIceCandidate(_ candidate: RTCIceCandidate) {
        _ = peerConnection?.addIceCandidate(candidate.platform)
    }
    
    // MARK: - Public Offer/Answer Creation
    public func createOffer(constraints: RTCMediaConstraints) async -> RTCSessionDescription {
        await withCheckedContinuation { continuation in
            Task {
                self.createOffer(constraints: constraints) { sdp in continuation.resume(returning: sdp) }
            }
        }
    }
    
    public func createAnswer(constraints: RTCMediaConstraints) async -> RTCSessionDescription {
        await withCheckedContinuation { continuation in
            Task {
                self.createAnswer(constraints: constraints) { sdp in continuation.resume(returning: sdp) }
            }
        }
    }
    
    public func setLocalDescription(_ sdp: RTCSessionDescription) async {
        await withCheckedContinuation { continuation in
            Task {
                self.setLocalDescription(sdp) {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    public func setRemoteDescription(_ sdp: RTCSessionDescription) async {
        await withCheckedContinuation { continuation in
            Task {
                self.setRemoteDescription(sdp) {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    public func close() {
        // Close peer connection and release tracks/sources
        peerConnection?.close()
        localVideoTrack?.dispose()
        localAudioTrack?.dispose()
        videoSource?.dispose()
        audioSource?.dispose()
        eglBase?.release()
        factory?.dispose()
        
        peerConnection = nil
        localVideoTrack = nil
        localAudioTrack = nil
        videoSource = nil
        audioSource = nil
        eglBase = nil
        factory = nil
    }
}

public class RTCVideoTrack: Equatable {
    public let platformTrack: org.webrtc.VideoTrack
    
    public init(_ platformTrack: org.webrtc.VideoTrack) {
        self.platformTrack = platformTrack
    }
    
    public func _setEnabled(_ enabled: Bool) {
//        platformTrack.setEnabled(enabled)
    }
    
    public func dispose() {
        platformTrack.dispose()
    }
    
    public var _isEnabled: Bool {
        get {
            return platformTrack.enabled()
        }
        set {
            platformTrack.setEnabled(newValue)
        }
    }
    
    public var trackId: String {
        return platformTrack.id()
    }
}

public class RTCAudioTrack {
    public let platformTrack: org.webrtc.AudioTrack
    
    public init(_ platformTrack: org.webrtc.AudioTrack) {
        self.platformTrack = platformTrack
    }
    
    public func _setEnabled(_ enabled: Bool) {
//        platformTrack.setEnabled(enabled)
    }
    
    public func dispose() {
        platformTrack.dispose()
    }
    
    public var _isEnabled: Bool {
        get {
            return platformTrack.enabled()
        }
        set {
            platformTrack.setEnabled(newValue)
        }
    }
}

public class RTCVideoSource {
    public let platformSource: org.webrtc.VideoSource
    
    public init(_ platformSource: org.webrtc.VideoSource) {
        self.platformSource = platformSource
    }
    
    public func dispose() {
        platformSource.dispose()
    }
}

public class RTCAudioSource {
    public let platformSource: org.webrtc.AudioSource
    
    public init(_ platformSource: org.webrtc.AudioSource) {
        self.platformSource = platformSource
    }
    
    public func dispose() {
        platformSource.dispose()
    }
}

public class RTCMediaConstraints {
    public let platformConstraints: org.webrtc.MediaConstraints
    
    public init(_ platformConstraints: org.webrtc.MediaConstraints) {
        self.platformConstraints = platformConstraints
    }
}

#endif
