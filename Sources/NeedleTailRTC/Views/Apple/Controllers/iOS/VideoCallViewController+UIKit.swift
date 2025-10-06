//
//  VideoCallViewController+UIKit.swift
//  needle-tail-rtc
//
//  Created by Cole M on 1/11/25.
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
#if os(iOS)
@preconcurrency import WebRTC
import NeedleTailMediaKit
import NTKLoop
import UIKit
import NeedleTailLogger
@preconcurrency import AVKit

@MainActor
public final class VideoCallViewController: UICollectionViewController {
    
    enum SectionType: Sendable {
        case fullscreen, conference
    }
    
    public weak var videoCallDelegate: VideoCallDelegate?
    private let logger = NeedleTailLogger("[VideoCallViewController]")
    private let controllerView = ControllerView()
    private let videoViews = VideoViews()
    private unowned let session: RTCSession
    public var usesEmbeddedControls = false
    private var duration: TimeInterval = 0
    private var isRunning = true
    private var showPip = false
    private var isMutingAudio = false
    private var isMutingVideo = false
    private var pipController: AVPictureInPictureController?
    private weak var pipDelegate: PiPEventReceiverDelegate?
    private var currentCall: Call?
    private var currentCallState: CallStateMachine.State = .waiting
    private var dataSource: UICollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>?
    private var isMinimized = false
    private static let sections = CollectionViewSections()
    private var loadedPreviewItem = false
    private var upgradedToVideo = false
    private var didUpgradeDowngrade = false
    private var speakerPhoneEnabled = false
    
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
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
#if DEBUG
        // Intentionally no print; rely on logger if needed
#endif
    }
    var stateStreamTask: Task<Void, Never>?
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.isScrollEnabled = false
        collectionView.delegate = self
        collectionView.allowsSelection = true
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        self.configureCollectionView()
        self.configureDataSource()
        
        stateStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.controllerView.voiceImageData = await self.session.avatar
            self.controllerView.calleeLabel.text = await self.session.callee
            guard let stateStream = await self.session.callState._currentCallStream.last else { return }
            
            for await state in stateStream {
                guard state != self.currentCallState else { continue }
                currentCallState = state
                await videoCallDelegate?.deliverCallState(currentCallState)
                
                switch state {
                case .waiting:
                    break
                case .ready(let currentCall):
                    self.currentCall = currentCall
                    self.controllerView.statusLabel.text = "Ready to Connect"
                case .connecting(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    if let text = self.controllerView.calleeLabel.text, text.isEmpty {
                        self.controllerView.calleeLabel.text = currentCall.sender.secretName
                    }
                    self.controllerView.statusLabel.text = "Connecting..."
                    self.controllerView.statusLabel.fadeInOutLoop(duration: 1.5)
                    
                    switch callDirection {
                    case .inbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            self.upgradedToVideo = true
                            await self.createPreviewView()
                            self.controllerView.bringControlsToFront()
                        }
                    case .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            self.upgradedToVideo = true
                            await self.createPreviewView()
                            self.controllerView.bringControlsToFront()
                        }
                    }
                    
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    self.controllerView.statusLabel.stopFadeInOutLoop()
                    self.controllerView.statusLabel.textColor = .white
                    self.controllerView.statusLabel.font = .boldSystemFont(ofSize: 16)
                    
                    switch callDirection {
                    case .inbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            self.upgradedToVideo = true
                            await createSampleView()
                        }
                    case .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            self.upgradedToVideo = true
                            await createSampleView()
                        }
                    }
                    await incrementDuration()
                case .held(_, _):
                    controllerView.statusLabel.text = "Held"
                case .ended(_, _):
                    currentCall = nil
                    controllerView.statusLabel.text = "Ended"
                    dismiss(animated: true)
                case .failed(_, _, let errorMessage):
                    controllerView.statusLabel.text = "Failed"
                    currentCall = nil
                    await videoCallDelegate?.passErrorMessage(errorMessage)
                    dismiss(animated: true)
                case .receivedVideoUpgrade:
                    self.upgradedToVideo = true
                    await createPreviewView(shouldQuery: false)
                    await createSampleView()
                    await videoCallDelegate?.videoUpgraded(true)
                case .receivedVoiceDowngrade:
                    self.upgradedToVideo = false
                    await tearDownPreviewView()
                    await tearDownSampleView()
                    videoViews.views.removeAll()
                    await performQuery()
                    await videoCallDelegate?.videoUpgraded(false)
                    
                case .callAnsweredAuxDevice:
                    controllerView.statusLabel.text = "Answered on Auxiliary Device"
                    currentCall = nil
                    await tearDownCall()
                    dismiss(animated: true)
                }
            }
        }
    }
    
    private func tearDownCall() async {
        guard isRunning == true else {
            return
        }
        if let currentCall {
            do {
                try await self.session._delegate?.invokeEnd(call: currentCall, endState: .userInitiated)
            } catch {
                logger.log(level: .error, message: "Error Invoking End \(error)")
            }
        }
        await tearDownPreviewView()
        await tearDownSampleView()
        isRunning = false
        await session.shutdown()
        videoViews.views.removeAll()
        deleteSnap()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        dataSource = nil
        self.currentCall = nil
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await tearDownCall()
        }
    }
    
    func createPreviewView(shouldQuery: Bool = true) async {
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
            
            //Wait to render until query finished
            try? await NTKLoop().run(5, sleep: .seconds(1)) { [weak self] in
                guard let self else { return false }
                var canRun = true
                if await loadedPreviewItem {
                    canRun = false
                }
                return canRun
            }
            loadedPreviewItem = false
        }
        
        await localVideoView.startRendering()
        if shouldQuery {
            await performQuery()
        }
        localVideoView.isUserInteractionEnabled = true
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        let connection = await session.connectionManager.findConnection(with: connectionId)
        guard let previewRenderer = localVideoView.renderer as? PreviewViewRender else { return }
        if let wrapper = connection?.rtcVideoCaptureWrapper {
            await previewRenderer.setCapture(wrapper)
        }
        await self.session.renderLocalVideo(to: previewRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        await self.session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    func createSampleView(removePreview: Bool = true) async {
        let remoteVideoView: NTMTKView
        do {
            remoteVideoView = try NTMTKView(type: .sample, contextName: "sample")
        } catch {
            logger.log(level: .error, message: "Failed to create sample view: \(error)")
            return
        }
        videoViews.views.append(.init(videoView: remoteVideoView))
        await performQuery(removePreview: true)
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        await controllerView.addConnectedLocalVideoView(view: localView)
        
        //Wait to render until query finished
        try? await NTKLoop().run(5, sleep: .seconds(1)) { [weak self] in
            guard let self else { return false }
            var canRun = true
            if await loadedPreviewItem {
                canRun = false
            }
            return canRun
        }
        loadedPreviewItem = false
        
        await remoteVideoView.startRendering()
        guard let remoteRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        pipDelegate = remoteRenderer
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.renderRemoteVideo(
            to: remoteRenderer.rtcVideoRenderWrapper,
            with: connectionId)
        await self.session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    func tearDownPreviewView() async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        guard let localVideoRenderer = localView.renderer as? PreviewViewRender else { return }
        await localVideoRenderer.setCapture(nil)
        await localVideoRenderer.stopCaptureSession()
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.removeLocal(renderer: localVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        localView.shutdownMetalStream()
    }
    
    func tearDownSampleView() async {
        guard let remoteVideoView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        guard let remoteVideoRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        await remoteVideoRenderer.shutdown()
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.setVideoTrack(isEnabled: false, connectionId: connectionId)
        await session.removeRemote(renderer: remoteVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        remoteVideoView.shutdownMetalStream()
    }
    
    public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await session.callState._callType == .video || upgradedToVideo {
                guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
                controllerView.updateLocalVideoSize(with: UIDevice.current.orientation, should: false, isConnected: isConnected() ? true : false, view: localView)
            }
        }
    }
    
    func isConnected() -> Bool {
        switch currentCallState {
        case .connected(_, _):
            return true
        default:
            return false
        }
    }
    
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
    
    func deleteSnap() {
        // Ensure the data source is available
        guard var snapshot = dataSource?.snapshot() else { return }
        
        // Delete the section and all its items
        snapshot.deleteSections([.initial])
        
        // Apply the updated snapshot to the data source
        dataSource?.apply(snapshot, animatingDifferences: true)
    }
    
    func configureCollectionView() {
        collectionView.register(RemoteViewItemCell.self, forCellWithReuseIdentifier: RemoteViewItemCell.reuseIdentifier)
    }
    
    fileprivate func setCollectionViewItem(item: RemoteViewItemCell? = nil, viewModel: VideoViewModel) {
        guard let item = item else { return }
        item.addSubview(viewModel.videoView)
        viewModel.videoView.anchors(
            top: item.topAnchor,
            leading: item.leadingAnchor,
            bottom: item.bottomAnchor,
            trailing: item.trailingAnchor
        )
    }
    
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
                    fatalError("Cannot create other item")
                }
            }
        }
    }
    
    static func createLayout(sectionType: SectionType) -> UICollectionViewCompositionalLayout {
        switch sectionType {
        case .fullscreen:
            return UICollectionViewCompositionalLayout(section: sections.fullScreenItem())
        case .conference:
            return UICollectionViewCompositionalLayout(section: sections.conferenceViewSection(itemCount: 2))
        }
    }
    
    func incrementDuration() async {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isRunning {
                try await Task.sleep(until: .now + .seconds(1))
                self.duration += 1
                controllerView.statusLabel.text = formatDuration(self.duration)
            }
        }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        
        return formatter.string(from: duration) ?? "00:00:00"
    }
    
    
    @objc func dragView(_ sender: UIPanGestureRecognizer) {}
    
    private func downgradeToVoice(callId: String) async throws {
        await tearDownPreviewView()
        await tearDownSampleView()
        videoViews.views.removeAll()
        await performQuery()
        
        let call = try await session.downgradeToVoice(connectionId: callId)
        
        try await session._delegate?.sendUpDowngrade(
            to: call,
            isUpgrade: false)
        
        upgradedToVideo = false
        didUpgradeDowngrade = false
    }
    
    private func upgradeToVideo(callId: String) async throws {
        if let connection = await session.connectionManager.findConnection(with: callId) {
            let updatedConnection = try await session.addVideoToStream(with: connection)
            await session.connectionManager.updateConnection(id: callId, with: updatedConnection)
        }
        await createPreviewView(shouldQuery: false)
        await createSampleView()
        upgradedToVideo = true
        didUpgradeDowngrade = false
    }
    
    
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
    
    @objc func dragPreviewView(_ sender:UIPanGestureRecognizer) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            controllerView.bringSubviewToFront(localView)
            let translation = sender.translation(in: self.view)
            localView.center = CGPoint(x: localView.center.x + translation.x, y: localView.center.y + translation.y)
            sender.setTranslation(CGPoint.zero, in: self.view)
        }
    }
    
    @objc func tapPreviewView() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isMinimized.toggle()
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            controllerView.updateLocalVideoSize(with: UIDevice.current.orientation, should: isMinimized, isConnected: isConnected() ? true : false, view: localView)
        }
    }
    
    private func setRenderOnMetal(_ shouldRender: Bool) async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        if let renderer = localView.renderer as? PreviewViewRender {
            await renderer.setShouldRender(shouldRender)
        }
    }
}

extension VideoCallViewController: CallActionDelegate {
    public func endCall() {
        Task { [weak self] in
            guard let self else { return }
            if let currentCall {
                try await session._delegate?.invokeEnd(call: currentCall, endState: .userInitiated)
                self.currentCall = nil
            }
            dismiss(animated: true)
        }
    }
    
    public func muteAudio() {
        isMutingAudio.toggle()
        Task { @MainActor [weak self] in
            guard let self = self,
                  let callId = self.currentCall?.sharedCommunicationId else { return }
            do {
                try await self.session.setAudioTrack(isEnabled: !self.isMutingAudio, connectionId: callId)
            } catch {
                self.logger.log(level: .error, message: "Failed to set audio track: \(error)")
            }
            
            if await self.session.callState._callType == .video {
                self.muteVideo()
            }
        }
    }
    
    public func muteVideo() {
        isMutingVideo.toggle()
        Task { @MainActor [weak self] in
            guard let self = self,
                  let callId = self.currentCall?.sharedCommunicationId else { return }
            await self.blurView(self.isMutingVideo)
            await session.setVideoTrack(isEnabled: !self.isMutingVideo, connectionId: callId)
        }
    }
    
    public func upgradeDowngrade() {
        if !didUpgradeDowngrade {
            didUpgradeDowngrade = true
            Task { @MainActor [weak self] in
                guard let self = self,
                      let callId = self.currentCall?.sharedCommunicationId else {
                    self?.didUpgradeDowngrade = false
                    return
                }
                do {
                    if upgradedToVideo {
                        try await downgradeToVoice(callId: callId)
                    } else {
                        try await upgradeToVideo(callId: callId)
                    }
                } catch {
                    didUpgradeDowngrade = false
                }
            }
        }
    }
    
    public func toggleSpeakerPhone() {
        speakerPhoneEnabled.toggle()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.currentCall?.supportsVideo == true {
                speakerPhoneEnabled = true
            }
            try await session.setAudioMode(mode: !speakerPhoneEnabled ? .videoChat : .voiceChat)
        }
    }
    
    public func showPictureInPicture(_ show: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.showPip(show: show)
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
    
    func showPip(show: Bool) async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        if show {
            if AVPictureInPictureController.isPictureInPictureSupported() {
                //                    guard let previewRenderer = localView.renderer as? PreviewViewRender else { return }
                //                    guard let captureSession = previewRenderer.layer.session else { return }
                //                        let remoteVideoScale = UserDefaults.standard.integer(forKey: "remoteVideoScale")
                //                        let scaleWithOrientation = UserDefaults.standard.bool(forKey: "scaleWithOrientation")
                
                let pipVideoCallViewController = AVPictureInPictureVideoCallViewController()
                let remotePipView = try! NTMTKView(type: .sample, contextName: "pip")
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
            guard let captureSession = previewRenderer.layer.session else { return }
            if captureSession.isMultitaskingCameraAccessSupported {
                pipController?.stopPictureInPicture()
                self.pipController = nil
            } else {
                pipController?.stopPictureInPicture()
            }
        }
    }
    
    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        
    }
    nonisolated public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
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

extension AVCaptureVideoPreviewLayer: @retroactive @unchecked Sendable {}
#endif
