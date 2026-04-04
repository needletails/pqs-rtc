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
    private var isMinimized = false
    private static let sections = CollectionViewSections()
    private var loadedPreviewItem = false
    private var speakerPhoneEnabled = false
    /// `NSObjectProtocol` is not `Sendable`; token is only used from main; `deinit` must remove it without isolation.
    nonisolated(unsafe) private var localVideoMirrorObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didEnterBackgroundPiPObserver: NSObjectProtocol?

    private var remoteVideoTrackPollTask: Task<Void, Never>?
    private weak var remoteCameraOffChrome: UIView?
    
    /// Creates an iOS call UI controller bound to a specific ``RTCSession``.
    public init(session: RTCSession) {
        self.session = session
        let layout = VideoCallViewController.createLayout(sectionType: .fullscreen)
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

        localVideoMirrorObserver = NotificationCenter.default.addObserver(
            forName: PQSRTCCallUIPreferences.localVideoMirrorPreferenceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.applyLocalVideoMirroringFromUserDefaults() }
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

        // Guarantee the underlying RTCSession is returned to a pre-call baseline
        // even when teardown is triggered by remote end/failure (not user-initiated endCall()).
        if let call = self.currentCall {
            await session.shutdown(with: call)
        }

        await tearDownPreviewView()
        await tearDownSampleView()
        
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
        
        // Bind capture injection into WebRTC as soon as the wrapper exists.
        // This is event-driven (no retry loop): if the wrapper isn't ready yet, we await it.
        if let wrapper = (await session.connectionManager.findConnection(with: connectionId))?.rtcVideoCaptureWrapper {
            await previewRenderer.setCapture(wrapper)
        } else if let wrapper = await session.waitForVideoCaptureWrapper(connectionId: connectionId) {
            await previewRenderer.setCapture(wrapper)
        }
        
        await self.session.renderLocalVideo(to: previewRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        await self.session.setVideoTrack(isEnabled: true, connectionId: connectionId)
        await applyLocalVideoMirroringFromUserDefaults()
    }

    private func applyLocalVideoMirroringFromUserDefaults() async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView,
              let renderer = localView.renderer as? PreviewViewRender else { return }
        await renderer.applyLocalVideoMirroringFromUserDefaults()
    }
    
    /// Creates and starts the remote sample (receive) Metal view.
    ///
    /// - Parameter removePreview: If `true`, removes the preview from the collection snapshot
    ///   so the remote video takes the full screen; the preview is instead overlaid on top.
    func createSampleView(removePreview: Bool = true) async {
        // Idempotency: avoid creating duplicate remote renderers if call-state re-emits `.connected`.
        if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) {
            configureLocalPreviewIfNeeded()
            if let remoteRenderer = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView.renderer as? SampleBufferViewRenderer {
                await remoteRenderer.setRemoteVideoInboundExpected(true)
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
        
        await remoteVideoView.startRendering()
        guard let remoteRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        pipDelegate = remoteRenderer
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.renderRemoteVideo(
            to: remoteRenderer.rtcVideoRenderWrapper,
            with: connectionId)
        await self.session.setVideoTrack(isEnabled: true, connectionId: connectionId)
        await remoteRenderer.setRemoteVideoInboundExpected(true)
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
        stopRemoteVideoTrackPolling()
        guard let remoteVideoView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        guard let remoteVideoRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        await remoteVideoRenderer.setRemoteVideoInboundExpected(false)
        await remoteVideoRenderer.shutdown()
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.setVideoTrack(isEnabled: false, connectionId: connectionId)
        await session.removeRemote(renderer: remoteVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        remoteVideoView.shutdownMetalStream()
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
        await dataSource?.apply(snapshot)
        
        var data = await videoViews.getViews()
        if removePreview {
            data.removeAll(where: { $0.videoView.contextName == "preview" })
        }
        if data.isEmpty {
            snapshot.deleteSections([.initial])
            snapshot.deleteItems(data)
            await dataSource?.apply(snapshot, animatingDifferences: false)
        } else {
            snapshot.appendSections([.initial])
            snapshot.appendItems(data, toSection: .initial)
            await dataSource?.apply(snapshot)
        }
    }
    
    /// Ensures the local preview view is attached, gesture-enabled, and sized.
    private func configureLocalPreviewIfNeeded() {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        
        if localView.superview !== controllerView {
            controllerView.addSubview(localView)
        }
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
        bringControlsToFront()
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
                    return item
                } else {
                    assertionFailure("Could not dequeue RemoteViewItemCell")
                    return collectionView.dequeueReusableCell(withReuseIdentifier: RemoteViewItemCell.reuseIdentifier, for: indexPath)
                }
            }
        }
    }
    
    /// Creates the compositional layout used for the call video grid.
    static func createLayout(sectionType: SectionType) -> UICollectionViewCompositionalLayout {
        switch sectionType {
        case .fullscreen:
            return UICollectionViewCompositionalLayout(section: sections.fullScreenItem())
        case .conference:
            return UICollectionViewCompositionalLayout(section: sections.conferenceViewSection(itemCount: 2))
        }
    }
    
    /// Adds or removes a blur overlay over the local preview view.
    func blurView(_ shouldBlur: Bool) async {
        if shouldBlur {
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

    private func startRemoteVideoTrackPolling() {
        stopRemoteVideoTrackPolling()
        guard let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        let connectionId = raw
        remoteVideoTrackPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var last: Bool?
            while !Task.isCancelled {
                guard self.isRunning else { break }
                let appearsActive = await self.remotePartyVideoAppearsActive(connectionId: connectionId)
                if last != appearsActive {
                    last = appearsActive
                    self.updateRemoteCameraOffChrome(isRemoteVideoActive: appearsActive)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopRemoteVideoTrackPolling() {
        remoteVideoTrackPollTask?.cancel()
        remoteVideoTrackPollTask = nil
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
        await pipRenderer.setRemoteVideoInboundExpected(true)

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
        
        // Fully tear down the RTC session (peer connections, cryptors, etc.)
        await session.shutdown(with: currentCall)
        
        // Finally clean up local UI resources
        await tearDownCall()
        dismiss(animated: true)
    }
    
    /// Toggles the local audio track and updates the session.
    public func muteAudio() async {
        guard let callId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "muteAudio: missing connection id")
            return
        }
        let shouldMute = !isMutingAudio
        do {
            // When muted, disable the local microphone track.
            try await session.setAudioTrack(isEnabled: !shouldMute, connectionId: callId)
            isMutingAudio = shouldMute
            await videoCallDelegate?.localMuteDisplayDidChange(videoMuted: isMutingVideo, audioMuted: isMutingAudio)
        } catch {
            logger.log(level: .error, message: "Failed to set audio track: \(error)")
        }
    }
    
    /// Toggles the local video track and applies a blur overlay when video is muted.
    public func muteVideo() async {
        guard let callId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "muteVideo: missing connection id")
            return
        }
        guard await activeCallAppearsToBeVideo() else { return }
        
        let shouldMute = !isMutingVideo
        
        // Best-effort: immediately stop feeding frames into the local capture wrapper so the user
        // experiences "camera off" instantly (privacy). This is separate from disabling the WebRTC track.
        await setLocalPreviewCapturing(isEnabled: !shouldMute)
        
        await session.setVideoTrack(isEnabled: !shouldMute, connectionId: callId)
        isMutingVideo = shouldMute
        await blurView(shouldMute)
        await videoCallDelegate?.localMuteDisplayDidChange(videoMuted: isMutingVideo, audioMuted: isMutingAudio)
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
}
extension AVCaptureVideoPreviewLayer: @retroactive @unchecked Sendable {}
#endif
