//
//  VideoCallViewController+UIKit.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
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

#if os(iOS)
@preconcurrency import WebRTC
import AVFoundation
import NeedleTailMediaKit
import NTKLoop
import UIKit
import NeedleTailLogger
@preconcurrency import AVKit
import CoreImage

@MainActor
/// iOS in-call UI controller.
///
/// This UIKit controller renders local/remote video for a single active call managed by
/// ``RTCSession``. It listens to the session's ``CallStateMachine`` stream, updates view
/// composition as the call transitions between voice/video, and drives rendering using
/// Metal-backed ``NTMTKView`` instances.
///
/// The host app typically embeds this controller using SwiftUI wrappers or presents it
/// directly, and receives high-level UI events via ``VideoCallDelegate`` / ``CallActionDelegate``.
public final class VideoCallViewController: UICollectionViewController {
    
    enum SectionType: Sendable {
        case fullscreen, conference
    }
    
    /// Delegate that receives high-level UI events (call state updates, errors, etc.).
    ///
    /// Held **strongly** so the SwiftUI `Coordinator` is not released while this controller is alive
    /// (`weak` here caused `localMuteDisplayDidChange` to no-op after layout cycles). Cleared in ``tearDownCall()``.
    public var videoCallDelegate: VideoCallDelegate?
    private let logger = NeedleTailLogger("[VideoCallViewController]")
    private let controllerView = ControllerView()
    private let videoViews = VideoViews()
    private unowned let session: RTCSession
    /// If `true`, the host app provides its own controls overlay via ``setControlsView(_:)``.
    public var usesEmbeddedControls = false
    /// For SwiftUI call chrome: re-sync toggle state after ``muteVideo()`` / ``muteAudio()`` (avoids optimistic UI drift).
    public var isLocalVideoMutedForDisplay: Bool { isMutingVideo }
    public var isLocalAudioMutedForDisplay: Bool { isMutingAudio }
    public func applyInitialLocalMuteDisplayState(videoMuted: Bool, audioMuted: Bool) {
        isMutingVideo = videoMuted
        isMutingAudio = audioMuted
    }

    public func updateConferenceRaisedHands(
        _ raisedHands: [String: Bool],
        topClearance: CGFloat = 0
    ) {
        conferenceRaisedHands = raisedHands
        conferenceRaisedHandBadgeTopClearance = topClearance
        applyConferenceRaisedHandBadges()
    }
    private weak var controlsView: UIView?
    private var duration: TimeInterval = 0
    private var isRunning = true
    private var showPip = false
    private var isMutingAudio = false
    private var isMutingVideo = false
    private var pipController: AVPictureInPictureController?
    private var pipVideoView: NTMTKView?
    private var pipSampleView: SampleCaptureView?
    private var pipSampleRenderer: SampleBufferViewRenderer?
    private var pipVideoCallViewController: AVPictureInPictureVideoCallViewController?
    /// Strong ref to the PiP-only ``RTCVideoRenderWrapper`` so we can always detach it from the remote track (avoids stacking sinks on repeated PiP attempts).
    private var pipAuxiliaryRenderWrapper: RTCVideoRenderWrapper?
    private var pipStartInFlight = false
    private var pipStopInFlight = false
    private weak var pipDelegate: PiPEventReceiverDelegate?
    private var currentCall: Call?
    private var currentCallState: CallStateMachine.State = .waiting
    private var dataSource: UICollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>?
    private var currentSectionType: SectionType = .fullscreen
    private let conferencePageSize = 12
    private let conferencePageIndicatorLabel = UILabel()
    private var lastConferencePageIndicatorSignature = ""
    private var lastConferenceLayoutBoundsSize: CGSize = .zero
    private var isMinimized = false
    private static let sections = CollectionViewSections()
    private var loadedPreviewItem = false
    private var speakerPhoneEnabled = false
    /// `NSObjectProtocol` is not `Sendable`; token is only used from main; `deinit` must remove it without isolation.
    nonisolated(unsafe) private var localVideoMirrorObserver: NSObjectProtocol?
    nonisolated(unsafe) private var preferredVideoCaptureDeviceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didEnterBackgroundPiPObserver: NSObjectProtocol?

    private var remoteVideoTrackPollTask: Task<Void, Never>?
    private var remoteRendererRecoveryTask: Task<Void, Never>?
    private var remoteRendererRecoveryConnectionId: String?
    private var remoteRendererRecoveryRendererId: ObjectIdentifier?
    private var lastRemoteRendererRecoveryUptimeNs: UInt64 = 0
    private var participantRendererRecoveryTasksByKey: [String: Task<Void, Never>] = [:]
    private var lastParticipantRendererRecoveryUptimeNsByKey: [String: UInt64] = [:]
    private weak var remoteCameraOffChrome: UIView?
    private var screenTrackStreamTask: Task<Void, Never>?
    private var participantTrackStreamTask: Task<Void, Never>?
    private var hasActiveRemoteScreenShare = false
    private var conferenceRaisedHands: [String: Bool] = [:]
    private var conferenceRaisedHandBadgeTopClearance: CGFloat = 0
    
    /// Creates an iOS call UI controller bound to a specific ``RTCSession``.
    public init(session: RTCSession) {
        self.session = session
        let layout = VideoCallViewController.createLayout(itemCount: 1)
        super.init(collectionViewLayout: layout)
        preferredContentSize = CGSize(width: 1080, height: 1920)
        view.addSubview(controllerView)
        controllerView.anchors(
            top: view.topAnchor,
            leading: view.leadingAnchor,
            bottom: view.bottomAnchor,
            trailing: view.trailingAnchor)
        controllerView.backgroundColor = .clear
    }
    
    required init?(coder: NSCoder) {
        assertionFailure("VideoCallViewController is intended to be initialized with init(session:)")
        return nil
    }
    
    deinit {
        if let localVideoMirrorObserver {
            NotificationCenter.default.removeObserver(localVideoMirrorObserver)
        }
        if let preferredVideoCaptureDeviceObserver {
            NotificationCenter.default.removeObserver(preferredVideoCaptureDeviceObserver)
        }
        if let didEnterBackgroundPiPObserver {
            NotificationCenter.default.removeObserver(didEnterBackgroundPiPObserver)
        }
#if DEBUG
        // Intentionally no print; rely on logger if needed
#endif
    }

    /// Task that consumes the session call-state stream and drives UI updates.
    var stateStreamTask: Task<Void, Never>?
    
    /// Subscribes to call state updates and updates UI + rendering accordingly.
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        collectionView.isScrollEnabled = false
        collectionView.delegate = self
        collectionView.allowsSelection = true
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Default `.automatic` insets the collection by the safe area, which letterboxes remote video.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = .zero
        if #available(iOS 13.0, *) {
            collectionView.verticalScrollIndicatorInsets = .zero
            collectionView.horizontalScrollIndicatorInsets = .zero
            collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        } else {
            collectionView.scrollIndicatorInsets = .zero
        }
        
        self.configureCollectionView()
        self.configureDataSource()
        self.setupConferencePageIndicator()

        localVideoMirrorObserver = NotificationCenter.default.addObserver(
            forName: PQSRTCCallUIPreferences.localVideoMirrorPreferenceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.applyLocalVideoMirroringFromUserDefaults() }
        }

        preferredVideoCaptureDeviceObserver = NotificationCenter.default.addObserver(
            forName: PQSRTCCallUIPreferences.preferredVideoCaptureDeviceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.applyPreferredVideoCaptureDeviceFromUserDefaults() }
        }

        didEnterBackgroundPiPObserver = NotificationCenter.default.addObserver(
            // `didEnterBackground` is too late for reliable PiP bring-up; request it while the app
            // is still resigning active so AVKit can complete the transition into PiP.
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.startPictureInPictureIfEligibleAfterBackgrounding()
            }
        }
        
        stateStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            // The host app may present this controller before `RTCSession.createStateStream(with:)`
            // has run (common on inbound CallKit answer flows). Wait until the stream exists rather
            // than failing fast and leaving the UI in a "no video" state.
            var stateStream: AsyncStream<CallStateMachine.State>?
            while !Task.isCancelled {
                if let s = await self.session.callState._currentCallStream.last {
                    stateStream = s
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
            }
            guard let stateStream else {
                logger.log(level: .error, message: "No call state stream available; cannot observe call state")
                return
            }

            // If we subscribed late, the state machine may have already advanced to `.connected`.
            // AsyncStream does not replay past values, so bootstrap UI from the current state first.
            if let current = await self.session.callState.currentState, current != self.currentCallState {
                self.currentCallState = current
                await videoCallDelegate?.deliverCallState(self.currentCallState)
                switch current {
                case .waiting:
                    break
                case .ready(let currentCall):
                    self.currentCall = currentCall
                case .connecting(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await self.createPreviewView()
                                self.bringControlsToFront()
                            }
                        }
                    }
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await self.createPreviewView(shouldQuery: true)
                            }
                            if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) == false {
                                await self.createSampleView()
                            }
                        }
                    }
                case .held(_, let currentCall):
                    self.currentCall = currentCall
                    break
                case .ended(_, _):
                    await tearDownCall()
                    dismiss(animated: true)
                case .failed(_, _, let errorMessage):
                    await videoCallDelegate?.passErrorMessage(errorMessage)
                    await tearDownCall()
                    dismiss(animated: true)
                case .callAnsweredAuxDevice:
                    await tearDownCall()
                    dismiss(animated: true)
                }
                self.syncVoiceCallChrome(with: self.currentCallState)
            }

            if let bootState = await self.session.callState.currentState {
                self.syncVoiceCallChrome(with: bootState)
            }
            
            for await state in stateStream {
                guard state != self.currentCallState else { continue }
                currentCallState = state
                await videoCallDelegate?.deliverCallState(currentCallState)
                
                switch state {
                case .waiting:
                    break
                case .ready(let currentCall):
                    self.currentCall = currentCall
                case .connecting(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            // Defensive: some call flows can emit `.connecting` more than once.
                            // Creating multiple preview views leaks capture/render resources and can
                            // explode memory. Ensure preview creation is idempotent.
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await self.createPreviewView()
                            }
                            self.bringControlsToFront()
                        }
                    }
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            // If we attached to the state stream late (e.g. after CallKit answer),
                            // we may observe `.connected` before `.connecting`. Ensure we still
                            // create the local preview so the user isn't staring at a black screen
                            // while the remote track/renegotiation settles.
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await self.createPreviewView(shouldQuery: true)
                            }
                            // Defensive: `.connected` can be re-emitted; avoid creating multiple
                            // sample renderers (each starts a render pipeline and can leak memory).
                            if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) == false {
                                await self.createSampleView()
                            }
                        }
                    }
                case .held(_, let currentCall):
                    self.currentCall = currentCall
                    break
                case .ended(_, _):
                    await tearDownCall()
                    dismiss(animated: true)
                case .failed(_, _, let errorMessage):
                    await videoCallDelegate?.passErrorMessage(errorMessage)
                    await tearDownCall()
                    dismiss(animated: true)
                case .callAnsweredAuxDevice:
                    await tearDownCall()
                    dismiss(animated: true)
                }
                self.syncVoiceCallChrome(with: self.currentCallState)
            }
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startRemoteScreenTrackObservation()
        startRemoteParticipantTrackObservation()
    }

    private func startRemoteScreenTrackObservation() {
        screenTrackStreamTask?.cancel()
        screenTrackStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.session.remoteScreenTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { return }
                if event.isActive {
                    await self.createScreenView(connectionId: event.connectionId, participantId: event.participantId)
                } else {
                    await self.tearDownScreenView(participantId: event.participantId)
                }
            }
        }
    }

    private func startRemoteParticipantTrackObservation() {
        participantTrackStreamTask?.cancel()
        participantTrackStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.session.remoteParticipantTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard event.kind == "video" else { continue }
                if event.isActive {
                    await self.createParticipantCameraView(
                        connectionId: event.connectionId,
                        participantId: event.participantId
                    )
                } else {
                    await self.tearDownParticipantCameraView(
                        connectionId: event.connectionId,
                        participantId: event.participantId
                    )
                }
            }
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let boundsSize = collectionView.bounds.size
        if currentSectionType == .conference,
           abs(boundsSize.width - lastConferenceLayoutBoundsSize.width) > 0.5 ||
            abs(boundsSize.height - lastConferenceLayoutBoundsSize.height) > 0.5 {
            lastConferenceLayoutBoundsSize = boundsSize
            collectionView.collectionViewLayout.invalidateLayout()
        }
        updateConferencePageIndicator()
    }

    public override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateConferencePageIndicator()
    }

    private func syncVoiceCallChrome(with state: CallStateMachine.State) {
        guard shouldPresentVoiceChrome(for: state) else {
            controllerView.setVoiceCallChromeVisible(false)
            return
        }
        let mono = Self.voiceMonogram(for: state)
        controllerView.setVoiceCallChromeVisible(true, monogram: mono)
    }

    private func shouldPresentVoiceChrome(for state: CallStateMachine.State) -> Bool {
        switch state {
        case .ready(let call), .connecting(_, let call), .connected(_, let call), .held(_, let call):
            return !call.supportsVideo
        default:
            return false
        }
    }

    private static func voiceMonogram(for state: CallStateMachine.State) -> String {
        let call: Call
        let direction: CallStateMachine.CallDirection?
        switch state {
        case .ready(let c):
            call = c
            direction = nil
        case .connecting(let d, let c):
            call = c
            direction = d
        case .connected(let d, let c):
            call = c
            direction = d
        case .held(let d, let c):
            call = c
            direction = d
        default:
            return ""
        }
        let name = remoteDisplayName(call: call, direction: direction)
        return initials(from: name)
    }

    private static func remoteDisplayName(call: Call, direction: CallStateMachine.CallDirection?) -> String {
        let participant: Call.Participant?
        if let direction {
            switch direction {
            case .inbound:
                participant = call.sender
            case .outbound:
                participant = call.recipients.first
            }
        } else {
            participant = call.recipients.first ?? call.sender
        }
        guard let p = participant else { return "" }
        let n = p.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? p.secretName : n
    }

    private static func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0.isWhitespace }).filter { !$0.isEmpty }
        if parts.count >= 2 {
            let a = parts[0].prefix(1)
            let b = parts[1].prefix(1)
            return String(a + b).uppercased()
        }
        if let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(first).uppercased()
        }
        return "?"
    }
    
    /// Tears down the controller's UI resources.
    ///
    /// This stops renderers, clears snapshots, removes blur overlays, cancels the state stream task,
    /// and notifies the host via ``VideoCallDelegate/endedCall(_:)``.
    private func tearDownCall() async {
        guard isRunning == true else {
            return
        }
        // Prevent concurrent teardown from running more than once
        isRunning = false

        speakerPhoneEnabled = false
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(true)
        try? audioSession.overrideOutputAudioPort(.none)
        controllerView.removeVoiceCallChrome()

        if let didEnterBackgroundPiPObserver {
            NotificationCenter.default.removeObserver(didEnterBackgroundPiPObserver)
            self.didEnterBackgroundPiPObserver = nil
        }

        pipController?.stopPictureInPicture()
        await dismantlePiPRenderingAndAuxiliaryTrack()
        pipController = nil

        screenTrackStreamTask?.cancel()
        screenTrackStreamTask = nil
        for model in videoViews.views where isScreenShareModel(model) {
            await tearDownScreenView(participantId: model.participantId)
        }
        hasActiveRemoteScreenShare = false
        participantTrackStreamTask?.cancel()
        participantTrackStreamTask = nil
        await tearDownAllParticipantCameraViews()

        await tearDownPreviewView()
        await tearDownSampleView()
        if let call = self.currentCall {
            await session.shutdown(with: call)
        }
        
        // Remove any remaining local preview view from the hierarchy
        if let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView {
            localView.removeFromSuperview()
        }
        
        // Clear blur if present
        controllerView.blurEffectView?.removeFromSuperview()
        controllerView.blurEffectView = nil

        videoViews.views.removeAll()
        deleteSnap()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        dataSource = nil
        self.currentCall = nil
        
        await videoCallDelegate?.endedCall(true)
        videoCallDelegate = nil
    }
    
    /// Ensures UI resources are released if the controller is dismissed.
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed
                || navigationController?.isBeingDismissed == true
                || isMovingFromParent
                || navigationController?.isMovingFromParent == true
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            logger.log(level: .debug, message: "VIEW WILL DISPPEAR")
            await tearDownCall()
        }
    }
    
    /// Creates and starts the local preview Metal view.
    ///
    /// - Parameter shouldQuery: If `true`, refreshes the diffable snapshot so the view is inserted
    ///   into the collection view before rendering begins.
    func createPreviewView(shouldQuery: Bool = true) async {
        // Idempotency: avoid creating duplicate preview views if call-state re-emits `.connecting`.
        if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) {
            if shouldQuery { await performQuery() }
            return
        }
        
        let localVideoView: NTMTKView
        do {
            localVideoView = try NTMTKView(type: .preview, contextName: "preview")
        } catch {
            logger.log(level: .error, message: "Failed to create preview view: \(error)")
            return
        }
        videoViews.views.append(.init(videoView: localVideoView))
        if shouldQuery {
            await performQuery()
        }
        
        await localVideoView.startRendering()
        if shouldQuery {
            await performQuery()
        }
        localVideoView.isUserInteractionEnabled = true
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        guard let previewRenderer = localVideoView.renderer as? PreviewViewRender else { return }
        
        await session.bindLocalPreviewCaptureRenderer(previewRenderer, connectionId: connectionId)
        await self.session.renderLocalVideo(to: previewRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        await applyCurrentLocalVideoMuteState(connectionId: connectionId)
        await applyLocalVideoMirroringFromUserDefaults()
    }

    private func applyLocalVideoMirroringFromUserDefaults() async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView,
              let renderer = localView.renderer as? PreviewViewRender else { return }
        await renderer.applyLocalVideoMirroringFromUserDefaults()
    }

    private func applyPreferredVideoCaptureDeviceFromUserDefaults() async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView,
              let renderer = localView.renderer as? PreviewViewRender else { return }
        await renderer.applyPreferredVideoCaptureDeviceFromUserDefaults()
    }
    
    /// Creates and starts the remote sample (receive) Metal view.
    ///
    /// - Parameter removePreview: If `true`, removes the preview from the collection snapshot
    ///   so the remote video takes the full screen; the preview is instead overlaid on top.
    func createSampleView(removePreview: Bool = true) async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if shouldUseParticipantCameraTiles() {
            await assignExistingParticipantTracks(connectionId: connectionId)
            await performQuery(removePreview: true)
            configureLocalPreviewIfNeeded()
            scheduleConnectedLocalPreviewStyleReapply()
            await applyCurrentLocalVideoMuteState(connectionId: connectionId)
            return
        }

        // Idempotency: avoid creating duplicate remote renderers if call-state re-emits `.connected`.
        if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) {
            configureLocalPreviewIfNeeded()
            scheduleConnectedLocalPreviewStyleReapply()
            await applyMainRemoteTileInboundExpectation(connectionId: connectionId)
            if let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView,
               let remoteRenderer = remoteView.renderer as? SampleBufferViewRenderer {
                startRemoteRendererRecoveryIfNeeded(renderer: remoteRenderer, connectionId: connectionId)
            }
            startRemoteVideoTrackPolling()
            return
        }
        
        let remoteVideoView: NTMTKView
        do {
            remoteVideoView = try NTMTKView(type: .sample, contextName: "sample")
        } catch {
            logger.log(level: .error, message: "Failed to create sample view: \(error)")
            return
        }
        videoViews.views.append(.init(videoView: remoteVideoView))
        await performQuery(removePreview: true)
        configureLocalPreviewIfNeeded()
        scheduleConnectedLocalPreviewStyleReapply()
        
        await remoteVideoView.startRendering()
        guard let remoteRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        pipDelegate = remoteRenderer
        await self.session.renderRemoteVideo(
            to: remoteRenderer.rtcVideoRenderWrapper,
            with: connectionId)
        await applyCurrentLocalVideoMuteState(connectionId: connectionId)
        await applyMainRemoteTileInboundExpectation(connectionId: connectionId)
        startRemoteRendererRecoveryIfNeeded(renderer: remoteRenderer, connectionId: connectionId)
        startRemoteVideoTrackPolling()
        _ = await preparePictureInPictureIfNeeded()
    }
    
    /// Stops capture and removes the local preview renderer from the session.
    func tearDownPreviewView() async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        guard let localVideoRenderer = localView.renderer as? PreviewViewRender else { return }
        await localVideoRenderer.stopCaptureSession()
        await localVideoRenderer.setCapture(nil)
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.removeLocal(renderer: localVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        localView.shutdownMetalStream()
    }
    
    /// Shuts down the remote renderer and removes it from the session.
    func tearDownSampleView() async {
        if shouldUseParticipantCameraTiles() {
            await tearDownAllParticipantCameraViews()
            return
        }
        stopRemoteVideoTrackPolling()
        stopRemoteRendererRecovery()
        guard let remoteVideoView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        guard let remoteVideoRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        await remoteVideoRenderer.setRemoteVideoInboundExpected(false)
        await remoteVideoRenderer.shutdown()
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.setVideoTrack(isEnabled: false, connectionId: connectionId)
        await session.removeRemote(renderer: remoteVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        remoteVideoView.shutdownMetalStream()
    }

    private func shouldUseParticipantCameraTiles() -> Bool {
        guard let call = currentCall else { return false }
        let normalizedSharedId = call.sharedCommunicationId.normalizedConnectionId
        return call.conferencePassword != nil
            || call.resolvedChannelWireId != nil
            || call.recipients.count > 1
            || normalizedSharedId.hasPrefix("conf-")
    }

    private func participantCameraContextName(_ participantId: String) -> String {
        "camera_\(participantId)"
    }

    private func shouldCreateParticipantCameraTile(participantId: String) -> Bool {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if UUID(uuidString: trimmed) != nil {
            logger.log(level: .info, message: "Skipping UUID-like SFU placeholder camera tile participant=\(trimmed)")
            return false
        }
        return true
    }

    private func isParticipantCameraModel(_ model: VideoViewModel) -> Bool {
        !model.isScreenShare
            && !model.participantId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.videoView.contextName.hasPrefix("camera_")
    }

    private func participantCameraModel(matching rawParticipantId: String) -> VideoViewModel? {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextName = participantCameraContextName(participantId)
        if let exact = videoViews.views.first(where: { $0.videoView.contextName == contextName }) {
            return exact
        }

        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return nil }
        return videoViews.views.first {
            isParticipantCameraModel($0)
                && RTCSession.conferenceParticipantIdentityKey($0.participantId) == participantKey
        }
    }

    private func isScreenShareModel(_ model: VideoViewModel) -> Bool {
        model.isScreenShare || model.videoView.contextName.hasPrefix("screen_")
    }

    private func screenShareModel(matching rawParticipantId: String, allowSingleFallback: Bool) -> VideoViewModel? {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextName = "screen_\(participantId)"
        if let exact = videoViews.views.first(where: { $0.videoView.contextName == contextName }) {
            return exact
        }

        let screenModels = videoViews.views.filter(isScreenShareModel)
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        if !participantKey.isEmpty,
           let normalized = screenModels.first(where: { RTCSession.conferenceParticipantIdentityKey($0.participantId) == participantKey }) {
            return normalized
        }

        if allowSingleFallback, screenModels.count == 1 {
            return screenModels.first
        }
        return nil
    }

    private func screenShareFirst(_ models: [VideoViewModel]) -> [VideoViewModel] {
        models.sorted { lhs, rhs in
            let lhsScreen = isScreenShareModel(lhs)
            let rhsScreen = isScreenShareModel(rhs)
            if lhsScreen != rhsScreen {
                return lhsScreen && !rhsScreen
            }
            let lhsName = lhs.participantId.isEmpty ? lhs.videoView.contextName : lhs.participantId
            let rhsName = rhs.participantId.isEmpty ? rhs.videoView.contextName : rhs.participantId
            if lhsName != rhsName {
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func assignExistingParticipantTracks(connectionId: String) async {
        guard shouldUseParticipantCameraTiles() else { return }
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await session.connectionManager.findConnection(with: normalizedId) else { return }
        for participantId in connection.remoteVideoTracksByParticipantId.keys.sorted() {
            guard shouldCreateParticipantCameraTile(participantId: participantId) else { continue }
            await createParticipantCameraView(connectionId: connectionId, participantId: participantId)
        }
    }

    private func createParticipantCameraView(connectionId: String, participantId rawParticipantId: String) async {
        guard shouldUseParticipantCameraTiles() else { return }
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantId.isEmpty else { return }
        guard shouldCreateParticipantCameraTile(participantId: participantId) else { return }
        let contextName = participantCameraContextName(participantId)
        if videoViews.views.contains(where: { $0.videoView.contextName == contextName }) {
            if let existingRenderer = videoViews.views.first(where: { $0.videoView.contextName == contextName })?.videoView.renderer as? SampleBufferViewRenderer {
                startParticipantRendererRecoveryIfNeeded(
                    renderer: existingRenderer,
                    connectionId: connectionId,
                    participantId: participantId
                )
            }
            return
        }

        let cameraView: NTMTKView
        do {
            cameraView = try NTMTKView(type: .sample, contextName: contextName)
        } catch {
            logger.log(level: .error, message: "Failed to create participant camera view: \(error)")
            return
        }

        let model = VideoViewModel(
            videoView: cameraView,
            participantId: participantId,
            connectionId: connectionId,
            isScreenShare: false
        )
        videoViews.views.append(model)
        await performQuery(removePreview: true)
        configureLocalPreviewIfNeeded()

        await cameraView.startRendering()
        guard let cameraRenderer = cameraView.renderer as? SampleBufferViewRenderer else {
            videoViews.views.removeAll(where: { $0.videoView.contextName == contextName })
            await performQuery(removePreview: true)
            logger.log(level: .error, message: "Participant camera renderer unavailable, removing orphan tile for participant=\(participantId)")
            return
        }

        let didAttach = await session.renderRemoteVideoForParticipant(
            to: cameraRenderer.rtcVideoRenderWrapper,
            connectionId: connectionId,
            participantId: participantId
        )
        guard didAttach else {
            await cameraRenderer.shutdown()
            cameraView.shutdownMetalStream()
            videoViews.views.removeAll(where: { $0.videoView.contextName == contextName })
            await performQuery(removePreview: true)
            logger.log(level: .warning, message: "Participant camera tile removed because no camera track was available for participant=\(participantId)")
            return
        }
        await cameraRenderer.setRemoteVideoInboundExpected(true)
        startParticipantRendererRecoveryIfNeeded(
            renderer: cameraRenderer,
            connectionId: connectionId,
            participantId: participantId
        )
        applyConferenceRaisedHandBadges()
        logger.log(level: .info, message: "Remote participant camera view created for participant=\(participantId)")
    }

    private func tearDownParticipantCameraView(connectionId: String, participantId rawParticipantId: String) async {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantId.isEmpty else { return }
        stopParticipantRendererRecovery(connectionId: connectionId, participantId: participantId)
        guard let model = participantCameraModel(matching: participantId) else { return }

        if let cameraRenderer = model.videoView.renderer as? SampleBufferViewRenderer {
            await cameraRenderer.setRemoteVideoInboundExpected(false)
            await session.removeRemoteForParticipant(
                renderer: cameraRenderer.rtcVideoRenderWrapper,
                connectionId: connectionId,
                participantId: model.participantId
            )
            await cameraRenderer.shutdown()
        }
        model.videoView.shutdownMetalStream()
        videoViews.views.removeAll(where: { $0.id == model.id })
        await performQuery(removePreview: true)
        logger.log(level: .info, message: "Remote participant camera view removed for participant=\(model.participantId) requestedParticipant=\(participantId)")
    }

    private func tearDownAllParticipantCameraViews() async {
        let cameraModels = videoViews.views.filter(isParticipantCameraModel)
        for model in cameraModels {
            await tearDownParticipantCameraView(
                connectionId: model.connectionId,
                participantId: model.participantId
            )
        }
        stopAllParticipantRendererRecovery()
    }
    
    /// Creates and renders a remote screen-share tile, promoting it to the dominant position.
    func createScreenView(connectionId: String, participantId: String) async {
        let contextName = "screen_\(participantId)"
        if screenShareModel(matching: participantId, allowSingleFallback: false) != nil { return }

        let screenView: NTMTKView
        do {
            screenView = try NTMTKView(type: .sample, contextName: contextName)
        } catch {
            logger.log(level: .error, message: "Failed to create screen share view: \(error)")
            return
        }

        let model = VideoViewModel(videoView: screenView, participantId: participantId, connectionId: connectionId)
        videoViews.views.insert(model, at: 0)
        hasActiveRemoteScreenShare = true
        await performQuery(removePreview: true)
        configureLocalPreviewIfNeeded()

        await screenView.startRendering()
        guard let screenRenderer = screenView.renderer as? SampleBufferViewRenderer else {
            videoViews.views.removeAll(where: { $0.videoView.contextName == contextName })
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isScreenShareModel)
            await performQuery(removePreview: true)
            logger.log(level: .error, message: "Screen share renderer unavailable, removing orphan tile for participant=\(participantId)")
            return
        }
        await session.renderRemoteScreenVideo(
            to: screenRenderer.rtcVideoRenderWrapper,
            connectionId: connectionId,
            participantId: participantId)
        await screenRenderer.setRemoteVideoInboundExpected(true)
        addPresenterBadge(to: screenView)

        await videoCallDelegate?.remoteScreenShareDidChange(participantId: participantId, isSharing: true)
        logger.log(level: .info, message: "Remote screen share view created for participant=\(participantId)")
    }

    /// Removes a remote screen-share tile and returns to normal layout.
    func tearDownScreenView(participantId: String) async {
        guard let model = screenShareModel(matching: participantId, allowSingleFallback: true) else {
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isScreenShareModel)
            await performQuery(removePreview: true)
            if !hasActiveRemoteScreenShare {
                await videoCallDelegate?.remoteScreenShareDidChange(participantId: participantId, isSharing: false)
            }
            logger.log(level: .warning, message: "Screen share teardown had no matching tile for participant=\(participantId); activeScreenShare=\(hasActiveRemoteScreenShare)")
            return
        }
        let actualParticipantId = model.participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendererParticipantId = actualParticipantId.isEmpty ? participantId : actualParticipantId
        let screenView = model.videoView
        if let screenRenderer = screenView.renderer as? SampleBufferViewRenderer {
            await screenRenderer.setRemoteVideoInboundExpected(false)
            await screenRenderer.shutdown()

            let connectionId = model.connectionId.isEmpty ? currentCall?.sharedCommunicationId : model.connectionId
            if let connectionId {
                await session.removeRemoteScreenVideoRenderer(
                    screenRenderer.rtcVideoRenderWrapper,
                    connectionId: connectionId,
                    participantId: rendererParticipantId)
            }
        }
        screenView.shutdownMetalStream()
        videoViews.removeView(model)
        hasActiveRemoteScreenShare = videoViews.views.contains(where: isScreenShareModel)
        await performQuery(removePreview: videoViews.views.contains(where: { $0.videoView.contextName == "sample" }))

        await videoCallDelegate?.remoteScreenShareDidChange(participantId: rendererParticipantId, isSharing: false)
        logger.log(level: .info, message: "Remote screen share view removed for participant=\(rendererParticipantId) requestedParticipant=\(participantId)")
    }

    /// Adds a "Presenting" badge to a screen-share tile (idempotent).
    private func addPresenterBadge(to view: NTMTKView) {
        let badgeTag = 9001
        if view.viewWithTag(badgeTag) != nil { return }

        let badge = UIView()
        badge.tag = badgeTag
        badge.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        badge.layer.cornerRadius = 6
        badge.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: "rectangle.inset.filled.and.person.filled"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        badge.addSubview(icon)

        let label = UILabel()
        label.text = "Presenting"
        label.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        badge.addSubview(label)

        view.addSubview(badge)
        badge.anchors(top: view.topAnchor, leading: view.leadingAnchor, paddingTop: 8, paddingLeft: 8)
        icon.anchors(leading: badge.leadingAnchor, centerY: badge.centerYAnchor, paddingLeft: 6, width: 14, height: 14)
        label.anchors(top: badge.topAnchor, leading: icon.trailingAnchor, bottom: badge.bottomAnchor, trailing: badge.trailingAnchor, paddingTop: 4, paddingLeft: 4, paddingBottom: 4, paddingRight: 8)
    }

    private func participantHasRaisedHand(_ participantId: String) -> Bool {
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }
        return conferenceRaisedHands.contains { key, value in
            value && RTCSession.conferenceParticipantIdentityKey(key) == participantKey
        }
    }

    private func removeRaisedHandBadge(from view: NTMTKView) {
        view.viewWithTag(9002)?.removeFromSuperview()
    }

    private func addRaisedHandBadge(to view: NTMTKView) {
        let badgeTag = 9002
        if view.viewWithTag(badgeTag) != nil { return }

        let badge = UIView()
        badge.tag = badgeTag
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.92)
        badge.layer.cornerRadius = 14
        badge.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: "hand.raised.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        badge.addSubview(icon)

        view.addSubview(badge)
        let topPadding = max(8, min(22, conferenceRaisedHandBadgeTopClearance * 0.25))
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: topPadding),
            badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    private func applyConferenceRaisedHandBadges() {
        for model in videoViews.views {
            guard isParticipantCameraModel(model) else {
                removeRaisedHandBadge(from: model.videoView)
                continue
            }
            if participantHasRaisedHand(model.participantId) {
                addRaisedHandBadge(to: model.videoView)
            } else {
                removeRaisedHandBadge(from: model.videoView)
            }
        }
    }

    /// Updates the preview layout when the interface rotates.
    public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await session.callState._callType == .video {
                guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
                // Disable our own animation here; UIKit already animates alongside rotation via coordinator.
                controllerView.updateLocalVideoSize(with: UIDevice.current.orientation, should: false, isConnected: isConnected() ? true : false, view: localView, animated: false)
                let pipSize = pictureInPictureLayoutSize()
                pipVideoCallViewController?.preferredContentSize = pipSize
                await pipSampleRenderer?.applyHostViewBounds(CGRect(origin: .zero, size: pipSize))
            }
        }
    }
    
    /// Returns `true` when the current call state is `.connected`.
    func isConnected() -> Bool {
        switch currentCallState {
        case .connected(_, _):
            return true
        default:
            return false
        }
    }
    
    /// Rebuilds and applies the diffable-data-source snapshot from the current Metal view list.
    func performQuery(removePreview: Bool = false) async {
        var snapshot = NSDiffableDataSourceSnapshot<ConferenceCallSections, VideoViewModel>()
        var data = await videoViews.getViews()
        if removePreview {
            data.removeAll(where: { $0.videoView.contextName == "preview" })
        }
        let hasScreenShareInData = data.contains(where: isScreenShareModel)
        if hasScreenShareInData {
            data = screenShareFirst(data)
        }
        updateLayoutForItemCount(data.count, hasScreenShare: hasScreenShareInData)
        if data.isEmpty {
            await dataSource?.apply(snapshot, animatingDifferences: false)
        } else {
            snapshot.appendSections([.initial])
            snapshot.appendItems(data, toSection: .initial)
            await dataSource?.apply(snapshot, animatingDifferences: false)
        }
        applyConferenceRaisedHandBadges()
        updateConferencePageIndicator(totalItems: data.count)
    }
    
    /// Ensures the local preview view is attached, gesture-enabled, and sized.
    private func configureLocalPreviewIfNeeded() {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        
        if localView.superview !== controllerView {
            controllerView.addSubview(localView)
        }
        controllerView.applyConnectedLocalPreviewCornerStyle(to: localView)
        localView.isAccessibilityElement = true
        localView.accessibilityLabel = "Local preview"
        
        // Enable dragging and tap-to-minimize on the local preview (single tap; waits for pan to fail so drag doesn’t double-toggle).
        let panGesture: UIPanGestureRecognizer = {
            if let existing = localView.gestureRecognizers?.compactMap({ $0 as? UIPanGestureRecognizer }).first(where: { $0.view === localView }) {
                return existing
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragPreviewView(_:)))
            localView.addGestureRecognizer(pan)
            return pan
        }()
        if let existingTap = localView.gestureRecognizers?.compactMap({ $0 as? UITapGestureRecognizer }).first(where: { $0.view === localView }) {
            existingTap.require(toFail: panGesture)
        } else {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tapPreviewView))
            tapGesture.require(toFail: panGesture)
            localView.addGestureRecognizer(tapGesture)
        }
        
        controllerView.updateLocalVideoSize(
            with: UIDevice.current.orientation,
            should: false,
            isConnected: isConnected(),
            view: localView,
            animated: true)
        controllerView.bringSubviewToFront(localView)
        controllerView.setNeedsLayout()
        controllerView.layoutIfNeeded()
        controllerView.applyConnectedLocalPreviewCornerStyle(to: localView)
        bringControlsToFront()
    }

    private func scheduleConnectedLocalPreviewStyleReapply() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isConnected() else { return }
            self.configureLocalPreviewIfNeeded()
        }
    }
    
    // MARK: - Controls view injection
    @MainActor
    /// Installs a custom controls overlay.
    ///
    /// This is primarily used when the host app wants to provide a bespoke control surface
    /// (mute/end/pip) while reusing PQSRTC's rendering and state wiring.
    public func setControlsView(_ view: UIView) {
        controlsView?.removeFromSuperview()
        controlsView = view
        controllerView.addSubview(view)
        view.anchors(
            top: controllerView.topAnchor,
            leading: controllerView.leadingAnchor,
            bottom: controllerView.bottomAnchor,
            trailing: controllerView.trailingAnchor
        )
        controllerView.bringSubviewToFront(view)
        bringControlsToFront()
    }
    
    private func bringControlsToFront() {
        if let controlsView {
            controllerView.bringSubviewToFront(controlsView)
        }
    }
    
    /// Clears any existing snapshot sections.
    func deleteSnap() {
        // Ensure the data source is available
        guard var snapshot = dataSource?.snapshot() else { return }
        
        // Delete the section and all its items
        snapshot.deleteSections([.initial])
        
        // Apply the updated snapshot to the data source
        dataSource?.apply(snapshot, animatingDifferences: true)
    }
    
    /// Registers collection view cell types required by the call UI.
    func configureCollectionView() {
        collectionView.register(RemoteViewItemCell.self, forCellWithReuseIdentifier: RemoteViewItemCell.reuseIdentifier)
    }
    
    /// Attaches a `VideoViewModel`'s view to a collection view cell.
    fileprivate func setCollectionViewItem(item: RemoteViewItemCell? = nil, viewModel: VideoViewModel) {
        guard let item = item else { return }
        item.setVideoView(viewModel.videoView)
    }
    
    /// Configures the diffable data source to render ``VideoViewModel`` items.
    func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>(collectionView: collectionView) { [weak self]
            (collectionView: UICollectionView, indexPath: IndexPath, model: VideoViewModel) -> UICollectionViewCell? in
            guard let self else { return nil }
            let section = ConferenceCallSections(rawValue: indexPath.section)!
            switch section {
            case .initial:
                if let item = collectionView.dequeueReusableCell(withReuseIdentifier: RemoteViewItemCell.reuseIdentifier, for: indexPath) as? RemoteViewItemCell {
                    self.setCollectionViewItem(item: item, viewModel: model)
                    if self.isScreenShareModel(model) {
                        self.addPresenterBadge(to: model.videoView)
                    }
                    return item
                } else {
                    assertionFailure("Could not dequeue RemoteViewItemCell")
                    return collectionView.dequeueReusableCell(withReuseIdentifier: RemoteViewItemCell.reuseIdentifier, for: indexPath)
                }
            }
        }
    }
    
    /// Creates the compositional layout used for the call video grid.
    static func createLayout(itemCount: Int, hasScreenShare: Bool = false) -> UICollectionViewCompositionalLayout {
        if hasScreenShare, itemCount > 1 {
            let cameraTileCount = itemCount - 1
            return UICollectionViewCompositionalLayout { _, environment in
                sections.screenShareDominantSection(
                    cameraTileCount: cameraTileCount,
                    containerSize: environment.container.effectiveContentSize)
            }
        }
        if itemCount > 1 {
            return UICollectionViewCompositionalLayout { _, environment in
                sections.conferenceViewSection(
                    itemCount: itemCount,
                    containerSize: environment.container.effectiveContentSize)
            }
        } else {
            return UICollectionViewCompositionalLayout(section: sections.fullScreenItem())
        }
    }

    private func updateLayoutForItemCount(_ itemCount: Int, hasScreenShare: Bool? = nil) {
        let hasScreenShare = hasScreenShare ?? hasActiveRemoteScreenShare
        hasActiveRemoteScreenShare = hasScreenShare
        let nextType: SectionType
        if hasScreenShare, itemCount > 1 {
            nextType = .conference
        } else {
            nextType = itemCount > 1 ? .conference : .fullscreen
        }
        collectionView.setCollectionViewLayout(
            Self.createLayout(itemCount: max(1, itemCount), hasScreenShare: hasScreenShare),
            animated: false)
        currentSectionType = nextType
    }

    private func setupConferencePageIndicator() {
        conferencePageIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        conferencePageIndicatorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        conferencePageIndicatorLabel.textColor = .white
        conferencePageIndicatorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        conferencePageIndicatorLabel.layer.cornerRadius = 12
        conferencePageIndicatorLabel.clipsToBounds = true
        conferencePageIndicatorLabel.textAlignment = .center
        conferencePageIndicatorLabel.isHidden = true
        controllerView.addSubview(conferencePageIndicatorLabel)
        NSLayoutConstraint.activate([
            conferencePageIndicatorLabel.topAnchor.constraint(equalTo: controllerView.safeAreaLayoutGuide.topAnchor, constant: 10),
            conferencePageIndicatorLabel.centerXAnchor.constraint(equalTo: controllerView.centerXAnchor),
            conferencePageIndicatorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])
    }

    private func updateConferencePageIndicator(totalItems: Int? = nil) {
        let itemCount = totalItems ?? dataSource?.snapshot().numberOfItems ?? 0
        let totalPages = max(1, Int(ceil(Double(itemCount) / Double(conferencePageSize))))
        guard totalPages > 1 else {
            conferencePageIndicatorLabel.isHidden = true
            lastConferencePageIndicatorSignature = ""
            return
        }
        let firstVisibleIndex = collectionView.indexPathsForVisibleItems.map(\.item).min() ?? 0
        let currentPage = min(totalPages, max(1, (firstVisibleIndex / conferencePageSize) + 1))
        let signature = "\(currentPage)/\(totalPages)"
        guard signature != lastConferencePageIndicatorSignature else { return }
        lastConferencePageIndicatorSignature = signature
        conferencePageIndicatorLabel.text = "  Page \(signature)  "
        conferencePageIndicatorLabel.isHidden = false
    }
    
    /// Adds or removes a blur overlay over the local preview view.
    func blurView(_ shouldBlur: Bool) async {
        if shouldBlur {
            controllerView.blurEffectView?.removeFromSuperview()
            controllerView.blurEffectView = UIVisualEffectView(effect: controllerView.blurEffect)
            guard let blurEffectView = controllerView.blurEffectView else { return }
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            controllerView.blurEffectView?.frame = localView.bounds
            controllerView.blurEffectView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            localView.addSubview(blurEffectView)
        } else {
            controllerView.blurEffectView?.removeFromSuperview()
        }
    }

    private static let remoteVideoStaleFrameThresholdMs: Int64 = 1200

    private func stopRemoteRendererRecovery() {
        remoteRendererRecoveryTask?.cancel()
        remoteRendererRecoveryTask = nil
        remoteRendererRecoveryConnectionId = nil
        remoteRendererRecoveryRendererId = nil
        lastRemoteRendererRecoveryUptimeNs = 0
    }

    private func participantRendererRecoveryKey(connectionId: String, participantId: String) -> String {
        "\(connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId)|\(participantId.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func stopParticipantRendererRecovery(connectionId: String, participantId: String) {
        let key = participantRendererRecoveryKey(connectionId: connectionId, participantId: participantId)
        participantRendererRecoveryTasksByKey.removeValue(forKey: key)?.cancel()
        lastParticipantRendererRecoveryUptimeNsByKey.removeValue(forKey: key)
    }

    private func stopAllParticipantRendererRecovery() {
        for task in participantRendererRecoveryTasksByKey.values {
            task.cancel()
        }
        participantRendererRecoveryTasksByKey.removeAll()
        lastParticipantRendererRecoveryUptimeNsByKey.removeAll()
    }

    private func startRemoteRendererRecoveryIfNeeded(
        renderer: SampleBufferViewRenderer,
        connectionId: String
    ) {
        let normalizedConnectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        let rendererId = ObjectIdentifier(renderer)
        if remoteRendererRecoveryTask != nil,
           remoteRendererRecoveryConnectionId == normalizedConnectionId,
           remoteRendererRecoveryRendererId == rendererId {
            return
        }
        stopRemoteRendererRecovery()
        remoteRendererRecoveryConnectionId = normalizedConnectionId
        remoteRendererRecoveryRendererId = rendererId
        remoteRendererRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard self.isRunning else { continue }
                guard self.currentCallState != .waiting else { continue }
                let callbackAgeMs = await renderer.ageMillisecondsSinceLastVideoFrameCallback()
                let expectationAgeMs = await renderer.ageMillisecondsSinceInboundVideoExpectationBegan()
                let hasAnyCallbacks = await renderer.hasReceivedAnyVideoFrameCallbacks()
                let noCallbacksYet = callbackAgeMs < 0
                    && expectationAgeMs >= 3_000
                    && !hasAnyCallbacks
                guard callbackAgeMs > 3_000 || noCallbacksYet else { continue }

                let now = DispatchTime.now().uptimeNanoseconds
                if self.lastRemoteRendererRecoveryUptimeNs > 0,
                   now >= self.lastRemoteRendererRecoveryUptimeNs,
                   now - self.lastRemoteRendererRecoveryUptimeNs < 6_000_000_000 {
                    continue
                }
                self.lastRemoteRendererRecoveryUptimeNs = now

                let inboundFlow = await self.session.evaluateInboundRemoteVideoFlow(connectionId: connectionId)
                if let flow = inboundFlow {
                    self.logger.log(
                        level: .warning,
                        message: "iOS remote renderer stall probe (callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState), inAudioPackets=\(flow.audioPacketsReceived), inVideoPackets=\(flow.packetsReceived), inFrames=\(flow.framesReceived), inDecoded=\(flow.framesDecoded), dAudioPackets=\(flow.deltaAudioPacketsReceived), dVideoPackets=\(flow.deltaPacketsReceived), dFrames=\(flow.deltaFramesReceived), dDecoded=\(flow.deltaFramesDecoded))"
                    )
                } else {
                    self.logger.log(
                        level: .warning,
                        message: "iOS remote renderer stall probe (callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs)) could not read inbound flow stats"
                    )
                }

                let shouldRecoverRenderer: Bool = {
                    guard let flow = inboundFlow else { return false }
                    switch flow.state {
                    case .advancingIngress, .decodeStalled:
                        return true
                    case .noTraffic, .stalledIngress:
                        return false
                    }
                }()
                guard shouldRecoverRenderer else {
                    self.logger.log(
                        level: .warning,
                        message: "iOS renderer recovery skipped: inbound counters not advancing enough; likelyCause=\(inboundFlow?.likelyCause ?? "unknown") connectionId=\(connectionId)"
                    )
                    continue
                }

                self.logger.log(
                    level: .warning,
                    message: "iOS remote renderer stalled with advancing inbound media; restarting stream + rebinding track for connectionId=\(connectionId)"
                )
                await renderer.startStream()
                await self.session.renderRemoteVideo(to: renderer.rtcVideoRenderWrapper, with: connectionId)
                await self.session.setVideoTrack(isEnabled: !self.isMutingVideo, connectionId: connectionId)
                await self.applyMainRemoteTileInboundExpectation(connectionId: connectionId)
            }
        }
    }

    private func startParticipantRendererRecoveryIfNeeded(
        renderer: SampleBufferViewRenderer,
        connectionId: String,
        participantId: String
    ) {
        let normalizedConnectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        let trimmedParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConnectionId.isEmpty, !trimmedParticipantId.isEmpty else { return }
        let key = participantRendererRecoveryKey(connectionId: normalizedConnectionId, participantId: trimmedParticipantId)
        if let existing = participantRendererRecoveryTasksByKey[key], !existing.isCancelled {
            return
        }

        participantRendererRecoveryTasksByKey[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard self.isRunning else { continue }
                guard self.currentCallState != .waiting else { continue }

                let callbackAgeMs = await renderer.ageMillisecondsSinceLastVideoFrameCallback()
                let expectationAgeMs = await renderer.ageMillisecondsSinceInboundVideoExpectationBegan()
                let hasAnyCallbacks = await renderer.hasReceivedAnyVideoFrameCallbacks()
                let noCallbacksYet = callbackAgeMs < 0
                    && expectationAgeMs >= 3_000
                    && !hasAnyCallbacks
                guard callbackAgeMs > 3_000 || noCallbacksYet else { continue }

                let now = DispatchTime.now().uptimeNanoseconds
                let last = self.lastParticipantRendererRecoveryUptimeNsByKey[key] ?? 0
                if last > 0, now >= last, now - last < 6_000_000_000 {
                    continue
                }
                self.lastParticipantRendererRecoveryUptimeNsByKey[key] = now

                let inboundFlow = await self.session.evaluateInboundRemoteVideoFlow(connectionId: normalizedConnectionId)
                if let flow = inboundFlow {
                    self.logger.log(
                        level: .warning,
                        message: "iOS participant camera stall probe (participant=\(trimmedParticipantId), callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState), inAudioPackets=\(flow.audioPacketsReceived), inVideoPackets=\(flow.packetsReceived), inFrames=\(flow.framesReceived), inDecoded=\(flow.framesDecoded), dAudioPackets=\(flow.deltaAudioPacketsReceived), dVideoPackets=\(flow.deltaPacketsReceived), dFrames=\(flow.deltaFramesReceived), dDecoded=\(flow.deltaFramesDecoded))"
                    )
                } else {
                    self.logger.log(
                        level: .warning,
                        message: "iOS participant camera stall probe (participant=\(trimmedParticipantId), callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs)) could not read inbound flow stats"
                    )
                }

                let shouldRecoverRenderer: Bool = {
                    guard let flow = inboundFlow else { return false }
                    switch flow.state {
                    case .advancingIngress, .decodeStalled:
                        return true
                    case .noTraffic, .stalledIngress:
                        return false
                    }
                }()
                guard shouldRecoverRenderer else {
                    self.logger.log(
                        level: .warning,
                        message: "iOS participant camera recovery skipped: inbound counters not advancing enough; participant=\(trimmedParticipantId) likelyCause=\(inboundFlow?.likelyCause ?? "unknown") connectionId=\(normalizedConnectionId)"
                    )
                    continue
                }

                self.logger.log(
                    level: .warning,
                    message: "iOS participant camera renderer stalled with advancing inbound media; restarting stream + rebinding participant track participant=\(trimmedParticipantId) connectionId=\(normalizedConnectionId)"
                )
                await renderer.startStream()
                let didAttach = await self.session.renderRemoteVideoForParticipant(
                    to: renderer.rtcVideoRenderWrapper,
                    connectionId: normalizedConnectionId,
                    participantId: trimmedParticipantId
                )
                if didAttach {
                    await renderer.setRemoteVideoInboundExpected(true)
                }
            }
        }
    }

    /// Combines inbound `isEnabled` (local receive toggle) with “no new frames for a while” so peer camera-off / frozen-last-frame resolve.
    private func remotePartyVideoAppearsActive(connectionId: String) async -> Bool {
        let trackSaysLive = await session.inboundRemoteVideoTrackAppearsEnabled(connectionId: connectionId)
        guard trackSaysLive else { return false }
        guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView,
              let renderer = remoteView.renderer as? SampleBufferViewRenderer else {
            return true
        }
        let ageMs = await renderer.ageMillisecondsSinceLastVideoFrameCallback()
        if ageMs < 0 { return true }
        return ageMs < Self.remoteVideoStaleFrameThresholdMs
    }

    private func applyMainRemoteTileInboundExpectation(connectionId: String) async {
        let expect = await session.shouldExpectRemoteVideoCallbacksFromOtherParticipants(connectionId: connectionId)
        guard let remoteRenderer = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView.renderer as? SampleBufferViewRenderer else { return }
        await remoteRenderer.setRemoteVideoInboundExpected(expect)
    }

    private func startRemoteVideoTrackPolling() {
        stopRemoteVideoTrackPolling()
        guard let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        let connectionId = raw
        remoteVideoTrackPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var last: Bool?
            var lastInboundExpect: Bool?
            while !Task.isCancelled {
                guard self.isRunning else { break }
                let appearsActive = await self.remotePartyVideoAppearsActive(connectionId: connectionId)
                if last != appearsActive {
                    last = appearsActive
                    self.updateRemoteCameraOffChrome(isRemoteVideoActive: appearsActive)
                }
                let expectInbound = await self.session.shouldExpectRemoteVideoCallbacksFromOtherParticipants(connectionId: connectionId)
                if lastInboundExpect != expectInbound {
                    lastInboundExpect = expectInbound
                    await self.applyMainRemoteTileInboundExpectation(connectionId: connectionId)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopRemoteVideoTrackPolling() {
        remoteVideoTrackPollTask?.cancel()
        remoteVideoTrackPollTask = nil
        stopRemoteRendererRecovery()
        remoteCameraOffChrome?.removeFromSuperview()
        remoteCameraOffChrome = nil
    }

    /// Covers the main remote surface when the sender disables video so the last frame is not mistaken for a live picture.
    private func updateRemoteCameraOffChrome(isRemoteVideoActive: Bool) {
        guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        if isRemoteVideoActive {
            remoteCameraOffChrome?.removeFromSuperview()
            remoteCameraOffChrome = nil
            return
        }
        if remoteCameraOffChrome != nil { return }

        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.88)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        container.addSubview(blur)

        let icon = UIImageView(image: UIImage(systemName: "video.slash.fill"))
        icon.tintColor = UIColor.white.withAlphaComponent(0.92)
        icon.contentMode = .scaleAspectFit
        container.addSubview(icon)

        remoteView.addSubview(container)
        container.anchors(
            top: remoteView.topAnchor,
            leading: remoteView.leadingAnchor,
            bottom: remoteView.bottomAnchor,
            trailing: remoteView.trailingAnchor
        )
        blur.anchors(
            top: container.topAnchor,
            leading: container.leadingAnchor,
            bottom: container.bottomAnchor,
            trailing: container.trailingAnchor
        )
        icon.anchors(
            centerY: container.centerYAnchor,
            centerX: container.centerXAnchor,
            width: 56,
            height: 56
        )
        remoteCameraOffChrome = container
        remoteView.bringSubviewToFront(container)
    }
    
    /// Draggable preview support (local view overlay).
    @objc func dragPreviewView(_ sender: UIPanGestureRecognizer) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            controllerView.bringSubviewToFront(localView)
            let translation = sender.translation(in: self.view)
            // Keep the preview within safe bounds (feels “tight” and prevents losing the preview off-screen).
            let proposed = CGPoint(x: localView.center.x + translation.x, y: localView.center.y + translation.y)
            let safe = controllerView.safeAreaLayoutGuide.layoutFrame
            let halfW = localView.bounds.width / 2
            let halfH = localView.bounds.height / 2
            let minX = safe.minX + halfW
            let maxX = safe.maxX - halfW
            let minY = safe.minY + halfH
            let maxY = safe.maxY - halfH
            localView.center = CGPoint(
                x: min(max(proposed.x, minX), maxX),
                y: min(max(proposed.y, minY), maxY)
            )
            sender.setTranslation(CGPoint.zero, in: self.view)
            
            // Snap-to-corner on end feels premium and prevents awkward mid-screen placement.
            if sender.state == .ended || sender.state == .cancelled || sender.state == .failed {
                let candidates = [
                    CGPoint(x: minX, y: minY),
                    CGPoint(x: maxX, y: minY),
                    CGPoint(x: minX, y: maxY),
                    CGPoint(x: maxX, y: maxY)
                ]
                let current = localView.center
                let target = candidates.min(by: { a, b in
                    hypot(a.x - current.x, a.y - current.y) < hypot(b.x - current.x, b.y - current.y)
                }) ?? current
                
                if #available(iOS 10.0, *) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    localView.center = target
                }
            }
        }
    }
    
    /// Toggles between minimized and normal preview sizing.
    @objc func tapPreviewView() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isMinimized.toggle()
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            controllerView.updateLocalVideoSize(with: UIDevice.current.orientation, should: isMinimized, isConnected: isConnected() ? true : false, view: localView, animated: true)
        }
    }
    
    /// Enables/disables Metal rendering for the local preview view.
    private func setRenderOnMetal(_ shouldRender: Bool) async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        if let renderer = localView.renderer as? PreviewViewRender {
            await renderer.setShouldRender(shouldRender)
        }
    }
    
    /// Enables/disables feeding frames from the local camera preview into the capture wrapper.
    ///
    /// This is used to make "mute video" feel instant: the user expects the camera to stop
    /// immediately (not a delayed disable after negotiation).
    private func setLocalPreviewCapturing(isEnabled: Bool) async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        guard let renderer = localView.renderer as? PreviewViewRender else { return }
        await renderer.setShouldRender(isEnabled)
    }

    private func applyCurrentLocalVideoMuteState(connectionId: String) async {
        let videoEnabled = !isMutingVideo
        await setLocalPreviewCapturing(isEnabled: videoEnabled)
        await session.setVideoTrack(isEnabled: videoEnabled, connectionId: connectionId)
        await blurView(isMutingVideo)
        await videoCallDelegate?.localMuteDisplayDidChange(videoMuted: isMutingVideo, audioMuted: isMutingAudio)
    }

    private func resolvedMuteConnectionId() async -> String? {
        if let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw.normalizedConnectionId
        }
        // UIKit controller can lag the actor-isolated state machine (e.g. CallKit / late stream attach).
        if let raw = await session.callState.currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw.normalizedConnectionId
        }
        return await session.fallbackConnectionIdForMuteControls()
    }

    private func activeCallAppearsToBeVideo() async -> Bool {
        if await session.callState._callType == .video { return true }
        guard let state = await session.callState.currentState else { return false }
        switch state {
        case .connecting(let direction, _), .connected(let direction, _):
            switch direction {
            case .inbound(let type), .outbound(let type):
                return type == .video
            }
        case .held(let direction, _):
            guard let direction else { return false }
            switch direction {
            case .inbound(let type), .outbound(let type):
                return type == .video
            }
        default:
            return false
        }
    }

    /// Starts video-call PiP when the user leaves the app so the remote feed can continue in the system PiP window.
    private func startPictureInPictureIfEligibleAfterBackgrounding() async {
        guard isRunning else { return }
        guard isConnected() else { return }
        guard await activeCallAppearsToBeVideo() else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard !pipStartInFlight, !pipStopInFlight else { return }
        if let existing = pipController, existing.isPictureInPictureActive { return }
        guard let pipController = await preparePictureInPictureIfNeeded() else {
            logger.log(level: .warning, message: "Auto PiP: controller was not ready before backgrounding")
            return
        }
        logger.log(
            level: .info,
            message: "Auto PiP background transition observed; prepared controller possible=\(pipController.isPictureInPicturePossible) active=\(pipController.isPictureInPictureActive)"
        )
    }

    private func pictureInPictureLayoutSize() -> CGSize {
        switch UIDevice.current.orientation {
        case .unknown, .faceUp, .faceDown:
            if UIScreen.main.bounds.width < UIScreen.main.bounds.height {
                return controllerView.setSize(isLandscape: false, minimize: false)
            }
            return controllerView.setSize(isLandscape: true, minimize: false)
        case .portrait, .portraitUpsideDown:
            return controllerView.setSize(isLandscape: false, minimize: false)
        case .landscapeRight, .landscapeLeft:
            return controllerView.setSize(isLandscape: true, minimize: false)
        default:
            return controllerView.setSize(isLandscape: true, minimize: false)
        }
    }

    /// Prepares a reusable PiP controller while the call is still foregrounded.
    ///
    /// Automatic PiP when backgrounding is driven by `canStartPictureInPictureAutomaticallyFromInline`;
    /// creating the controller only after the app resigns active is too late.
    private func preparePictureInPictureIfNeeded() async -> AVPictureInPictureController? {
        guard let rawConnection = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !rawConnection.isEmpty else {
            logger.log(level: .warning, message: "preparePiP: missing connection id")
            return nil
        }
        guard videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) else {
            logger.log(level: .debug, message: "preparePiP: preview not ready yet")
            return nil
        }
        guard videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) else {
            logger.log(level: .debug, message: "preparePiP: remote video view not ready yet")
            return nil
        }

        let layoutSize = pictureInPictureLayoutSize()
        if let existing = pipController,
           let pipRenderer = pipSampleRenderer,
           pipSampleView != nil,
           pipVideoCallViewController != nil {
            pipVideoCallViewController?.preferredContentSize = layoutSize
            await pipRenderer.applyHostViewBounds(CGRect(origin: .zero, size: layoutSize))
            return existing
        }

        await dismantlePiPRenderingAndAuxiliaryTrack()
        pipController = nil
        pipVideoCallViewController = nil

        let pipVideoCallViewController = AVPictureInPictureVideoCallViewController()
        let remotePipView = SampleCaptureView()
        remotePipView.translatesAutoresizingMaskIntoConstraints = false
        self.pipSampleView = remotePipView

        pipVideoCallViewController.preferredContentSize = layoutSize
        pipVideoCallViewController.view.addSubview(remotePipView)
        remotePipView.anchors(
            top: pipVideoCallViewController.view.topAnchor,
            leading: pipVideoCallViewController.view.leadingAnchor,
            bottom: pipVideoCallViewController.view.bottomAnchor,
            trailing: pipVideoCallViewController.view.trailingAnchor
        )
        pipVideoCallViewController.view.layoutIfNeeded()

        let pipCIContext = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView.ciContext
            ?? CIContext(options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false,
                .name: "pip"
            ])
        let pipLayerBox = SampleBufferDisplayLayerBox(layer: remotePipView.sampleBufferLayer)
        let pipRenderer = SampleBufferViewRenderer(
            layerBox: pipLayerBox,
            ciContext: pipCIContext,
            bounds: CGRect(origin: .zero, size: layoutSize)
        )
        pipRenderer.passPause(true)
        await pipRenderer.startStream()
        self.pipSampleRenderer = pipRenderer

        let pipWrapper = await pipRenderer.rtcVideoRenderWrapper
        await session.addAuxiliaryRemoteVideoRenderer(pipWrapper, connectionId: rawConnection)
        pipAuxiliaryRenderWrapper = pipWrapper
        let pipExpect = await session.shouldExpectRemoteVideoCallbacksFromOtherParticipants(connectionId: rawConnection)
        await pipRenderer.setRemoteVideoInboundExpected(pipExpect)

        let sourceView = activeVideoCallSourceViewForPiP()
        let pipContentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: pipVideoCallViewController
        )

        let newPipController = AVPictureInPictureController(contentSource: pipContentSource)
        newPipController.canStartPictureInPictureAutomaticallyFromInline = true
        newPipController.delegate = self
        self.pipVideoCallViewController = pipVideoCallViewController
        self.pipController = newPipController
        logger.log(
            level: .info,
            message: "Prepared PiP controller while foregrounded (possible=\(newPipController.isPictureInPicturePossible), automatic=\(newPipController.canStartPictureInPictureAutomaticallyFromInline))"
        )
        return newPipController
    }

    /// Per Apple’s video-call PiP guide, `activeVideoCallSourceView` should be a view that actually carries call video (animation + restore target).
    private func activeVideoCallSourceViewForPiP() -> UIView {
        guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else {
            return view
        }
        // Avoid handing AVKit the actor-isolated `NTMTKView` directly; the host container is a safer
        // source view for visibility checks and PiP restore animations.
        return remoteView.superview ?? remoteView
    }

    /// After PiP, align the main remote renderer with `NTMTKView.shouldRenderOnMetal` (iOS defaults to sample buffers; `passPause(false)` alone breaks that).
    private func restoreMainRemoteRendererOutputModeAfterPiP() {
        guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView as? NTMTKView else {
            pipDelegate?.passPause(true)
            return
        }
        pipDelegate?.passPause(!remoteView.shouldRenderOnMetal)
    }

    /// Removes the PiP-only WebRTC sink and shuts down the PiP `NTMTKView` (safe to call more than once).
    private func dismantlePiPRenderingAndAuxiliaryTrack() async {
        let pipRenderer = pipSampleRenderer
        let pipSampleView = pipSampleView
        let pipMetalView = pipVideoView
        let hadPipSurface = pipSampleView != nil || pipRenderer != nil || pipMetalView != nil || pipAuxiliaryRenderWrapper != nil
        if let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let w = pipAuxiliaryRenderWrapper {
                await session.removeAuxiliaryRemoteVideoRenderer(w, connectionId: raw)
            } else if let pipView = pipMetalView,
                      let pipRenderer = pipView.renderer as? SampleBufferViewRenderer {
                let wrapper = await pipRenderer.rtcVideoRenderWrapper
                await session.removeAuxiliaryRemoteVideoRenderer(wrapper, connectionId: raw)
            } else if let pipRenderer {
                let wrapper = await pipRenderer.rtcVideoRenderWrapper
                await session.removeAuxiliaryRemoteVideoRenderer(wrapper, connectionId: raw)
            }
        }
        pipSampleRenderer = nil
        await pipRenderer?.setRemoteVideoInboundExpected(false)
        await pipRenderer?.shutdown()
        pipAuxiliaryRenderWrapper = nil
        pipSampleView?.removeFromSuperview()
        pipSampleView?.shutdown()
        self.pipSampleView = nil
        pipVideoCallViewController = nil
        pipMetalView?.shutdownMetalStream()
        pipVideoView = nil
        if hadPipSurface {
            restoreMainRemoteRendererOutputModeAfterPiP()
        }
    }
}

extension VideoCallViewController: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
    nonisolated public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
    
    /// Starts or stops Picture in Picture for the current video call.
    ///
    /// This uses `AVPictureInPictureVideoCallViewController` plus a sample-buffer host view so
    /// AVKit does not traverse an actor-isolated `NTMTKView` subtree during PiP visibility checks.
    func showPip(show: Bool) async {
        do {
            if show {
                if let existing = pipController, existing.isPictureInPictureActive { return }
                guard !pipStopInFlight else {
                    logger.log(level: .debug, message: "showPip: stop already in progress, ignoring start request")
                    return
                }
                guard let rawConnection = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !rawConnection.isEmpty else {
                    logger.log(level: .warning, message: "showPip: missing connection id")
                    return
                }
                guard videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) else {
                    logger.log(level: .warning, message: "showPip: local preview not ready (video UI not fully up)")
                    return
                }
                guard AVPictureInPictureController.isPictureInPictureSupported() else {
                    logger.log(level: .notice, message: "PiP not supported on this device")
                    return
                }
                guard !pipStartInFlight else {
                    logger.log(level: .debug, message: "showPip: start already in progress, ignoring duplicate request")
                    return
                }
                pipStartInFlight = true
                defer { pipStartInFlight = false }
                guard let pipController = await preparePictureInPictureIfNeeded() else {
                    logger.log(level: .error, message: "showPip: PiP controller could not be prepared")
                    return
                }
                guard pipController.isPictureInPicturePossible else {
                    logger.log(
                        level: .error,
                        message: "showPip: isPictureInPicturePossible is false — the controller must already be inline/ready before start; ensure the call is visibly active on a physical device with an active VoIP audio session."
                    )
                    return
                }
                // Defer one run-loop turn so AVKit/Pegasus XPC is not started synchronously from SwiftUI `body` / gesture updates.
                await Task.yield()
                pipController.startPictureInPicture()
            } else {
                guard !pipStopInFlight else { return }
                if let pipController, pipController.isPictureInPictureActive {
                    pipStopInFlight = true
                    pipController.stopPictureInPicture()
                } else {
                    await dismantlePiPRenderingAndAuxiliaryTrack()
                    self.pipController = nil
                }
            }
        } catch {
            self.logger.log(level: .error, message: "Error showing PIP: \(error.localizedDescription)")
            pipStopInFlight = false
            await dismantlePiPRenderingAndAuxiliaryTrack()
            pipController = nil
        }
    }
    
    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.pipStopInFlight = false
            self?.logger.log(level: .info, message: "PiP did start")
        }
    }
    nonisolated public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pipStopInFlight = true
            logger.log(level: .debug, message: "PiP will stop")
        }
    }
    
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            logger.log(level: .error, message: "PiP failed to start: \(error.localizedDescription)")
            pipStopInFlight = false
        }
    }
    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pipStopInFlight = false
            restoreMainRemoteRendererOutputModeAfterPiP()
            logger.log(level: .info, message: "PiP did stop")
        }
    }
    
    @objc(pictureInPictureController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:)
    nonisolated public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            completionHandler(true)
        }
    }
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pipDelegate?.passPause(true)
        }
    }
}

extension VideoCallViewController: CallActionDelegate {
    /// Ends the current call, notifies transport, shuts down the session, then dismisses the UI.
    public func endCall() async {
        // If we don't have an active call, just clean up the UI
        guard let currentCall else {
            await tearDownCall()
            dismiss(animated: true)
            return
        }
        
        // Notify transport that the user ended the call
        do {
            let transport = try await session.requireTransport()
            try await transport.didEnd(
                call: currentCall,
                endState: CallStateMachine.EndState.userInitiated)
        } catch {
            logger.log(level: .error, message: "Error invoking didEnd on transport delegate: \(error)")
        }
        
        await tearDownCall()
        dismiss(animated: true)
    }
    
    /// Toggles the local audio track and updates the session.
    public func muteAudio() async {
        await setAudioMuted(!isMutingAudio)
    }

    /// Sets the local audio track to a specific muted/unmuted state.
    public func setAudioMuted(_ muted: Bool) async {
        guard let callId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "muteAudio: missing connection id")
            return
        }
        guard isMutingAudio != muted else {
            await videoCallDelegate?.localMuteDisplayDidChange(videoMuted: isMutingVideo, audioMuted: isMutingAudio)
            return
        }
        do {
            // When muted, disable the local microphone track.
            try await session.setAudioTrack(isEnabled: !muted, connectionId: callId)
            isMutingAudio = muted
            await videoCallDelegate?.localMuteDisplayDidChange(videoMuted: isMutingVideo, audioMuted: isMutingAudio)
        } catch {
            logger.log(level: .error, message: "Failed to set audio track: \(error)")
        }
    }
    
    /// Toggles the local video track and applies a blur overlay when video is muted.
    public func muteVideo() async {
        await setVideoMuted(!isMutingVideo)
    }

    /// Sets the local video track to a specific muted/unmuted state.
    public func setVideoMuted(_ muted: Bool) async {
        guard let callId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "muteVideo: missing connection id")
            return
        }
        guard await activeCallAppearsToBeVideo() else { return }

        guard isMutingVideo != muted else {
            await applyCurrentLocalVideoMuteState(connectionId: callId)
            return
        }

        isMutingVideo = muted
        await applyCurrentLocalVideoMuteState(connectionId: callId)
    }
    
    /// Routes call audio to the built-in speaker or back to the default receiver/route.
    public func setSpeakerOutputEnabled(_ enabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            if enabled {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
            speakerPhoneEnabled = enabled
        } catch {
            logger.log(level: .error, message: "setSpeakerOutputEnabled(\(enabled)): \(error)")
        }
    }

    public func toggleSpeakerPhone() {
        setSpeakerOutputEnabled(!speakerPhoneEnabled)
    }
    
    /// Starts/stops Picture in Picture.
    public func showPictureInPicture(_ show: Bool) async {
        await showPip(show: show)
    }

    /// Starts screen sharing with the given target.
    public func startScreenShare(target: ScreenShareTarget) async {
        await startScreenShare(target: target, options: ScreenShareOptions())
    }

    /// Starts screen sharing with the given target and capture preferences.
    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        guard let connectionId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "startScreenShare: no active connection")
            return
        }
        do {
            try await session.addScreenTrackToStream(target: target, options: options, connectionId: connectionId)
            await videoCallDelegate?.screenShareDidChange(isSharing: true)
        } catch {
            logger.log(level: .error, message: "startScreenShare failed: \(error)")
        }
    }

    /// Stops the active screen share.
    public func stopScreenShare() async {
        guard let connectionId = await resolvedMuteConnectionId() else { return }
        await session.removeScreenTrackFromStream(connectionId: connectionId)
        await videoCallDelegate?.screenShareDidChange(isSharing: false)
    }
}
extension AVCaptureVideoPreviewLayer: @retroactive @unchecked Sendable {}
#endif
