//
//  VideoCallViewController+AppKit.swift
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
#if os(macOS)
import AppKit
import NTKLoop
import NeedleTailLogger

@MainActor
public final class VideoCallViewController: NSViewController {
    
    private unowned let session: RTCSession
    let sections = CollectionViewSections()
    var dataSource: NSCollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>?
    private let videoViews = VideoViews()
    private lazy var currentCallState: CallStateMachine.State = .waiting
    private var currentCall: Call?
    private var isMutingAudio = false
    private var isMutingVideo = false
    private var isRunning = true
    private var shouldCloseWindow = true
    private var duration: TimeInterval = 0
    private var loadedPreviewItem = false
    private var upgradedToVideo = false
    private var didUpgradeDowngrade = false
    public weak var videoCallDelegate: VideoCallDelegate?
    private let logger = NeedleTailLogger("[VideoCallViewController]")
    public var usesEmbeddedControls = false
    
    public init(session: RTCSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.logger.log(level: .debug, message: "Reclaimed memory in VideoCallViewController")
    }
    var stateStreamTask: Task<Void, Never>?
    
    public override func loadView() {
        view = ControllerView()
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        let controllerView = self.view as! ControllerView
        
        self.configureCollectionView()
        self.configureDataSource()
        
        stateStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
            controllerView.voiceImageData = await self.session.avatar
            controllerView.calleeLabel.stringValue = await self.session.callee
            guard let stateStream = await session.callState.getCurrentCallStream().last else { return }
            
            for await state in stateStream {
                guard state != self.currentCallState else { continue }
                self.currentCallState = state
                await videoCallDelegate?.deliverCallState(currentCallState)
                
                switch state {
                case .waiting:
                    break
                case .ready:
                    self.currentCall = currentCall
                    controllerView.statusLabel.stringValue = "Ready to Connect"
                case .connecting(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    if controllerView.calleeLabel.stringValue.isEmpty {
                        controllerView.calleeLabel.stringValue = currentCall.sender.secretName
                    }
                   controllerView.statusLabel.stringValue = "Connecting..."
                   controllerView.statusLabel.fadeInOutLoop(duration: 1.5)
                    
                    switch callDirection {
                    case .inbound(let callType):
                        switch callType {
                        case .voice:
                            await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
                            controllerView.anchors(width: 450, height: 100)
                        case .video:
                            upgradedToVideo = true
                            await self.videoCallDelegate?.passSize(.init(width: 335, height: 475))
                            controllerView.anchors(
                                top: self.view.topAnchor,
                                leading: self.view.leadingAnchor,
                                bottom: self.view.bottomAnchor,
                                trailing: self.view.trailingAnchor,
                                minWidth: 335,
                                minHeight: 475)
                            await createPreviewView()
                        }
                    case .outbound(let callType):
                        switch callType {
                        case .voice:
                            await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
                            controllerView.anchors(width: 450, height: 100)
                        case .video:
                            upgradedToVideo = true
                            await self.videoCallDelegate?.passSize(.init(width: 335, height: 475))
                            controllerView.anchors(
                                top: self.view.topAnchor,
                                leading: self.view.leadingAnchor,
                                bottom: self.view.bottomAnchor,
                                trailing: self.view.trailingAnchor,
                                minWidth: 335,
                                minHeight: 475)
                            await createPreviewView()
                        }
                    }
                    
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    controllerView.statusLabel.stopFadeInOutLoop()
                    switch callDirection {
                    case .inbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            upgradedToVideo = true
                            await createSampleView()
                        }
                    case .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            upgradedToVideo = true
                            await createSampleView()
                        }
                    }
                    await incrementDuration()
                case .held(_, _):
                    controllerView.statusLabel.stringValue = "Held"
                case .ended(_, _):
                    controllerView.statusLabel.stringValue = "Ended"
                    await tearDownCall()
                case .failed(_, _, let errorMessage):
                    controllerView.statusLabel.stringValue = "Failed"
                    await session.stopRingtone()
                    await videoCallDelegate?.passErrorMessage(errorMessage)
                    if currentCall != nil {
                        await tearDownCall()
                    }
                case .receivedVideoUpgrade:
                    upgradedToVideo = true
                    await self.videoCallDelegate?.passSize(.init(width: 375, height: 475))
                    controllerView.anchors(
                        top: self.view.topAnchor,
                        leading: self.view.leadingAnchor,
                        bottom: self.view.bottomAnchor,
                        trailing: self.view.trailingAnchor,
                        minWidth: 335,
                        minHeight: 475)
                    await createPreviewView()
                    await createSampleView()
                    await videoCallDelegate?.videoUpgraded(true)
                case .receivedVoiceDowngrade:
                    upgradedToVideo = false
                    await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
                    controllerView.anchors(width: 450, height: 100)
                    
                    // Voice added, so remove video stuff
                    await tearDownPreviewView()
                    await tearDownSampleView()
                    videoViews.removeAllViews()
                    await performQuery()
                    await videoCallDelegate?.videoUpgraded(false)
                    
                case .callAnsweredAuxDevice(_):
                    controllerView.statusLabel.stringValue = "Answered on Auxiliary Device"
                    currentCall = nil
                    await tearDownCall()
                }
            }
        }
    }
    
    func incrementDuration() async {
        let controllerView = self.view as! ControllerView
        Task { [weak self] in
            guard let self else { return }
            while self.isRunning {
                try await Task.sleep(until: .now + .seconds(1))
                self.duration += 1
                controllerView.statusLabel.stringValue = formatDuration(self.duration)
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

    private func downgradeToVoice(callId: String) async throws {
        await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
        let controllerView = self.view as! ControllerView
        controllerView.anchors(width: 450, height: 100)
        // Voice added, so remove video stuff
        await tearDownPreviewView()
        await tearDownSampleView()
        videoViews.removeAllViews()
        await performQuery()
        
        let call = try await session.downgradeToVoice(connectionId: callId)
        
        try await session.getDelegate()?.sendUpDowngrade(
            to: call,
            isUpgrade: false)
        
        upgradedToVideo = false
        didUpgradeDowngrade = false
    }
    
    private func upgradeToVideo(callId: String) async throws {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if let connection = await session.connectionManager.findConnection(with: connectionId) {
            let updatedConnection = try await session.addVideoToStream(with: connection)
            await session.connectionManager.updateConnection(id: connectionId, with: updatedConnection)
        }
        await self.videoCallDelegate?.passSize(.init(width: 335, height: 475))
        let controllerView = self.view as! ControllerView
        controllerView.anchors(
            top: self.view.topAnchor,
            leading: self.view.leadingAnchor,
            bottom: self.view.bottomAnchor,
            trailing: self.view.trailingAnchor,
            minWidth: 335,
            minHeight: 475)
        await createPreviewView(shouldQuery: false)
        await createSampleView(wasAudioCall: true)
        
        let call = try await session.upgradeToVideo(connectionId: callId)
        
        try await session.getDelegate()?.sendUpDowngrade(
            to: call,
            isUpgrade: true)
        upgradedToVideo = true
        didUpgradeDowngrade = false
    }
    
    private func setRenderOnMetal(_ shouldRender: Bool) async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        if let renderer = localView.renderer as? PreviewViewRender {
            await renderer.setShouldRender(shouldRender)
        }
    }
    
    private var blurEffectView: NSVisualEffectView?
    
    func blurView(_ shouldBlur: Bool) async {
        if shouldBlur {
            
            if blurEffectView == nil {
                blurEffectView = NSVisualEffectView()
                blurEffectView?.material = .sidebar
                blurEffectView?.blendingMode = .behindWindow
                blurEffectView?.state = .active
                blurEffectView?.frame = self.view.bounds
                blurEffectView?.autoresizingMask = [.width, .height]
            }
            
            guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
            remoteView.addSubview(blurEffectView!)
            guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            localView.addSubview(blurEffectView!)
        } else {
            blurEffectView?.removeFromSuperview()
            blurEffectView = nil
        }
    }
    
    private func tearDownCall() async {
        guard isRunning == true else {
            return
        }
        await Task {
            if let currentCall {
                do {
                    try await session.getDelegate()?.invokeEnd(call: currentCall, endState: .userInitiated)
                } catch {
                    logger.log(level: .error, message: "Error Invoking End \(error)")
                }
            }
        }.value
        await tearDownPreviewView()
        await tearDownSampleView()
        let videoView = self.view as! ControllerView
        isRunning = false
        blurEffectView?.removeFromSuperview()
        blurEffectView = nil
        videoView.tearDownView()
        await session.shutdown()
        videoViews.removeAllViews()
        deleteSnap()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        dataSource = nil
        self.currentCall = nil
        await videoCallDelegate?.endedCall(true)
    }
    
    public override func viewWillDisappear() {
        shouldCloseWindow = false
        Task { [weak self] in
            guard let self else { return }
            if currentCall != nil {
                await self.tearDownCall()
            }
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
        videoViews.addView(.init(videoView: localVideoView))
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
        localVideoView.shouldRenderOnMetal = true
        if shouldQuery {
            await performQuery()
        }
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        let connection = await session.connectionManager.findConnection(with: connectionId)
        guard let previewRenderer = localVideoView.renderer as? PreviewViewRender else { return }
        if let wrapper = connection?.rtcVideoCaptureWrapper {
            await previewRenderer.setCapture(wrapper)
        }
        await self.session.renderLocalVideo(to: previewRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        await self.session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    func createSampleView(wasAudioCall: Bool = false) async {
        let remoteVideoView: NTMTKView
        do {
            remoteVideoView = try NTMTKView(type: .sample, contextName: "sample")
        } catch {
            logger.log(level: .error, message: "Failed to create sample view: \(error)")
            return
        }
        videoViews.addView(.init(videoView: remoteVideoView))
        await performQuery(removePreview: true)
        let controllerView = self.view as! ControllerView
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
        remoteVideoView.shouldRenderOnMetal = true
        guard let remoteRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.renderRemoteVideo(
            to: remoteRenderer.rtcVideoRenderWrapper,
            with: connectionId)
        await self.session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }
    
    func tearDownPreviewView() async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        guard let localVideoRenderer = localView.renderer as? PreviewViewRender else { return }
        await localVideoRenderer.stopCaptureSession()
        await localVideoRenderer.setCapture(nil)
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
    
    
    func performQuery(removePreview: Bool = false) async {
        var snapshot = NSDiffableDataSourceSnapshot<ConferenceCallSections, VideoViewModel>()
        dataSource?.apply(snapshot)
        
        var data = await videoViews.getViews()
        if removePreview {
            data.removeAll(where: { $0.videoView.contextName == "preview" })
        }
        if data.isEmpty {
            snapshot.deleteSections([.initial])
            snapshot.deleteItems(data)
            dataSource?.apply(snapshot, animatingDifferences: false)
        } else {
            snapshot.appendSections([.initial])
            snapshot.appendItems(data, toSection: .initial)
            dataSource?.apply(snapshot)
        }
    }
    
    func deleteSnap() {
        // Ensure the data source is available
        guard var snapshot = dataSource?.snapshot() else { return }
        
        // Delete the section and all its items
        snapshot.deleteAllItems()
        // Apply the updated snapshot to the data source
        dataSource?.apply(snapshot, animatingDifferences: true)
    }
}

extension VideoCallViewController {
    
    func configureCollectionView() {
        let controllerView = self.view as! ControllerView
        let collectionView = controllerView.scrollView.documentView as! VideoCallCollectionView
        collectionView.collectionViewLayout = createLayout()
        collectionView.register(VideoItem.self, forItemWithIdentifier: Constants.VIDEO_IDENTIFIER)
    }
    
    func configureDataSource() {
        let controllerView = self.view as! ControllerView
        let collectionView = controllerView.scrollView.documentView as! VideoCallCollectionView
        dataSource = NSCollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>(
            collectionView: collectionView) { @MainActor [weak self]
                (collectionView: NSCollectionView,
                 indexPath: IndexPath,
                 identifier: Any) -> NSCollectionViewItem? in
                guard let self else {return nil}
                let item = collectionView.makeItem(withIdentifier: Constants.VIDEO_IDENTIFIER, for: indexPath) as! VideoItem
                if let model = identifier as? VideoViewModel {
                    item.view.addSubview(model.videoView)
                    model.videoView.anchors(
                        top: item.view.topAnchor,
                        leading: item.view.leadingAnchor,
                        bottom: item.view.bottomAnchor,
                        trailing: item.view.trailingAnchor)
                    model.videoView.layoutSubtreeIfNeeded()
                    self.loadedPreviewItem = true
                } else {
                    fatalError("Cannot create other item")
                }
                return item
            }
    }
    
    
    fileprivate func createLayout() -> NSCollectionViewLayout {
        let layout = NSCollectionViewCompositionalLayout { [weak self]
            (sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection in
            guard let self else { fatalError("THIS SHOULD NEVER HAPPEN") }
            return sections.fullScreenItem()
        }
        return layout
    }
}


extension VideoCallViewController: CallActionDelegate {
    public func endCall() {
        Task.detached { [weak self] in
            guard let self else { return }
            await self.tearDownCall()
        }
    }
    public func muteAudio() {
        isMutingAudio.toggle()
        Task { [weak self] in
            guard let self = self,
                  let callId = self.currentCall?.sharedCommunicationId else { return }
            
            self.isMutingAudio.toggle()
            do {
                try await self.session.setAudioTrack(isEnabled: self.isMutingAudio, connectionId: callId)
            } catch {
                self.logger.log(level: .error, message: "Failed to set audio track: \(error)")
            }
            
            if await session.callState.getCallType() == .video {
                muteVideo()
            }
        }
    }
    public func muteVideo() {
        isMutingVideo.toggle()
        Task { [weak self] in
            guard let self = self,
                  let callId = self.currentCall?.sharedCommunicationId else { return }
            
            await session.setVideoTrack(isEnabled: !self.isMutingVideo, connectionId: callId)
            await self.blurView(self.isMutingVideo)
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
                let controllerView = self.view as! ControllerView
                controllerView.upgradeDowngradeMedia.layer?.opacity = 1.0
            }
        }
    }
    public func toggleSpeakerPhone() {
        // No-op on macOS; not applicable
    }
    public func showPictureInPicture(_ show: Bool) {
        // No-op on macOS; not implemented
    }
}
#endif
