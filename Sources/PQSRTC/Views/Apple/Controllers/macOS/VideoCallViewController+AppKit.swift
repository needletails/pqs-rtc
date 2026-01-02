//
//  VideoCallViewController+AppKit.swift
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

#if os(macOS)
import AppKit
import NTKLoop
import NeedleTailLogger

@MainActor
/// macOS in-call UI controller.
///
/// This view controller renders local/remote video for a single active call managed by
/// ``RTCSession``. It listens to the session's ``CallStateMachine`` stream, updates the UI
/// accordingly, and drives video rendering via Metal-based views.
///
/// The host application typically embeds this controller using the SwiftUI representable
/// wrappers and receives user actions via ``VideoCallDelegate`` / ``CallActionDelegate``.
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
    /// Delegate that receives high-level UI events (call state updates, window sizing, etc.).
    public weak var videoCallDelegate: VideoCallDelegate?
    private let logger = NeedleTailLogger("[VideoCallViewController]")
    /// If `true`, the host app provides its own controls overlay via ``setControlsView(_:)``.
    public var usesEmbeddedControls = false
    private weak var controlsView: NSView?
    
    /// Creates a macOS call UI controller bound to a specific ``RTCSession``.
    public init(session: RTCSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        
    }
    
    required init?(coder: NSCoder) {
        return nil
    }
    
    deinit {
        self.logger.log(level: .debug, message: "Reclaimed memory in VideoCallViewController")
    }
    /// Task that consumes the session call-state stream and drives UI updates.
    var stateStreamTask: Task<Void, Never>?
    
    /// Installs the AppKit view hierarchy for the controller.
    public override func loadView() {
        view = ControllerView()
    }
    
    /// Subscribes to call state updates and updates UI + rendering accordingly.
    ///
    /// This method:
    /// - configures the collection view/data source
    /// - listens to the session's call state stream
    /// - creates/tears down Metal render views as the call transitions between voice/video
    public override func viewDidLoad() {
        super.viewDidLoad()
        let controllerView = self.view as! ControllerView
        
        self.configureCollectionView()
        self.configureDataSource()
        
        stateStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
            guard let stateStream = await session.callState._currentCallStream.last else { return }
            
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
                case .callAnsweredAuxDevice(_):
                    controllerView.statusLabel.stringValue = "Answered on Auxiliary Device"
                    currentCall = nil
                    await tearDownCall()
                }
            }
        }
    }
    
    /// Starts a lightweight loop that updates the duration label every second while the call is active.
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
    
    /// Formats a duration as a positional clock string (e.g. `00:01:23`).
    func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        
        return formatter.string(from: duration) ?? "00:00:00"
    }
    
    /// Enables/disables Metal rendering for the local preview view.
    private func setRenderOnMetal(_ shouldRender: Bool) async {
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        if let renderer = localView.renderer as? PreviewViewRender {
            await renderer.setShouldRender(shouldRender)
        }
    }
    
    private var blurEffectView: NSVisualEffectView?
    
    /// Adds or removes a blur overlay over the video views.
    ///
    /// Used on macOS to obscure video when muted (and to match the call UI styling).
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
        // Prevent concurrent teardown from running more than once
        isRunning = false
        
        if let currentCall {
            do {
                let transport = try await session.requireTransport()
                try await transport.didEnd(
                    call: currentCall,
                    endState: CallStateMachine.EndState.userInitiated)
            } catch {
                logger.log(level: .error, message: "Error Invoking End \(error)")
            }
        }
        await tearDownPreviewView()
        await tearDownSampleView()
        let videoView = self.view as! ControllerView
        blurEffectView?.removeFromSuperview()
        blurEffectView = nil
        videoView.tearDownView()
        await session.shutdown(with: currentCall)
        videoViews.removeAllViews()
        deleteSnap()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        dataSource = nil
        self.currentCall = nil
        await videoCallDelegate?.endedCall(true)
    }
    
    /// Ensures an in-progress call is ended if the controller is dismissed.
    public override func viewWillDisappear() {
        shouldCloseWindow = false
        Task { [weak self] in
            guard let self else { return }
            if currentCall != nil {
                await self.tearDownCall()
            }
        }
    }
    
    /// Creates and starts the local preview Metal view.
    ///
    /// - Parameter shouldQuery: If `true`, triggers a diffable-data-source refresh so the view is
    ///   inserted into the collection view before rendering begins.
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
    
    /// Creates and starts the remote sample (receive) Metal view.
    ///
    /// - Parameter wasAudioCall: Currently unused; retained for call-type transitions.
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
    
    
    /// Rebuilds and applies the diffable-data-source snapshot from the current Metal view list.
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
    
    /// Clears all items from the current diffable snapshot.
    func deleteSnap() {
        // Ensure the data source is available
        guard var snapshot = dataSource?.snapshot() else { return }
        
        // Delete the section and all its items
        snapshot.deleteAllItems()
        // Apply the updated snapshot to the data source
        dataSource?.apply(snapshot, animatingDifferences: true)
    }
    
    // MARK: - Controls view injection
    @MainActor
    /// Installs a custom controls overlay.
    ///
    /// This is primarily used when the host app wants to provide a bespoke control
    /// surface (mute/end/pip) while reusing PQSRTC's rendering and state wiring.
    public func setControlsView(_ view: NSView) {
        controlsView?.removeFromSuperview()
        controlsView = view
        self.view.addSubview(view)
        view.anchors(
            top: self.view.topAnchor,
            leading: self.view.leadingAnchor,
            bottom: self.view.bottomAnchor,
            trailing: self.view.trailingAnchor
        )
        if let controllerView = self.view as? ControllerView {
            controllerView.layoutSubtreeIfNeeded()
        }
    }
}

extension VideoCallViewController {
    /// Collection view and diffable-data-source setup helpers.
    func configureCollectionView() {
        let controllerView = self.view as! ControllerView
        let collectionView = controllerView.scrollView.documentView as! VideoCallCollectionView
        collectionView.collectionViewLayout = createLayout()
        collectionView.register(VideoItem.self, forItemWithIdentifier: Constants.VIDEO_IDENTIFIER)
    }
    
    /// Configures the diffable data source to render ``VideoViewModel`` items.
    func configureDataSource() {
        let controllerView = self.view as! ControllerView
        let collectionView = controllerView.scrollView.documentView as! VideoCallCollectionView
        dataSource = NSCollectionViewDiffableDataSource<ConferenceCallSections, VideoViewModel>(
            collectionView: collectionView) { @MainActor [weak self]
                (collectionView: NSCollectionView,
                 indexPath: IndexPath,
                 identifier: Any) -> NSCollectionViewItem? in
                guard let self else {return nil}
                guard let item = collectionView.makeItem(withIdentifier: Constants.VIDEO_IDENTIFIER, for: indexPath) as? VideoItem else {
                    assertionFailure("Could not create VideoItem for identifier \(Constants.VIDEO_IDENTIFIER)")
                    return NSCollectionViewItem()
                }
                guard let model = identifier as? VideoViewModel else {
                    assertionFailure("Unexpected identifier type for VideoItem")
                    return item
                }
                item.view.addSubview(model.videoView)
                model.videoView.anchors(
                    top: item.view.topAnchor,
                    leading: item.view.leadingAnchor,
                    bottom: item.view.bottomAnchor,
                    trailing: item.view.trailingAnchor)
                model.videoView.layoutSubtreeIfNeeded()
                self.loadedPreviewItem = true
                return item
            }
    }
    
    
    /// Creates the compositional layout used for the call video grid.
    fileprivate func createLayout() -> NSCollectionViewLayout {
        let layout = NSCollectionViewCompositionalLayout { [weak self]
            (_: Int, _: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection in
            guard let self else {
                return CollectionViewSections().fullScreenItem()
            }
            return self.sections.fullScreenItem()
        }
        return layout
    }
}


extension VideoCallViewController: CallActionDelegate {
    /// Ends the current call and tears down local/remote rendering.
    public func endCall() async {
        await tearDownCall()
    }
    
    /// Toggles the local audio track and updates the session.
    public func muteAudio() async {
        guard let callId = currentCall?.sharedCommunicationId else { return }
        
        isMutingAudio.toggle()
        do {
            // When isMutingAudio is true, disable audio track
            try await session.setAudioTrack(isEnabled: !isMutingAudio, connectionId: callId)
        } catch {
            logger.log(level: .error, message: "Failed to set audio track: \(error)")
        }
        
        if await session.callState._callType == .video {
            await muteVideo()
        }
    }
    
    /// Toggles the local video track and applies a blur overlay when video is muted.
    public func muteVideo() async {
        guard let callId = currentCall?.sharedCommunicationId else { return }
        
        isMutingVideo.toggle()
        await session.setVideoTrack(isEnabled: !isMutingVideo, connectionId: callId)
        await blurView(isMutingVideo)
    }

    public func toggleSpeakerPhone() {
        // No-op on macOS; not applicable
    }
    
    public func showPictureInPicture(_ show: Bool) async {
        // No-op on macOS; not implemented
    }
}
#endif
