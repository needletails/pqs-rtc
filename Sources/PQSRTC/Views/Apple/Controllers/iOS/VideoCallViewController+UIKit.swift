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
import NeedleTailMediaKit
import NTKLoop
import UIKit
import NeedleTailLogger
@preconcurrency import AVKit

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
    public weak var videoCallDelegate: VideoCallDelegate?
    private let logger = NeedleTailLogger("[VideoCallViewController]")
    private let controllerView = ControllerView()
    private let videoViews = VideoViews()
    private unowned let session: RTCSession
    /// If `true`, the host app provides its own controls overlay via ``setControlsView(_:)``.
    public var usesEmbeddedControls = false
    private weak var controlsView: UIView?
    private var duration: TimeInterval = 0
    private var isRunning = true
    private var showPip = false
    private var isMutingAudio = false
    private var isMutingVideo = false
    private var pipController: AVPictureInPictureController?
    private var pipVideoView: NTMTKView?
    private weak var pipDelegate: PiPEventReceiverDelegate?
    private var currentCall: Call?
    private var currentCallState: CallStateMachine.State = .waiting
    private var dataSource: UICollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>?
    private var isMinimized = false
    private static let sections = CollectionViewSections()
    private var loadedPreviewItem = false
    private var speakerPhoneEnabled = false
    
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
        
        self.configureCollectionView()
        self.configureDataSource()
        
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
                        if callType == .video,
                           videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                            await self.createPreviewView()
                            self.bringControlsToFront()
                        }
                    }
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        if callType == .video {
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await self.createPreviewView(shouldQuery: true)
                            }
                            if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) == false {
                                await self.createSampleView()
                            }
                        }
                    }
                case .held(_, _):
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
                case .held(_, _):
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
            }
        }
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
    }
    
    /// Ensures UI resources are released if the controller is dismissed.
    public override func viewWillDisappear(_ animated: Bool) {
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
    }
    
    /// Creates and starts the remote sample (receive) Metal view.
    ///
    /// - Parameter removePreview: If `true`, removes the preview from the collection snapshot
    ///   so the remote video takes the full screen; the preview is instead overlaid on top.
    func createSampleView(removePreview: Bool = true) async {
        // Idempotency: avoid creating duplicate remote renderers if call-state re-emits `.connected`.
        if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) {
            configureLocalPreviewIfNeeded()
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
        guard let remoteVideoView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        guard let remoteVideoRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
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
        
        // Enable dragging and tap-to-minimize on the local preview view (idempotent).
        if !(localView.gestureRecognizers ?? []).contains(where: { $0 is UIPanGestureRecognizer && $0.view === localView }) {
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(dragPreviewView(_:)))
            localView.addGestureRecognizer(panGesture)
        }
        if !(localView.gestureRecognizers ?? []).contains(where: { $0 is UITapGestureRecognizer && $0.view === localView }) {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tapPreviewView))
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
    /// This uses `AVPictureInPictureVideoCallViewController` plus an off-screen `NTMTKView`
    /// configured with a dedicated `contextName` to render remote video while PiP is active.
    func showPip(show: Bool) async {
        do {
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            if show {
                if AVPictureInPictureController.isPictureInPictureSupported() {
                    let pipVideoCallViewController = AVPictureInPictureVideoCallViewController()
                    let remotePipView = try NTMTKView(type: .sample, contextName: "pip")
                    self.pipVideoView = remotePipView
                    var size: CGSize?
                    switch UIDevice.current.orientation {
                    case .unknown, .faceUp, .faceDown:
                        if UIScreen.main.bounds.width < UIScreen.main.bounds.height {
                            size = controllerView.setSize(isLandscape: false, minimize: false)
                        } else {
                            size = controllerView.setSize(isLandscape: true, minimize: false)
                        }
                    case .portrait, .portraitUpsideDown:
                        size = controllerView.setSize(isLandscape: false, minimize: false)
                    case .landscapeRight, .landscapeLeft:
                        size = controllerView.setSize(isLandscape: true, minimize: false)
                    default:
                        size = controllerView.setSize(isLandscape: true, minimize: false)
                    }
                    
                    pipVideoCallViewController.preferredContentSize = size!
                    pipVideoCallViewController.view.addSubview(remotePipView)
                    
                    remotePipView.anchors(
                        top: pipVideoCallViewController.view.topAnchor,
                        leading: pipVideoCallViewController.view.leadingAnchor,
                        bottom: pipVideoCallViewController.view.bottomAnchor,
                        trailing: pipVideoCallViewController.view.trailingAnchor
                        
                    )
                    
                    let pipContentSource = AVPictureInPictureController.ContentSource(
                        activeVideoCallSourceView: view,
                        contentViewController: pipVideoCallViewController
                    )
                    
                    let pipController = AVPictureInPictureController(contentSource: pipContentSource)
                    pipController.canStartPictureInPictureAutomaticallyFromInline = true
                    pipController.delegate = self
                    pipController.startPictureInPicture()
                    self.pipController = pipController
                } else {
                    self.logger.log(level: .notice, message: "PIP not Supported")
                }
            } else {
                guard let previewRenderer = localView.renderer as? PreviewViewRender else { return }
                guard let captureSession = await previewRenderer.layer.session else { return }
                if captureSession.isMultitaskingCameraAccessSupported {
                    pipController?.stopPictureInPicture()
                    self.pipController = nil
                } else {
                    pipController?.stopPictureInPicture()
                }

                pipVideoView?.shutdownMetalStream()
                pipVideoView = nil
            }
        } catch {
            self.logger.log(level: .error, message: "Error showing PIP: \(error.localizedDescription)")
        }
    }
    
    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        
    }
    nonisolated public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pipVideoView?.shutdownMetalStream()
            pipVideoView = nil
            pictureInPictureController.contentSource?.activeVideoCallContentViewController.removeFromParent()
            pictureInPictureController.contentSource?.activeVideoCallSourceView?.removeFromSuperview()
            pictureInPictureController.contentSource?.sampleBufferDisplayLayer?.removeFromSuperlayer()
            pipDelegate?.passPause(false)
        }
    }
    
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        
    }
    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    }
    
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController) async -> Bool {
        return true
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
        guard let callId = currentCall?.sharedCommunicationId else { return }
        let shouldMute = !isMutingAudio
        do {
            // When muted, disable the local microphone track.
            try await session.setAudioTrack(isEnabled: !shouldMute, connectionId: callId)
            isMutingAudio = shouldMute
        } catch {
            logger.log(level: .error, message: "Failed to set audio track: \(error)")
        }
    }
    
    /// Toggles the local video track and applies a blur overlay when video is muted.
    public func muteVideo() async {
        guard let callId = currentCall?.sharedCommunicationId else { return }
        // Only meaningful for video calls.
        guard await session.callState._callType == .video else { return }
        
        let shouldMute = !isMutingVideo
        
        // Best-effort: immediately stop feeding frames into the local capture wrapper so the user
        // experiences "camera off" instantly (privacy). This is separate from disabling the WebRTC track.
        await setLocalPreviewCapturing(isEnabled: !shouldMute)
        
        await session.setVideoTrack(isEnabled: !shouldMute, connectionId: callId)
        isMutingVideo = shouldMute
        await blurView(shouldMute)
    }
    
    public func toggleSpeakerPhone() {
        // No-op on iOS for now; not implemented
    }
    
    /// Starts/stops Picture in Picture.
    public func showPictureInPicture(_ show: Bool) async {
        await showPip(show: show)
    }
}
extension AVCaptureVideoPreviewLayer: @retroactive @unchecked Sendable {}
#endif
