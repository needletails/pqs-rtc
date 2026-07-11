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

/// Sits above `PreviewCaptureView` / layer content so `NSGestureRecognizer` receives clicks and drags reliably.
private final class LocalPreviewGestureHostView: NSView {
    override var isOpaque: Bool { false }

    /// Without this, the first click on an inactive window only activates it; the PiP minimize toggle needs one click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

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
    private var duration: TimeInterval = 0
    private var loadedPreviewItem = false
    private var upgradedToVideo = false
    private var didUpgradeDowngrade = false
    private var previewDetachedToOverlay = false
    private weak var detachedPreviewView: NTMTKView?
    private var isPreviewMinimized = false
    private var isDraggingPreview = false
    /// Diffable snapshot apply can overlap AppKit layout; avoid re-entering PiP reconfiguration there.
    private var isApplyingCollectionSnapshot = false
    /// Coalesce repeated local-preview reconfiguration requests onto the next main run loop tick.
    private var previewConfigurationScheduled = false
    private var previewConfigurationNeedsAnimation = false
    /// Avoid re-entering preview reconfiguration while constraints are actively being changed.
    private var isConfiguringLocalPreview = false
    /// Periodically recovers remote renderer when frame callbacks stop (track/renderer rebind).
    private var remoteRendererRecoveryTask: Task<Void, Never>?
    private var lastRemoteRendererRecoveryUptimeNs: UInt64 = 0
    private var participantRendererRecoveryTasksByKey: [String: Task<Void, Never>] = [:]
    private var lastParticipantRendererRecoveryUptimeNsByKey: [String: UInt64] = [:]
    private var screenShareRendererRecoveryTasksByKey: [String: Task<Void, Never>] = [:]
    private var lastScreenShareRendererRecoveryUptimeNsByKey: [String: UInt64] = [:]
    /// Ignores PiP minimize/maximize clicks briefly after a drag ends so pan + click cannot double-toggle.
    private var previewToggleClickSuppressionDeadline: Date?
    /// Cumulative drag distance for the active pan; sub-pixel jitter must not suppress a tap meant as minimize.
    private var previewPanAccumulatedDistance: CGFloat = 0
    /// Movement past this (points) counts as a real drag for post-drag click suppression.
    private let previewPanSuppressionDistanceThreshold: CGFloat = 6
    /// `NSObjectProtocol` is not `Sendable`; token is only used from main; `deinit` must remove it without isolation.
    nonisolated(unsafe) private var localVideoMirrorObserver: NSObjectProtocol?
    nonisolated(unsafe) private var preferredVideoCaptureDeviceObserver: NSObjectProtocol?
    /// Observe real host-window closes; SwiftUI/AppKit hosting can trigger view disappearance without a real close.
    nonisolated(unsafe) private var windowWillCloseObserver: NSObjectProtocol?
    /// Full-frame hit target above `PreviewCaptureView` / Metal so PiP pan/click aren’t swallowed by subviews.
    private weak var localPreviewGestureHostView: LocalPreviewGestureHostView?
    /// Delegate that receives high-level UI events (call state updates, window sizing, etc.).
    /// Strong so SwiftUI `Coordinator` survives for mute/state callbacks; cleared in ``tearDownCall()``.
    public var videoCallDelegate: VideoCallDelegate?
    /// Optional host-provided remote display name for call chrome labels.
    public var remotePartyNameOverride: String = ""
    /// Optional host-provided remote profile image bytes for voice chrome.
    public var remotePartyAvatarData: Data?
    private let logger = NeedleTailLogger("[VideoCallViewController]")
    /// Task observing local screen-share state changes from the session.
    private var localScreenShareStateTask: Task<Void, Never>?
    /// Task observing remote screen track events from the session.
    private var screenTrackStreamTask: Task<Void, Never>?
    /// Task observing remote participant camera track events from the session.
    private var participantTrackStreamTask: Task<Void, Never>?
    private var hasActiveLocalScreenShare = false
    /// Whether a remote screen-share tile is currently visible in the collection view.
    private var hasActiveRemoteScreenShare = false
    /// Whether any screen-share tile (local or remote) is visible — drives presentation layout.
    private var hasVisibleScreenShareInCollection = false
    /// Deferred layout pass after screen-share transitions (mirrors iOS heal for stale tile bounds).
    private var postScreenShareLayoutHealTask: Task<Void, Never>?
    private var localScreenShareAttachRetryTask: Task<Void, Never>?
    /// Participant id for the remote screen-share tile currently shown (mirrors Android guard).
    private var activeRemoteScreenShareParticipantId: String?
    private var remoteScreenShareAttachRetryTask: Task<Void, Never>?
    private var remoteScreenShareAttachRetryKey: String?
    /// Participant id for the local outgoing screen-share tile, when the host is sharing.
    private var localScreenShareTileParticipantId: String?
    /// Tracks the temporary expansion of an audio-call window while a share is visible.
    private var hasExpandedVoiceCallForScreenShare = false
    private var conferenceRaisedHands: [String: Bool] = [:]
    private var conferenceRaisedHandBadgeTopClearance: CGFloat = 0
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
        applyConferenceRaisedHandIndicators()
    }
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
        if let localVideoMirrorObserver {
            NotificationCenter.default.removeObserver(localVideoMirrorObserver)
        }
        if let preferredVideoCaptureDeviceObserver {
            NotificationCenter.default.removeObserver(preferredVideoCaptureDeviceObserver)
        }
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        self.logger.log(level: .debug, message: "Reclaimed memory in VideoCallViewController")
    }
    /// Task that consumes the session call-state stream and drives UI updates.
    var stateStreamTask: Task<Void, Never>?
    
    /// Installs the AppKit view hierarchy for the controller.
    public override func loadView() {
        let controllerView = ControllerView()
        controllerView.videoViewBase()
        view = controllerView
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
        controllerView.setCallInfoChromeHidden(usesEmbeddedControls)
        
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

        preferredVideoCaptureDeviceObserver = NotificationCenter.default.addObserver(
            forName: PQSRTCCallUIPreferences.preferredVideoCaptureDeviceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.applyPreferredVideoCaptureDeviceFromUserDefaults() }
        }
        
        stateStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.videoCallDelegate?.passSize(.init(width: 450, height: 100))
            
            // The host app may present this controller before `RTCSession.createStateStream(with:)`
            // has run. Wait until the stream exists rather than silently returning.
            var stateStream: AsyncStream<CallStateMachine.State>?
            while !Task.isCancelled {
                if let s = await session.callState._currentCallStream.last {
                    stateStream = s
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
            }
            guard let stateStream else { return }

            // If we subscribed late, the state machine may already be `.connected`.
            // AsyncStream doesn't replay, so bootstrap UI from the current state.
            if let current = await session.callState.currentState, current != self.currentCallState {
                self.currentCallState = current
                await videoCallDelegate?.deliverCallState(currentCallState)
                switch current {
                case .waiting:
                    break
                case .ready(let currentCall):
                    self.currentCall = currentCall
                    controllerView.statusLabel.stringValue = "Ready to Connect"
                case .connecting(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    applyConnectingChrome(for: currentCall)
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            await applyVoiceCallWindowLayout()
                        case .video:
                            await applyVideoCallWindowLayout()
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await createPreviewView()
                            }
                        }
                    }
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    controllerView.statusLabel.stopFadeInOutLoop()
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            await applyVideoCallWindowLayout()
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await createPreviewView(shouldQuery: true)
                            }
                            if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) == false {
                                await createSampleView()
                            }
                        }
                    }
                    await incrementDuration()
                case .held(_, let currentCall):
                    self.currentCall = currentCall
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
            
            for await state in stateStream {
                guard state != self.currentCallState else { continue }
                self.currentCallState = state
                await videoCallDelegate?.deliverCallState(currentCallState)
                
                switch state {
                case .waiting:
                    break
                case .ready(let currentCall):
                    self.currentCall = currentCall
                    controllerView.statusLabel.stringValue = "Ready to Connect"
                case .connecting(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    applyConnectingChrome(for: currentCall)
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            await applyVoiceCallWindowLayout()
                        case .video:
                            await applyVideoCallWindowLayout()
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await createPreviewView()
                            }
                        }
                    }
                case .connected(let callDirection, let currentCall):
                    self.currentCall = currentCall
                    controllerView.statusLabel.stopFadeInOutLoop()
                    switch callDirection {
                    case .inbound(let callType), .outbound(let callType):
                        switch callType {
                        case .voice:
                            break
                        case .video:
                            await applyVideoCallWindowLayout()
                            if videoViews.views.contains(where: { $0.videoView.contextName == "preview" }) == false {
                                await createPreviewView(shouldQuery: true)
                            }
                            if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) == false {
                                await createSampleView()
                            }
                        }
                    }
                    await incrementDuration()
                case .held(_, let currentCall):
                    self.currentCall = currentCall
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

    public override func viewDidAppear() {
        super.viewDidAppear()
        installWindowCloseObserverIfNeeded()
        startLocalScreenShareStateObservation()
        startRemoteScreenTrackObservation()
        startRemoteParticipantTrackObservation()
    }

    private func startLocalScreenShareStateObservation() {
        localScreenShareStateTask?.cancel()
        localScreenShareStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.session.localScreenShareStateStream()
            for await isSharing in stream {
                guard !Task.isCancelled else { return }
                self.hasActiveLocalScreenShare = isSharing
                if isSharing {
                    await self.createLocalScreenView()
                } else {
                    await self.tearDownLocalScreenView()
                }
                await self.videoCallDelegate?.screenShareDidChange(isSharing: isSharing)
            }
        }
    }

    private func startRemoteScreenTrackObservation() {
        screenTrackStreamTask?.cancel()
        screenTrackStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.session.remoteScreenTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self.handleRemoteScreenTrackEvent(event)
            }
        }
    }

    private func handleRemoteScreenTrackEvent(_ event: RemoteScreenTrackEvent) async {
        if !event.isActive {
            let hasVisibleScreenTiles = videoViews.views.contains(where: isRemoteScreenShareModel)
            let endedActiveShare = RTCSession.shouldAcceptRemoteScreenShareEnd(
                activeParticipantId: activeRemoteScreenShareParticipantId,
                endedParticipantId: event.participantId
            )
            guard endedActiveShare || hasVisibleScreenTiles || hasActiveRemoteScreenShare else {
                logger.log(
                    level: .debug,
                    message: "Ignoring remote screen-share removal for inactive participant=\(event.participantId); activeParticipant=\(activeRemoteScreenShareParticipantId ?? "nil")"
                )
                return
            }

            stopRemoteScreenShareAttachRetry()
            await tearDownScreenView(participantId: event.participantId)
            return
        }

        guard canPresentRemoteScreenShareUI(for: event.participantId) else {
            logger.log(
                level: .info,
                message: "Ignoring remote screen-share activation for unresolved SFU placeholder participant=\(event.participantId)"
            )
            return
        }
        if hasActiveLocalScreenShare {
            logger.log(
                level: .info,
                message: "Ignoring remote screen-share activation for participant=\(event.participantId) while local screen share is active"
            )
            return
        }
        guard await session.hasMappedRemoteScreenTrack(
            connectionId: event.connectionId,
            participantId: event.participantId
        ) else {
            logger.log(
                level: .info,
                message: "Ignoring remote screen-share activation with no mapped track for participant=\(event.participantId)"
            )
            return
        }
        activeRemoteScreenShareParticipantId = event.participantId
        if let existing = screenShareModel(matching: event.participantId, allowSingleFallback: false),
           hasActiveRemoteScreenShare {
            if await refreshScreenView(existing, connectionId: event.connectionId, participantId: event.participantId) {
                return
            }
        }
        await createScreenView(connectionId: event.connectionId, participantId: event.participantId)
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
                    await self.reconcileRemoteScreenShareAfterParticipantCameraEvent(
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
    
    /// Logged when root view bounds change (SwiftUI ↔ AppKit sizing).
    private var lastLayoutProbeBounds: CGSize = .zero
    /// Throttles `[VideoCallLayoutProbe] compositionalSection` (provider runs often during live resize).
    private var lastCompositionalLayoutProbeSignature: String = ""
    private static let isLayoutProbeEnabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["PQSRTC_LAYOUT_PROBE"] == "1"
        #endif
    }()
    /// When `effectiveContentSize` is briefly zero during live resize, fractional layout items collapse; reuse last good size.
    private var lastStableCompositionalContentSize: CGSize = CGSize(width: 335, height: 475)

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard let controllerView = self.view as? ControllerView else { return }
        let b = controllerView.bounds.size
        if b != lastLayoutProbeBounds {
            lastLayoutProbeBounds = b
            logLayoutProbe("viewDidLayout controllerBounds=\(Int(b.width))x\(Int(b.height)) scrollFrame=\(Int(controllerView.scrollView.frame.size.width))x\(Int(controllerView.scrollView.frame.size.height))")
        }
        // Do not call `collectionViewLayout?.invalidateLayout()` here: it schedules another layout
        // pass and this method runs again, causing constant churn (and can starve remote video).
        // `VideoCallCollectionView` already invalidates when its bounds size changes.
        if previewDetachedToOverlay,
           let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView {
            // Re-run full configure only if the preview was reparented (e.g. collection churn).
            // Calling `configureLocalPreviewIfNeeded` on every layout caused massive churn, recursion
            // warnings, and redundant `updateVideoConstraints` while the PiP was already correct.
            if localView.superview !== controllerView.localPreviewOverlay {
                scheduleConfigureLocalPreviewIfNeeded(animated: false)
            } else {
                controllerView.bringLocalPreviewOverlayToFront()
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
    
    // MARK: - Call UI layout (mirror iOS transition order; macOS adds window sizing via delegate)
    
    private func applyConnectingChrome(for currentCall: Call) {
        let controllerView = self.view as! ControllerView
        Task { @MainActor [weak self] in
            guard let self else { return }
            let localId = await self.session.localParticipantId(
                forCallConnectionId: currentCall.sharedCommunicationId
            )
            let override = self.remotePartyNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if !override.isEmpty {
                name = override
            } else {
                let resolved = currentCall.remoteDisplayName(localSecretName: localId)
                if !resolved.isEmpty {
                    name = resolved
                } else {
                    name = currentCall.recipients.first?.secretName
                        ?? currentCall.sender.secretName
                }
            }
            if controllerView.calleeLabel.stringValue.isEmpty || controllerView.calleeLabel.stringValue == currentCall.sender.secretName {
                controllerView.calleeLabel.stringValue = name
            }
            if let avatarData = self.remotePartyAvatarData {
                controllerView.voiceImageData = avatarData
            }
        }
        controllerView.statusLabel.stringValue = "Connecting secure video..."
        controllerView.statusLabel.fadeInOutLoop(duration: 1.5)
    }
    
    private func applyVoiceCallWindowLayout() async {
        let controllerView = self.view as! ControllerView
        await videoCallDelegate?.passSize(.init(width: 450, height: 100))
        logLayoutProbe("applyVoiceCallWindowLayout passSize=450x100 replaceRootSizing=450x100")
        controllerView.replaceCallRootSizingForVoiceCall(width: 450, height: 100)
    }
    
    /// Resizes the host window and pins the call root view for video (same as pre-refactor `.connecting` video).
    ///
    /// Always applies `passSize` + constraints when entering a video leg. A one-shot `guard` was
    /// skipping this when `upgradedToVideo` stayed true across flows/teardown, which left the UI at
    /// the initial 450×100 chrome and broke video layout/rendering.
    private func applyVideoCallWindowLayout() async {
        let controllerView = self.view as! ControllerView
        await videoCallDelegate?.passSize(.init(width: 335, height: 475))
        logLayoutProbe("applyVideoCallWindowLayout passSize=335x475 replaceRootSizing=min335x475 note=noDuplicateSelfEdgePins scrollViewAlreadyFillsBounds")
        controllerView.replaceCallRootSizingForVideoCall(minWidth: 335, minHeight: 475)
        upgradedToVideo = true
    }

    private func syncVoiceCallWindowForScreenShare(hasVisibleScreenShare: Bool) async {
        guard isRunning,
              let currentCall,
              !currentCall.supportsVideo,
              hasExpandedVoiceCallForScreenShare != hasVisibleScreenShare
        else { return }

        hasExpandedVoiceCallForScreenShare = hasVisibleScreenShare
        if RTCSession.shouldPresentVoiceOnlyCallChrome(
            callSupportsVideo: currentCall.supportsVideo,
            hasVisibleScreenShare: hasVisibleScreenShare
        ) {
            upgradedToVideo = false
            await applyVoiceCallWindowLayout()
        } else {
            await applyVideoCallWindowLayout()
        }
    }
    
    private func waitForMountedVideoView(_ view: NTMTKView) async {
        for _ in 0..<20 {
            if view.superview != nil,
               view.window != nil,
               view.bounds.width > 0,
               view.bounds.height > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        logger.log(
            level: .warning,
            message: "Timed out waiting for mounted video view context=\(view.contextName) superview=\(String(describing: view.superview)) window=\(String(describing: view.window)) bounds=\(view.bounds)"
        )
    }
    
    private func applySnapshotAsync(
        _ snapshot: NSDiffableDataSourceSnapshot<ConferenceCallSections, VideoViewModel>,
        animatingDifferences: Bool = false
    ) async {
        guard let dataSource else { return }
        isApplyingCollectionSnapshot = true
        await withCheckedContinuation { continuation in
            dataSource.apply(snapshot, animatingDifferences: animatingDifferences) {
                self.isApplyingCollectionSnapshot = false
                continuation.resume()
            }
        }
    }

    private func scheduleConfigureLocalPreviewIfNeeded(animated: Bool = true) {
        previewConfigurationNeedsAnimation = previewConfigurationNeedsAnimation || animated
        guard previewConfigurationScheduled == false else { return }
        previewConfigurationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewConfigurationScheduled = false
            let animate = self.previewConfigurationNeedsAnimation
            self.previewConfigurationNeedsAnimation = false
            guard self.isApplyingCollectionSnapshot == false else {
                self.scheduleConfigureLocalPreviewIfNeeded(animated: animate)
                return
            }
            self.configureLocalPreviewIfNeeded(animated: animate)
        }
    }
    
    private func configureLocalPreviewIfNeeded(animated: Bool = true) {
        guard isConfiguringLocalPreview == false else {
            scheduleConfigureLocalPreviewIfNeeded(animated: animated)
            return
        }
        isConfiguringLocalPreview = true
        defer { isConfiguringLocalPreview = false }
        guard let controllerView = self.view as? ControllerView else { return }
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        
        logger.log(
            level: .info,
            message: "configureLocalPreviewIfNeeded animated=\(animated) minimized=\(isPreviewMinimized) previewDetachedToOverlay=\(previewDetachedToOverlay) localFrame=\(localView.frame.size) tam=\(localView.translatesAutoresizingMaskIntoConstraints)"
        )
        // PiP configuration always targets the overlay; keep the detached flag in sync so collection
        // reconfigure passes cannot reparent the preview back into a cell with stale 160×90 constraints.
        previewDetachedToOverlay = true
        if detachedPreviewView == nil {
            detachedPreviewView = localView
        }
        controllerView.addConnectedLocalVideoView(view: localView)
        localView.setAccessibilityLabel("Local preview")

        func stripPreviewPanAndClick(from view: NSView) {
            for gr in view.gestureRecognizers where gr is NSPanGestureRecognizer || gr is NSClickGestureRecognizer {
                view.removeGestureRecognizer(gr)
            }
        }
        stripPreviewPanAndClick(from: localView)
        if let captureView = localView.captureView {
            stripPreviewPanAndClick(from: captureView)
        }
        for gr in controllerView.localPreviewOverlay.gestureRecognizers where gr is NSClickGestureRecognizer {
            controllerView.localPreviewOverlay.removeGestureRecognizer(gr)
        }
        if !controllerView.localPreviewOverlay.gestureRecognizers.contains(where: { $0 is NSPanGestureRecognizer }) {
            let panGesture = NSPanGestureRecognizer(target: self, action: #selector(dragPreviewView(_:)))
            controllerView.localPreviewOverlay.addGestureRecognizer(panGesture)
        }

        let host: LocalPreviewGestureHostView = {
            if let existing = localPreviewGestureHostView, existing.superview === localView {
                return existing
            }
            localPreviewGestureHostView?.removeFromSuperview()
            let h = LocalPreviewGestureHostView(frame: .zero)
            h.translatesAutoresizingMaskIntoConstraints = false
            localView.addSubview(h, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: localView.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: localView.trailingAnchor),
                h.topAnchor.constraint(equalTo: localView.topAnchor),
                h.bottomAnchor.constraint(equalTo: localView.bottomAnchor),
            ])
            localPreviewGestureHostView = h
            return h
        }()
        for gr in host.gestureRecognizers {
            host.removeGestureRecognizer(gr)
        }
        host.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragPreviewView(_:))))
        host.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapPreviewView(_:))))
        
        controllerView.updateLocalVideoSize(
            isConnected: true,
            view: localView,
            minimize: isPreviewMinimized,
            animated: animated
        )
        controllerView.bringLocalPreviewOverlayToFront()
    }
    
    /// Enables/disables Metal rendering for the local preview view.
    private func setRenderOnMetal(_ shouldRender: Bool) async {
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        if let renderer = localView.renderer as? PreviewViewRender {
            await renderer.setShouldRender(shouldRender)
        }
    }

    /// Connection id for mute/track APIs: prefer the VC’s `currentCall`, else session’s active id (covers UI/state races).
    private func resolvedMuteConnectionId() async -> String? {
        if let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw.normalizedConnectionId
        }
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

    /// Stops camera preview pipeline immediately when muting video (matches iOS).
    private func setLocalPreviewCapturing(isEnabled: Bool) async {
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
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
    
    private var blurEffectView: NSVisualEffectView?
    /// Polls remote track + frame age so peer camera-off matches iOS (paused / camera-off chrome).
    private var remoteVideoTrackPollTask: Task<Void, Never>?
    private var remoteCameraOffChrome: NSView?
    private var remotePoorVideoChrome: NSView?
    /// Hysteresis for render-frozen overlay (distinct from the app-level network quality banner).
    private var remoteVideoShowsFrozen = false
    private var participantFrozenHysteresisByKey: [String: Bool] = [:]
    private static let remoteVideoTileOverlayAccessibilityId = "RemoteVideoTileOverlay"
    /// Recovery rebind cooldown - avoid cryptor/renderer churn that can extend decode stalls.
    private static let remoteRendererRecoveryCooldownNs: UInt64 = 15_000_000_000

    private enum RemoteVideoTileOverlay: Equatable {
        case none
        case cameraOff
        /// Last decoded frame is stale - video picture frozen; unstable network uses the app call-quality banner.
        case renderFrozen
    }
    
    /// Adds or removes a blur overlay over the video views.
    ///
    /// Used on macOS to obscure video when muted (and to match the call UI styling).
    func blurView(_ shouldBlur: Bool) async {
        if shouldBlur {
            guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
            if blurEffectView == nil {
                blurEffectView = NSVisualEffectView()
                blurEffectView?.material = .sidebar
                blurEffectView?.blendingMode = .behindWindow
                blurEffectView?.state = .active
                blurEffectView?.autoresizingMask = [.width, .height]
            }
            guard let blurEffectView else { return }
            blurEffectView.removeFromSuperview()
            blurEffectView.frame = localView.bounds
            localView.addSubview(blurEffectView)
        } else {
            blurEffectView?.removeFromSuperview()
            blurEffectView = nil
        }
    }
    
    private func remoteVideoTileOverlay(
        trackEnabled: Bool,
        frameCallbackAgeMs: Int64,
        inboundFlowState: InboundVideoFlowState?,
        showsFrozen: inout Bool
    ) -> RemoteVideoTileOverlay {
        if !trackEnabled {
            showsFrozen = false
            return .cameraOff
        }
        let showFrozen = RemoteVideoRenderOverlayPolicy.shouldShowRenderFrozenOverlay(
            frameCallbackAgeMs: frameCallbackAgeMs,
            inboundFlowState: inboundFlowState,
            showsFrozen: &showsFrozen)
        return showFrozen ? .renderFrozen : .none
    }

    private func mainRemoteVideoTileOverlay(connectionId: String) async -> RemoteVideoTileOverlay {
        let trackEnabled = await session.inboundRemoteVideoTrackAppearsEnabled(connectionId: connectionId)
        guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView,
              let renderer = remoteView.renderer as? SampleBufferViewRenderer else {
            return trackEnabled ? .none : .cameraOff
        }
        let ageMs = await renderer.ageMillisecondsSinceLastVideoFrameCallback()
        let inboundFlowState = await session.cachedInboundRemoteVideoFlow(connectionId: connectionId)?.state
        return remoteVideoTileOverlay(
            trackEnabled: trackEnabled,
            frameCallbackAgeMs: ageMs,
            inboundFlowState: inboundFlowState,
            showsFrozen: &remoteVideoShowsFrozen)
    }

    private func participantRemoteVideoTileOverlay(
        connectionId: String,
        participantId: String,
        renderer: SampleBufferViewRenderer
    ) async -> RemoteVideoTileOverlay {
        let trackEnabled = await session.inboundRemoteParticipantVideoTrackAppearsEnabled(
            connectionId: connectionId,
            participantId: participantId)
        let ageMs = await renderer.ageMillisecondsSinceLastVideoFrameCallback()
        let key = participantRendererRecoveryKey(connectionId: connectionId, participantId: participantId)
        var showsFrozen = participantFrozenHysteresisByKey[key] ?? false
        let inboundFlowState = await session.cachedInboundRemoteVideoFlow(connectionId: connectionId)?.state
        let overlay = remoteVideoTileOverlay(
            trackEnabled: trackEnabled,
            frameCallbackAgeMs: ageMs,
            inboundFlowState: inboundFlowState,
            showsFrozen: &showsFrozen)
        participantFrozenHysteresisByKey[key] = showsFrozen
        return overlay
    }

    private func applyMainRemoteVideoTileOverlay(_ overlay: RemoteVideoTileOverlay) {
        guard let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        updateVideoTileOverlay(on: remoteView, overlay: overlay)
        remoteCameraOffChrome = overlay == .cameraOff
            ? remoteView.subviews.first(where: { $0.identifier?.rawValue == Self.remoteVideoTileOverlayAccessibilityId })
            : nil
        remotePoorVideoChrome = overlay == .renderFrozen
            ? remoteView.subviews.first(where: { $0.identifier?.rawValue == Self.remoteVideoTileOverlayAccessibilityId })
            : nil
    }

    private func pollParticipantVideoTileOverlays(
        connectionId: String,
        lastOverlays: inout [String: RemoteVideoTileOverlay]
    ) async {
        for model in videoViews.views.filter(isParticipantCameraModel) {
            guard let renderer = model.videoView.renderer as? SampleBufferViewRenderer else { continue }
            let overlay = await participantRemoteVideoTileOverlay(
                connectionId: connectionId,
                participantId: model.participantId,
                renderer: renderer)
            let key = participantRendererRecoveryKey(connectionId: connectionId, participantId: model.participantId)
            if lastOverlays[key] != overlay {
                lastOverlays[key] = overlay
                updateVideoTileOverlay(on: model.videoView, overlay: overlay)
            }
        }
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
        Task { [session] in
            await session.startInboundVideoFlowSamplerIfNeeded(connectionId: connectionId)
        }
        remoteVideoTrackPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastMainOverlay: RemoteVideoTileOverlay?
            var lastParticipantOverlays: [String: RemoteVideoTileOverlay] = [:]
            var lastInboundExpect: Bool?
            while !Task.isCancelled {
                guard self.isRunning else { break }
                if self.shouldUseParticipantCameraTiles() {
                    await self.pollParticipantVideoTileOverlays(
                        connectionId: connectionId,
                        lastOverlays: &lastParticipantOverlays)
                } else {
                    let overlay = await self.mainRemoteVideoTileOverlay(connectionId: connectionId)
                    if lastMainOverlay != overlay {
                        lastMainOverlay = overlay
                        self.applyMainRemoteVideoTileOverlay(overlay)
                    }
                    let expectInbound = await self.session.shouldExpectRemoteVideoCallbacksFromOtherParticipants(connectionId: connectionId)
                    if lastInboundExpect != expectInbound {
                        lastInboundExpect = expectInbound
                        await self.applyMainRemoteTileInboundExpectation(connectionId: connectionId)
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    
    private func stopRemoteVideoTrackPolling() {
        remoteVideoTrackPollTask?.cancel()
        remoteVideoTrackPollTask = nil
        if let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            Task { [session] in
                await session.stopInboundVideoFlowSampler(connectionId: raw)
            }
        }
        remoteVideoShowsFrozen = false
        participantFrozenHysteresisByKey.removeAll()
        remoteCameraOffChrome?.removeFromSuperview()
        remoteCameraOffChrome = nil
        remotePoorVideoChrome?.removeFromSuperview()
        remotePoorVideoChrome = nil
        for model in videoViews.views.filter(isParticipantCameraModel) {
            model.videoView.subviews
                .filter { $0.identifier?.rawValue == Self.remoteVideoTileOverlayAccessibilityId }
                .forEach { $0.removeFromSuperview() }
        }
    }

    private func updateVideoTileOverlay(on hostView: NTMTKView, overlay: RemoteVideoTileOverlay) {
        hostView.subviews
            .filter { $0.identifier?.rawValue == Self.remoteVideoTileOverlayAccessibilityId }
            .forEach { $0.removeFromSuperview() }
        guard overlay != .none else { return }

        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier(Self.remoteVideoTileOverlayAccessibilityId)
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        switch overlay {
        case .none:
            return
        case .cameraOff:
            container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
            icon.image = NSImage(systemSymbolName: "video.slash.fill", accessibilityDescription: "Camera off")
            icon.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        case .renderFrozen:
            container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            icon.image = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Video frozen")
            icon.contentTintColor = NSColor.white.withAlphaComponent(0.88)
        }

        container.addSubview(blur)
        container.addSubview(icon)
        hostView.addSubview(container)

        let iconSize: CGFloat = overlay == .cameraOff ? 56 : 44
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: hostView.topAnchor),
            container.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            container.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            container.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
        ])
    }
    
    private func tearDownCall() async {
        guard isRunning == true else {
            return
        }
        // Prevent concurrent teardown from running more than once
        isRunning = false
        await session.releaseLocalMediaResourcesForCallEnding(call: currentCall)
        removeWindowCloseObserver()
        
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
        screenTrackStreamTask?.cancel()
        screenTrackStreamTask = nil
        stopRemoteScreenShareAttachRetry()
        stopLocalScreenShareAttachRetry()
        localScreenShareStateTask?.cancel()
        localScreenShareStateTask = nil
        await tearDownLocalScreenView()
        for model in videoViews.views where isScreenShareModel(model) {
            await tearDownScreenView(participantId: model.participantId)
        }
        stopAllScreenShareRendererRecovery()
        hasActiveLocalScreenShare = false
        hasActiveRemoteScreenShare = false
        hasVisibleScreenShareInCollection = false
        activeRemoteScreenShareParticipantId = nil
        participantTrackStreamTask?.cancel()
        participantTrackStreamTask = nil
        await tearDownAllParticipantCameraViews()
        await tearDownPreviewView()
        await tearDownSampleView()
        let videoView = self.view as! ControllerView
        blurEffectView?.removeFromSuperview()
        blurEffectView = nil
        videoView.tearDownView()
        await session.shutdown(with: currentCall)
        previewDetachedToOverlay = false
        detachedPreviewView = nil
        upgradedToVideo = false
        isPreviewMinimized = false
        loadedPreviewItem = false
        videoViews.removeAllViews()
        deleteSnap()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        dataSource = nil
        self.currentCall = nil
        await videoCallDelegate?.endedCall(true)
        videoCallDelegate = nil
    }
    
    /// Creates and starts the local preview Metal view.
    ///
    /// - Parameter shouldQuery: If `true`, triggers a diffable-data-source refresh so the view is
    ///   inserted into the collection view before rendering begins.
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
        videoViews.addView(.init(videoView: localVideoView))
        if shouldQuery {
            await performQuery()
            await waitForMountedVideoView(localVideoView)
        }
        await localVideoView.startRendering()
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        guard let previewRenderer = localVideoView.renderer as? PreviewViewRender else { return }
        
        await session.bindLocalPreviewCaptureRenderer(previewRenderer, connectionId: connectionId)
        await self.session.renderLocalVideo(to: previewRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        await applyCurrentLocalVideoMuteState(connectionId: connectionId)
        await applyLocalVideoMirroringFromUserDefaults()
    }

    private func applyLocalVideoMirroringFromUserDefaults() async {
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView,
              let renderer = localView.renderer as? PreviewViewRender else { return }
        await renderer.applyLocalVideoMirroringFromUserDefaults()
    }

    private func applyPreferredVideoCaptureDeviceFromUserDefaults() async {
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView,
              let renderer = localView.renderer as? PreviewViewRender else { return }
        await renderer.applyPreferredVideoCaptureDeviceFromUserDefaults()
    }
    
    /// Creates and starts the remote sample (receive) Metal view.
    ///
    /// - Parameter wasAudioCall: Currently unused; retained for call-type transitions.
    func createSampleView(wasAudioCall: Bool = false) async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if shouldUseParticipantCameraTiles() {
            if let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView {
                detachedPreviewView = localView
                previewDetachedToOverlay = true
                scheduleConfigureLocalPreviewIfNeeded(animated: false)
            }
            await assignExistingParticipantTracks(connectionId: connectionId)
            await performQuery(removePreview: true)
            scheduleConfigureLocalPreviewIfNeeded(animated: false)
            await applyCurrentLocalVideoMuteState(connectionId: connectionId)
            startRemoteVideoTrackPolling()
            return
        }

        // Idempotency: avoid creating duplicate remote renderers if call-state re-emits `.connected`.
        if videoViews.views.contains(where: { $0.videoView.contextName == "sample" }) {
            scheduleConfigureLocalPreviewIfNeeded()
            if let remoteView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView,
               let remoteRenderer = remoteView.renderer as? SampleBufferViewRenderer {
                remoteView.setPrefersAspectFit(true)
                await remoteRenderer.setPrefersAspectFit(true)
                await applyMainRemoteTileInboundExpectation(connectionId: connectionId)
                startRemoteRendererRecoveryIfNeeded(renderer: remoteRenderer, connectionId: connectionId)
            }
            startRemoteVideoTrackPolling()
            return
        }
        
        guard let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else {
            logger.log(level: .error, message: "createSampleView: no preview view; cannot show local PiP")
            return
        }
        
        let remoteVideoView: NTMTKView
        do {
            remoteVideoView = try NTMTKView(type: .sample, contextName: "sample")
        } catch {
            logger.log(level: .error, message: "Failed to create sample view: \(error)")
            return
        }
        remoteVideoView.setPrefersAspectFit(true)
        
        // Move local PiP into the overlay *before* the diffable snapshot drops its collection item.
        // Otherwise AppKit can tear the preview out of the hierarchy and it never reappears.
        detachedPreviewView = localView
        previewDetachedToOverlay = true
        scheduleConfigureLocalPreviewIfNeeded(animated: false)
        
        videoViews.addView(.init(videoView: remoteVideoView))
        await performQuery(removePreview: true)
        await waitForMountedVideoView(remoteVideoView)
        logger.log(level: .info, message: "Remote view mounted: bounds=\(remoteVideoView.bounds)")
        
        await remoteVideoView.startRendering()
        // Production macOS path: keep the remote tile on Metal. The sample-buffer fallback has
        // been prone to freezing after a short period even while RTP stats continue updating.
        remoteVideoView.shouldRenderOnMetal = true
        guard let remoteRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        await remoteRenderer.setPrefersAspectFit(true)
        logger.log(level: .info, message: "Attaching remote renderer for connectionId=\(connectionId)")
        await self.session.renderRemoteVideo(
            to: remoteRenderer.rtcVideoRenderWrapper,
            with: connectionId)
        await applyCurrentLocalVideoMuteState(connectionId: connectionId)
        await applyMainRemoteTileInboundExpectation(connectionId: connectionId)
        startRemoteRendererRecoveryIfNeeded(renderer: remoteRenderer, connectionId: connectionId)
        startRemoteVideoTrackPolling()
        scheduleConfigureLocalPreviewIfNeeded()
    }
    
    /// Stops capture and removes the local preview renderer from the session.
    func tearDownPreviewView() async {
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        guard let localVideoRenderer = localView.renderer as? PreviewViewRender else { return }
        await localVideoRenderer.stopCaptureSession()
        await localVideoRenderer.setCapture(nil)
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.removeLocal(renderer: localVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        localView.shutdownMetalStream()
        detachedPreviewView = nil
        previewDetachedToOverlay = false
    }
    
    /// Shuts down the remote renderer and removes it from the session.
    func tearDownSampleView() async {
        if shouldUseParticipantCameraTiles() {
            await tearDownAllParticipantCameraViews()
            return
        }
        stopRemoteVideoTrackPolling()
        guard let remoteVideoView = videoViews.views.first(where: { $0.videoView.contextName == "sample" })?.videoView else { return }
        guard let remoteVideoRenderer = remoteVideoView.renderer as? SampleBufferViewRenderer else { return }
        stopRemoteRendererRecovery()
        await remoteVideoRenderer.setRemoteVideoInboundExpected(false)
        await remoteVideoRenderer.shutdown()
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await self.session.setVideoTrack(isEnabled: false, connectionId: connectionId)
        await session.removeRemote(renderer: remoteVideoRenderer.rtcVideoRenderWrapper, connectionId: connectionId)
        remoteVideoView.shutdownMetalStream()
    }

    private func shouldUseParticipantCameraTiles() -> Bool {
        guard let call = currentCall else { return false }
        if RTCSession.isTrueOneToOneSfuRoom(call: call) {
            return false
        }
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

    private func isRemoteScreenShareModel(_ model: VideoViewModel) -> Bool {
        guard isScreenShareModel(model) else { return false }
        if let localId = localScreenShareTileParticipantId,
           !localId.isEmpty,
           RTCSession.remoteScreenShareParticipantMatches(localId, model.participantId) {
            return false
        }
        return true
    }

    private func canPresentRemoteScreenShareUI(for rawParticipantId: String) -> Bool {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantId.isEmpty else { return false }
        if !shouldUseParticipantCameraTiles() {
            return true
        }
        return shouldCreateParticipantCameraTile(participantId: participantId)
    }

    private func screenShareModel(matching rawParticipantId: String, allowSingleFallback: Bool) -> VideoViewModel? {
        let matches = screenShareModels(matching: rawParticipantId)
        if let exact = matches.first(where: { $0.videoView.contextName == "screen_\(rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines))" }) {
            return exact
        }
        if let normalized = matches.first {
            return normalized
        }
        if allowSingleFallback, videoViews.views.filter(isRemoteScreenShareModel).count == 1 {
            return videoViews.views.first(where: isRemoteScreenShareModel)
        }
        return nil
    }

    private func screenShareModels(matching rawParticipantId: String) -> [VideoViewModel] {
        let participantId = rawParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantId.isEmpty else { return [] }
        let contextName = "screen_\(participantId)"
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        return videoViews.views.filter { model in
            guard isScreenShareModel(model) else { return false }
            if model.videoView.contextName == contextName { return true }
            guard !participantKey.isEmpty else { return false }
            return RTCSession.conferenceParticipantIdentityKey(model.participantId) == participantKey
        }
    }

    private func isOneToOneRemoteCameraModel(_ model: VideoViewModel) -> Bool {
        !model.isScreenShare && model.videoView.contextName == "sample"
    }

    private func mainCollectionView() -> VideoCallCollectionView? {
        (view as? ControllerView)?.scrollView.documentView as? VideoCallCollectionView
    }

    /// Re-applies aspect-fit and renderer bounds on remote camera tiles after screen-share layout churn.
    private func syncParticipantCameraTileAspectModes() async {
        for model in videoViews.views where isParticipantCameraModel(model) || isOneToOneRemoteCameraModel(model) {
            model.videoView.setPrefersAspectFit(true)
            guard let renderer = model.videoView.renderer as? SampleBufferViewRenderer else { continue }
            await renderer.setPrefersAspectFit(true)
            let bounds = effectiveBoundsForMountedVideoView(model.videoView)
            if bounds.width > 0, bounds.height > 0 {
                await renderer.applyHostViewBounds(bounds)
            }
        }
    }

    /// Falls back to collection item bounds when `NTMTKView.bounds` is still stale after layout.
    private func effectiveBoundsForMountedVideoView(_ view: NTMTKView) -> CGRect {
        if view.bounds.width > 1, view.bounds.height > 1 {
            return view.bounds
        }
        guard let collectionView = mainCollectionView() else { return view.bounds }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: indexPath) as? VideoItem,
                  item.view.subviews.contains(where: { $0 === view }) else {
                continue
            }
            let contentBounds = item.view.bounds
            if contentBounds.width > 1, contentBounds.height > 1 {
                return contentBounds
            }
            if let attributes = collectionView.layoutAttributesForItem(at: indexPath),
               attributes.size.width > 1,
               attributes.size.height > 1 {
                return CGRect(origin: .zero, size: attributes.size)
            }
        }
        return view.bounds
    }

    private func refreshMountedVideoRendererBounds() async {
        for model in videoViews.views {
            let view = model.videoView
            let bounds = effectiveBoundsForMountedVideoView(view)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            if let renderer = view.renderer as? SampleBufferViewRenderer {
                await renderer.applyHostViewBounds(bounds)
            }
        }
    }

    private func configureVideoItemCell(_ item: VideoItem, model: VideoViewModel) {
        let isPreview = model.videoView.contextName == "preview"
        if isPreview {
            if previewDetachedToOverlay {
                loadedPreviewItem = true
                return
            }
            if let controllerView = view as? ControllerView,
               model.videoView.superview === controllerView.localPreviewOverlay {
                loadedPreviewItem = true
                return
            }
        }
        let controllerView = view as? ControllerView
        controllerView?.prepareVideoViewForCollectionCellLayout(model.videoView, hostView: item.view)
        for subview in item.view.subviews where subview !== model.videoView {
            subview.removeFromSuperview()
        }
        let didReparentVideoView = model.videoView.superview !== item.view
        if model.videoView.superview !== item.view {
            model.videoView.removeFromSuperview()
            item.view.addSubview(model.videoView)
        }
        let isScreenShare = model.isScreenShare || model.videoView.contextName.hasPrefix("screen_")
        let cornerRadius: CGFloat = isScreenShare ? 16 : 12
        item.view.wantsLayer = true
        item.view.layer?.cornerRadius = cornerRadius
        item.view.layer?.masksToBounds = true
        item.view.layer?.borderWidth = isScreenShare ? 1 : 0.75
        item.view.layer?.borderColor = NSColor.white.withAlphaComponent(isScreenShare ? 0.18 : 0.12).cgColor
        model.videoView.wantsLayer = true
        model.videoView.layer?.cornerRadius = cornerRadius
        model.videoView.layer?.masksToBounds = true
        model.videoView.anchors(
            top: item.view.topAnchor,
            leading: item.view.leadingAnchor,
            bottom: item.view.bottomAnchor,
            trailing: item.view.trailingAnchor)
        model.videoView.layoutSubtreeIfNeeded()
        if isParticipantCameraModel(model) || isOneToOneRemoteCameraModel(model) {
            model.videoView.setPrefersAspectFit(true)
            if let renderer = model.videoView.renderer as? SampleBufferViewRenderer {
                Task { await renderer.setPrefersAspectFit(true) }
            }
        }
        if isScreenShare {
            addPresenterBadge(to: model.videoView)
        }
        if didReparentVideoView || item.view.bounds.width < 1 || item.view.bounds.height < 1 {
            logLayoutProbe("cellConfigure context=\(model.videoView.contextName) itemBounds=\(Int(item.view.bounds.width))x\(Int(item.view.bounds.height)) videoBounds=\(Int(model.videoView.bounds.width))x\(Int(model.videoView.bounds.height)) reparented=\(didReparentVideoView) previewDetached=\(previewDetachedToOverlay)")
        }
        loadedPreviewItem = true
    }

    private func reconfigureVisibleVideoCells() {
        guard let collectionView = mainCollectionView() else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let model = dataSource?.itemIdentifier(for: indexPath),
                  let item = collectionView.item(at: indexPath) as? VideoItem else {
                continue
            }
            if model.videoView.contextName == "preview" {
                if previewDetachedToOverlay {
                    continue
                }
                if let controllerView = view as? ControllerView,
                   model.videoView.superview === controllerView.localPreviewOverlay {
                    continue
                }
            }
            configureVideoItemCell(item, model: model)
        }
    }

    /// Clears stale aspect-fit state and re-syncs bounds on camera tiles after screen share ends.
    ///
    /// Does not clear the last Metal frame — ``SampleBufferViewRenderer/applyHostViewBounds(_:)`` re-rasterizes
    /// at the new size when layout expands, avoiding a visible blank snap before the next WebRTC callback.
    private func healParticipantCameraTilesAfterScreenShareEnd() async {
        await syncParticipantCameraTileAspectModes()
        for model in videoViews.views where isParticipantCameraModel(model) || isOneToOneRemoteCameraModel(model) {
            guard let renderer = model.videoView.renderer as? SampleBufferViewRenderer else { continue }
            let bounds = effectiveBoundsForMountedVideoView(model.videoView)
            if bounds.width > 0, bounds.height > 0 {
                await renderer.applyHostViewBounds(bounds)
            }
        }
    }

    /// Re-attaches live remote camera sinks after screen-share layout teardown (mirrors iOS).
    private func rebindRemoteCameraRenderersAfterScreenShareEnd() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if shouldUseParticipantCameraTiles() {
            await assignExistingParticipantTracks(connectionId: connectionId)
            return
        }

        guard let remoteRenderer = videoViews.views
            .first(where: isOneToOneRemoteCameraModel)?
            .videoView
            .renderer as? SampleBufferViewRenderer else {
            return
        }
        await remoteRenderer.startStream()
        await session.renderRemoteVideo(to: remoteRenderer.rtcVideoRenderWrapper, with: connectionId)
        await applyMainRemoteTileInboundExpectation(connectionId: connectionId)
    }

    /// After screen share ends, camera tiles can keep strip-sized bounds until the next layout pass.
    private func schedulePostScreenShareLayoutHeal() {
        postScreenShareLayoutHealTask?.cancel()
        postScreenShareLayoutHealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isRunning, !self.hasVisibleScreenShareInCollection else { return }
            guard let collectionView = self.mainCollectionView() else { return }
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            self.reconfigureVisibleVideoCells()
            await self.syncParticipantCameraTileAspectModes()
            await self.refreshMountedVideoRendererBounds()

            await Task.yield()
            guard !Task.isCancelled, self.isRunning, !self.hasVisibleScreenShareInCollection else { return }
            collectionView.layoutSubtreeIfNeeded()
            self.reconfigureVisibleVideoCells()
            await self.healParticipantCameraTilesAfterScreenShareEnd()
        }
    }

    private func scheduleScreenShareLayoutTransitionHeal(expectingScreenShareVisible: Bool? = nil) {
        if expectingScreenShareVisible == false {
            schedulePostScreenShareLayoutHeal()
            return
        }
        postScreenShareLayoutHealTask?.cancel()
        postScreenShareLayoutHealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isRunning else { return }
            if let expectingScreenShareVisible,
               self.hasVisibleScreenShareInCollection != expectingScreenShareVisible {
                return
            }
            guard let collectionView = self.mainCollectionView() else { return }
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            self.reconfigureVisibleVideoCells()
            await self.syncParticipantCameraTileAspectModes()
            await self.refreshMountedVideoRendererBounds()

            await Task.yield()
            guard !Task.isCancelled, self.isRunning else { return }
            if let expectingScreenShareVisible,
               self.hasVisibleScreenShareInCollection != expectingScreenShareVisible {
                return
            }
            collectionView.layoutSubtreeIfNeeded()
            self.reconfigureVisibleVideoCells()
            await self.refreshMountedVideoRendererBounds()
        }
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
            if let existingView = videoViews.views.first(where: { $0.videoView.contextName == contextName })?.videoView,
               let existingRenderer = existingView.renderer as? SampleBufferViewRenderer {
                existingView.setPrefersAspectFit(true)
                await existingRenderer.setPrefersAspectFit(true)
                let didAttach = await session.renderRemoteVideoForParticipant(
                    to: existingRenderer.rtcVideoRenderWrapper,
                    connectionId: connectionId,
                    participantId: participantId
                )
                if didAttach {
                    await existingRenderer.setRemoteVideoInboundExpected(true)
                }
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

        if let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView {
            detachedPreviewView = localView
            previewDetachedToOverlay = true
            scheduleConfigureLocalPreviewIfNeeded(animated: false)
        }

        let model = VideoViewModel(
            videoView: cameraView,
            participantId: participantId,
            connectionId: connectionId,
            isScreenShare: false
        )
        videoViews.addView(model)
        await performQuery(removePreview: previewDetachedToOverlay)
        await waitForMountedVideoView(cameraView)

        await cameraView.startRendering()
        cameraView.shouldRenderOnMetal = true
        guard let cameraRenderer = cameraView.renderer as? SampleBufferViewRenderer else {
            videoViews.removeView(model)
            await performQuery(removePreview: previewDetachedToOverlay)
            logger.log(level: .error, message: "Participant camera renderer unavailable, removing orphan tile for participant=\(participantId)")
            return
        }
        cameraView.setPrefersAspectFit(true)
        await cameraRenderer.setPrefersAspectFit(true)

        let didAttach = await session.renderRemoteVideoForParticipant(
            to: cameraRenderer.rtcVideoRenderWrapper,
            connectionId: connectionId,
            participantId: participantId
        )
        if didAttach {
            await cameraRenderer.setRemoteVideoInboundExpected(true)
            startParticipantRendererRecoveryIfNeeded(
                renderer: cameraRenderer,
                connectionId: connectionId,
                participantId: participantId
            )
            applyConferenceRaisedHandIndicators()
            logger.log(level: .info, message: "Remote participant camera view created for participant=\(participantId)")
            return
        }

        await cameraRenderer.setRemoteVideoInboundExpected(true)
        startParticipantRendererRecoveryIfNeeded(
            renderer: cameraRenderer,
            connectionId: connectionId,
            participantId: participantId
        )
        applyConferenceRaisedHandIndicators()
        logger.log(
            level: .warning,
            message: "Participant camera tile waiting for track; keeping placeholder and retrying attach for participant=\(participantId)"
        )
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
        videoViews.removeView(model)
        await performQuery(removePreview: previewDetachedToOverlay)
        logger.log(level: .info, message: "Remote participant camera view removed for participant=\(model.participantId) requestedParticipant=\(participantId)")
    }

    private func tearDownAllParticipantCameraViews() async {
        stopRemoteVideoTrackPolling()
        let cameraModels = videoViews.views.filter(isParticipantCameraModel)
        for model in cameraModels {
            await tearDownParticipantCameraView(
                connectionId: model.connectionId,
                participantId: model.participantId
            )
        }
        stopAllParticipantRendererRecovery()
    }

    private func createLocalScreenView() async {
        guard hasActiveLocalScreenShare else { return }
        guard let connectionId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "createLocalScreenView: missing active connection id")
            startLocalScreenShareAttachRetry()
            return
        }
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await session.connectionManager.findConnection(with: normalizedId) else {
            logger.log(level: .warning, message: "createLocalScreenView: connection not found for \(connectionId)")
            startLocalScreenShareAttachRetry()
            return
        }
        guard connection.localScreenTrack != nil else {
            logger.log(level: .warning, message: "createLocalScreenView: local screen track not ready for \(connectionId)")
            startLocalScreenShareAttachRetry()
            return
        }

        stopLocalScreenShareAttachRetry()

        let rawParticipantId = connection.localParticipantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let participantId = rawParticipantId.isEmpty ? "local" : rawParticipantId
        localScreenShareTileParticipantId = participantId
        let contextName = "screen_\(participantId)"
        if screenShareModel(matching: participantId, allowSingleFallback: false) != nil {
            await promoteLocalScreenSharePresentationLayout()
            return
        }

        if let localView = videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView {
            detachedPreviewView = localView
            previewDetachedToOverlay = true
            scheduleConfigureLocalPreviewIfNeeded(animated: false)
        }

        let screenView: NTMTKView
        do {
            screenView = try NTMTKView(type: .sample, contextName: contextName)
        } catch {
            logger.log(level: .error, message: "Failed to create local screen share view: \(error)")
            return
        }

        let model = VideoViewModel(videoView: screenView, participantId: participantId, connectionId: normalizedId)
        videoViews.views.insert(model, at: 0)
        await promoteLocalScreenSharePresentationLayout()
        await waitForMountedVideoView(screenView)
        await refreshMountedVideoRendererBounds()

        await screenView.startRendering()
        screenView.shouldRenderOnMetal = true
        guard let screenRenderer = screenView.renderer as? SampleBufferViewRenderer else {
            videoViews.removeView(model)
            localScreenShareTileParticipantId = nil
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
            hasVisibleScreenShareInCollection = videoViews.views.contains(where: isScreenShareModel)
            await performQuery(removePreview: previewDetachedToOverlay)
            logger.log(level: .error, message: "Local screen share renderer unavailable, removing orphan tile")
            return
        }

        let didAttach = await session.renderLocalScreenVideo(
            to: screenRenderer.rtcVideoRenderWrapper,
            connectionId: normalizedId
        )
        guard didAttach else {
            await screenRenderer.setRemoteVideoInboundExpected(false)
            await screenRenderer.shutdown()
            screenView.shutdownMetalStream()
            videoViews.removeView(model)
            localScreenShareTileParticipantId = nil
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
            hasVisibleScreenShareInCollection = videoViews.views.contains(where: isScreenShareModel)
            await performQuery(removePreview: previewDetachedToOverlay)
            logger.log(level: .warning, message: "Local screen share tile removed because no local screen track was available")
            startLocalScreenShareAttachRetry()
            return
        }

        await screenRenderer.setRemoteVideoInboundExpected(false)
        addPresenterBadge(to: screenView)
        logger.log(level: .info, message: "Local screen share view created for participant=\(participantId)")
    }

    /// Re-applies the screen-share dominant collection layout and keeps local PiP in the overlay.
    private func promoteLocalScreenSharePresentationLayout() async {
        await performQuery(removePreview: true)
        scheduleConfigureLocalPreviewIfNeeded(animated: false)
        await syncParticipantCameraTileAspectModes()
        if let collectionView = mainCollectionView() {
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
        }
        reconfigureVisibleVideoCells()
        await refreshMountedVideoRendererBounds()
        scheduleScreenShareLayoutTransitionHeal(expectingScreenShareVisible: true)
    }

    private func startLocalScreenShareAttachRetry() {
        guard hasActiveLocalScreenShare else { return }
        localScreenShareAttachRetryTask?.cancel()
        localScreenShareAttachRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<40 {
                guard !Task.isCancelled else { return }
                guard self.hasActiveLocalScreenShare else { return }
                if self.screenShareModel(
                    matching: self.localScreenShareTileParticipantId ?? "",
                    allowSingleFallback: false
                ) != nil {
                    await self.promoteLocalScreenSharePresentationLayout()
                    return
                }
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await self.createLocalScreenView()
            }
            self.logger.log(level: .warning, message: "Timed out waiting to attach local screen share tile")
        }
    }

    private func stopLocalScreenShareAttachRetry() {
        localScreenShareAttachRetryTask?.cancel()
        localScreenShareAttachRetryTask = nil
    }

    private func tearDownLocalScreenView() async {
        stopLocalScreenShareAttachRetry()
        guard let participantId = localScreenShareTileParticipantId else {
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
            await performQuery(removePreview: previewDetachedToOverlay)
            return
        }
        guard let model = screenShareModel(matching: participantId, allowSingleFallback: false) else {
            localScreenShareTileParticipantId = nil
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
            await performQuery(removePreview: previewDetachedToOverlay)
            return
        }

        let screenView = model.videoView
        if let screenRenderer = screenView.renderer as? SampleBufferViewRenderer {
            await screenRenderer.setRemoteVideoInboundExpected(false)
            if !model.connectionId.isEmpty {
                await session.removeLocalScreenVideoRenderer(
                    screenRenderer.rtcVideoRenderWrapper,
                    connectionId: model.connectionId
                )
            }
            await screenRenderer.shutdown()
        }
        screenView.shutdownMetalStream()
        videoViews.removeView(model)
        localScreenShareTileParticipantId = nil
        hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
        await performQuery(removePreview: previewDetachedToOverlay)
        logger.log(level: .info, message: "Local screen share view removed for participant=\(model.participantId)")
    }

    /// Ends every remote screen-share tile except the participant who is taking over.
    private func tearDownRemoteScreenShares(exceptParticipantId activeParticipantId: String) async {
        let activeKey = RTCSession.conferenceParticipantIdentityKey(activeParticipantId)
        for model in videoViews.views.filter(isRemoteScreenShareModel) {
            let modelKey = RTCSession.conferenceParticipantIdentityKey(model.participantId)
            guard modelKey != activeKey else { continue }
            await tearDownScreenView(participantId: model.participantId)
        }
    }

    private func reconcileRemoteScreenShareAfterParticipantCameraEvent(
        connectionId: String,
        participantId: String
    ) async {
        guard hasActiveRemoteScreenShare || videoViews.views.contains(where: isRemoteScreenShareModel) else {
            return
        }
        guard RTCSession.shouldAcceptRemoteScreenShareEnd(
            activeParticipantId: activeRemoteScreenShareParticipantId,
            endedParticipantId: participantId
        ) else {
            return
        }
        let screenParticipantId = activeRemoteScreenShareParticipantId ?? participantId
        let screenTrackStillMapped = await session.hasMappedRemoteScreenTrack(
            connectionId: connectionId,
            participantId: screenParticipantId
        )
        guard !screenTrackStillMapped else {
            return
        }
        logger.log(
            level: .info,
            message: "Clearing stale remote screen-share UI after participant camera restored participant=\(participantId)"
        )
        await tearDownScreenView(participantId: participantId)
    }

    /// Creates and renders a remote screen-share tile, promoting it to the dominant position.
    func createScreenView(connectionId: String, participantId: String) async {
        activeRemoteScreenShareParticipantId = participantId
        await syncParticipantCameraTileAspectModes()
        await tearDownRemoteScreenShares(exceptParticipantId: participantId)
        let contextName = "screen_\(participantId)"
        if let existing = screenShareModel(matching: participantId, allowSingleFallback: false) {
            if await refreshScreenView(existing, connectionId: connectionId, participantId: participantId) {
                return
            }
            await tearDownScreenView(participantId: participantId)
        }

        guard await session.hasMappedRemoteScreenTrack(
            connectionId: connectionId,
            participantId: participantId
        ) else {
            startRemoteScreenShareAttachRetry(connectionId: connectionId, participantId: participantId)
            logger.log(
                level: .info,
                message: "Deferring screen share tile until track mapping exists for participant=\(participantId)"
            )
            return
        }

        let screenView: NTMTKView
        do {
            screenView = try NTMTKView(type: .sample, contextName: contextName)
        } catch {
            if RTCSession.remoteScreenShareParticipantMatches(activeRemoteScreenShareParticipantId, participantId) {
                activeRemoteScreenShareParticipantId = nil
            }
            logger.log(level: .error, message: "Failed to create screen share view: \(error)")
            return
        }

        let model = VideoViewModel(videoView: screenView, participantId: participantId, connectionId: connectionId)
        videoViews.views.insert(model, at: 0)
        await performQuery(removePreview: previewDetachedToOverlay)
        await waitForMountedVideoView(screenView)
        await refreshMountedVideoRendererBounds()

        await screenView.startRendering()
        screenView.shouldRenderOnMetal = true
        guard let screenRenderer = screenView.renderer as? SampleBufferViewRenderer else {
            videoViews.views.removeAll(where: { $0.videoView.contextName == contextName })
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
            if RTCSession.remoteScreenShareParticipantMatches(activeRemoteScreenShareParticipantId, participantId) {
                activeRemoteScreenShareParticipantId = nil
            }
            await performQuery(removePreview: previewDetachedToOverlay)
            logger.log(level: .error, message: "Screen share renderer unavailable, removing orphan tile for participant=\(participantId)")
            return
        }
        let didAttach = await session.renderRemoteScreenVideo(
            to: screenRenderer.rtcVideoRenderWrapper,
            connectionId: connectionId,
            participantId: participantId)
        guard didAttach else {
            await screenRenderer.setRemoteVideoInboundExpected(false)
            await screenRenderer.shutdown()
            screenView.shutdownMetalStream()
            videoViews.removeView(model)
            hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
            await performQuery(removePreview: previewDetachedToOverlay)
            startRemoteScreenShareAttachRetry(connectionId: connectionId, participantId: participantId)
            logger.log(level: .warning, message: "Screen share tile removed because no screen track was available for participant=\(participantId)")
            return
        }
        stopRemoteScreenShareAttachRetry()
        await screenRenderer.setRemoteVideoInboundExpected(true)
        startRemoteScreenShareRendererRecoveryIfNeeded(
            renderer: screenRenderer,
            connectionId: connectionId,
            participantId: participantId
        )
        addPresenterBadge(to: screenView)
        hasActiveRemoteScreenShare = true
        activeRemoteScreenShareParticipantId = participantId
        await syncParticipantCameraTileAspectModes()
        scheduleScreenShareLayoutTransitionHeal(expectingScreenShareVisible: true)

        await videoCallDelegate?.remoteScreenShareDidChange(
            participantId: participantId,
            isSharing: hasActiveRemoteScreenShare)
        logger.log(level: .info, message: "Remote screen share view created for participant=\(participantId)")
    }

    @discardableResult
    private func refreshScreenView(_ model: VideoViewModel, connectionId: String, participantId: String) async -> Bool {
        activeRemoteScreenShareParticipantId = participantId
        let screenView = model.videoView
        if screenView.renderer == nil {
            await screenView.startRendering()
            screenView.shouldRenderOnMetal = true
        }
        await waitForMountedVideoView(screenView)
        await refreshMountedVideoRendererBounds()
        guard let screenRenderer = screenView.renderer as? SampleBufferViewRenderer else {
            if RTCSession.remoteScreenShareParticipantMatches(activeRemoteScreenShareParticipantId, participantId) {
                activeRemoteScreenShareParticipantId = nil
            }
            logger.log(level: .warning, message: "Screen share refresh skipped: renderer unavailable for participant=\(participantId)")
            return false
        }
        let didAttach = await session.renderRemoteScreenVideo(
            to: screenRenderer.rtcVideoRenderWrapper,
            connectionId: connectionId,
            participantId: participantId)
        guard didAttach else {
            startRemoteScreenShareAttachRetry(connectionId: connectionId, participantId: participantId)
            logger.log(level: .warning, message: "Screen share refresh could not attach track for participant=\(participantId)")
            return false
        }
        stopRemoteScreenShareAttachRetry()
        await screenRenderer.setRemoteVideoInboundExpected(true)
        startRemoteScreenShareRendererRecoveryIfNeeded(
            renderer: screenRenderer,
            connectionId: connectionId,
            participantId: participantId
        )
        addPresenterBadge(to: screenView)
        hasActiveRemoteScreenShare = true
        await performQuery(removePreview: previewDetachedToOverlay)
        await refreshMountedVideoRendererBounds()
        await videoCallDelegate?.remoteScreenShareDidChange(
            participantId: participantId,
            isSharing: hasActiveRemoteScreenShare)
        logger.log(level: .info, message: "Remote screen share view refreshed for participant=\(participantId)")
        return true
    }

    private func stopRemoteScreenShareAttachRetry() {
        remoteScreenShareAttachRetryTask?.cancel()
        remoteScreenShareAttachRetryTask = nil
        remoteScreenShareAttachRetryKey = nil
    }

    private func isRemoteScreenShareAttachRetryPending(for participantId: String) -> Bool {
        guard let retryKey = remoteScreenShareAttachRetryKey,
              let task = remoteScreenShareAttachRetryTask,
              !task.isCancelled else {
            return false
        }
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        return retryKey.hasSuffix("|\(participantKey)")
            && RTCSession.remoteScreenShareParticipantMatches(activeRemoteScreenShareParticipantId, participantId)
    }

    private func startRemoteScreenShareAttachRetry(connectionId: String, participantId: String) {
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        let retryKey = "\(connectionId.normalizedConnectionId)|\(participantKey)"
        if remoteScreenShareAttachRetryKey == retryKey, remoteScreenShareAttachRetryTask != nil {
            return
        }
        stopRemoteScreenShareAttachRetry()
        remoteScreenShareAttachRetryKey = retryKey
        remoteScreenShareAttachRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled, attempts < 40 {
                attempts += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                guard RTCSession.remoteScreenShareParticipantMatches(
                    self.activeRemoteScreenShareParticipantId,
                    participantId
                ) else { return }
                guard await self.session.hasMappedRemoteScreenTrack(
                    connectionId: connectionId,
                    participantId: participantId
                ) else { continue }

                await self.createScreenView(connectionId: connectionId, participantId: participantId)
                if self.hasActiveRemoteScreenShare,
                   self.screenShareModel(matching: participantId, allowSingleFallback: false) != nil {
                    self.stopRemoteScreenShareAttachRetry()
                    return
                }
            }
            self.remoteScreenShareAttachRetryKey = nil
            self.logger.log(
                level: .warning,
                message: "Remote screen share attach retry exhausted for participant=\(participantId)"
            )
        }
    }

    /// Removes a remote screen-share tile and returns to normal layout.
    func tearDownScreenView(participantId: String) async {
        stopRemoteScreenShareAttachRetry()

        var models = screenShareModels(matching: participantId)
        if models.isEmpty {
            if let fallback = screenShareModel(matching: participantId, allowSingleFallback: true) {
                models = [fallback]
            } else if RTCSession.shouldAcceptRemoteScreenShareEnd(
                activeParticipantId: activeRemoteScreenShareParticipantId,
                endedParticipantId: participantId
            ) {
                models = videoViews.views.filter(isRemoteScreenShareModel)
            }
        }

        guard !models.isEmpty else {
            await finalizeScreenShareLayoutTransition(
                participantId: participantId,
                notifyDelegate: true
            )
            logger.log(
                level: .warning,
                message: "Screen share teardown had no matching remote tile for participant=\(participantId); activeScreenShare=\(hasActiveRemoteScreenShare)"
            )
            return
        }

        for model in models {
            await tearDownScreenShareViewModel(model, requestedParticipantId: participantId)
        }
        let resolvedParticipantId = models.last?.participantId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? models.last!.participantId
            : participantId
        await finalizeScreenShareLayoutTransition(
            participantId: resolvedParticipantId,
            notifyDelegate: true
        )
        logger.log(
            level: .info,
            message: "Remote screen share view removed for participant=\(resolvedParticipantId) requestedParticipant=\(participantId)"
        )
    }

    private func tearDownScreenShareViewModel(
        _ model: VideoViewModel,
        requestedParticipantId: String
    ) async {
        let actualParticipantId = model.participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendererParticipantId = actualParticipantId.isEmpty ? requestedParticipantId : actualParticipantId
        let recoveryConnectionId = model.connectionId.isEmpty ? currentCall?.sharedCommunicationId : model.connectionId
        if let recoveryConnectionId {
            stopScreenShareRendererRecovery(connectionId: recoveryConnectionId, participantId: rendererParticipantId)
        } else if RTCSession.remoteScreenShareParticipantMatches(activeRemoteScreenShareParticipantId, rendererParticipantId) {
            stopAllScreenShareRendererRecovery()
        }
        let screenView = model.videoView
        if let screenRenderer = screenView.renderer as? SampleBufferViewRenderer {
            await screenRenderer.setRemoteVideoInboundExpected(false)
            await screenRenderer.shutdown()
            if let connectionId = recoveryConnectionId {
                await session.removeRemoteScreenVideoRenderer(
                    screenRenderer.rtcVideoRenderWrapper,
                    connectionId: connectionId,
                    participantId: rendererParticipantId
                )
            }
        }
        screenView.shutdownMetalStream()
        videoViews.removeView(model)
    }

    private func finalizeScreenShareLayoutTransition(
        participantId: String,
        notifyDelegate: Bool
    ) async {
        hasActiveRemoteScreenShare = videoViews.views.contains(where: isRemoteScreenShareModel)
        if hasActiveRemoteScreenShare {
            activeRemoteScreenShareParticipantId = videoViews.views.first(where: isRemoteScreenShareModel)?.participantId
        } else {
            activeRemoteScreenShareParticipantId = nil
        }
        await syncParticipantCameraTileAspectModes()
        if !hasActiveRemoteScreenShare {
            await rebindRemoteCameraRenderersAfterScreenShareEnd()
        }
        await performQuery(removePreview: previewDetachedToOverlay)
        configureLocalPreviewIfNeeded()
        await Task.yield()
        if let collectionView = mainCollectionView() {
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
        }
        reconfigureVisibleVideoCells()
        await refreshMountedVideoRendererBounds()
        if !hasActiveRemoteScreenShare {
            schedulePostScreenShareLayoutHeal()
        }
        if notifyDelegate {
            scheduleRemoteScreenShareDidChange(
                participantId: participantId,
                isSharing: hasActiveRemoteScreenShare
            )
        }
    }

    private func scheduleRemoteScreenShareDidChange(participantId: String, isSharing: Bool) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isRunning else { return }
            let active = self.hasActiveRemoteScreenShare
            let resolvedParticipantId = active
                ? (self.activeRemoteScreenShareParticipantId ?? participantId)
                : participantId
            await self.videoCallDelegate?.remoteScreenShareDidChange(
                participantId: resolvedParticipantId,
                isSharing: active
            )
        }
    }

    /// Adds a "Presenting" badge to a screen-share tile (idempotent).
    private func addPresenterBadge(to view: NTMTKView) {
        let badgeId = NSUserInterfaceItemIdentifier("presenterBadge")
        if view.subviews.contains(where: { $0.identifier == badgeId }) { return }

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        badge.layer?.cornerRadius = 6
        badge.identifier = NSUserInterfaceItemIdentifier("presenterBadge")

        let label = NSTextField(labelWithString: "Presenting")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        badge.addSubview(label)

        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled", accessibilityDescription: "Presenting")!)
        icon.contentTintColor = .white
        badge.addSubview(icon)

        view.addSubview(badge)
        badge.anchors(top: view.topAnchor, leading: view.leadingAnchor, paddingTop: 8, paddingLeading: 8)
        icon.anchors(leading: badge.leadingAnchor, centerY: badge.centerYAnchor, paddingLeading: 6, width: 14, height: 14)
        label.anchors(top: badge.topAnchor, leading: icon.trailingAnchor, bottom: badge.bottomAnchor, trailing: badge.trailingAnchor, paddingTop: 4, paddingLeading: 4, paddingBottom: 4, paddingTrailing: 8)
    }

    private func participantHasRaisedHand(_ participantId: String) -> Bool {
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }
        return conferenceRaisedHands.contains { key, value in
            value && RTCSession.conferenceParticipantIdentityKey(key) == participantKey
        }
    }

    private func removeRaisedHandIndicator(from view: NTMTKView) {
        let indicatorId = NSUserInterfaceItemIdentifier("raisedHandIndicator")
        view.subviews.first(where: { $0.identifier == indicatorId })?.removeFromSuperview()
    }

    private func addRaisedHandIndicator(to view: NTMTKView) {
        let indicatorId = NSUserInterfaceItemIdentifier("raisedHandIndicator")
        if view.subviews.contains(where: { $0.identifier == indicatorId }) { return }

        let label = NSTextField(labelWithString: "✋")
        label.identifier = indicatorId
        label.font = NSFont.systemFont(ofSize: 24)
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        let topPadding = max(8, min(22, conferenceRaisedHandBadgeTopClearance * 0.25))
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: topPadding),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            label.widthAnchor.constraint(equalToConstant: 30),
            label.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func applyConferenceRaisedHandIndicators() {
        for model in videoViews.views {
            guard isParticipantCameraModel(model) else {
                removeRaisedHandIndicator(from: model.videoView)
                continue
            }
            if participantHasRaisedHand(model.participantId) {
                addRaisedHandIndicator(to: model.videoView)
            } else {
                removeRaisedHandIndicator(from: model.videoView)
            }
        }
    }

    private func stopRemoteRendererRecovery() {
        remoteRendererRecoveryTask?.cancel()
        remoteRendererRecoveryTask = nil
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

    private func screenShareRendererRecoveryKey(connectionId: String, participantId: String) -> String {
        "screen|\(participantRendererRecoveryKey(connectionId: connectionId, participantId: participantId))"
    }

    private func stopScreenShareRendererRecovery(connectionId: String, participantId: String) {
        let key = screenShareRendererRecoveryKey(connectionId: connectionId, participantId: participantId)
        screenShareRendererRecoveryTasksByKey.removeValue(forKey: key)?.cancel()
        lastScreenShareRendererRecoveryUptimeNsByKey.removeValue(forKey: key)
    }

    private func stopAllScreenShareRendererRecovery() {
        for task in screenShareRendererRecoveryTasksByKey.values {
            task.cancel()
        }
        screenShareRendererRecoveryTasksByKey.removeAll()
        lastScreenShareRendererRecoveryUptimeNsByKey.removeAll()
    }

    private func startRemoteRendererRecoveryIfNeeded(
        renderer: SampleBufferViewRenderer,
        connectionId: String
    ) {
        stopRemoteRendererRecovery()
        remoteRendererRecoveryTask = Task { [weak self] in
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
                   now - self.lastRemoteRendererRecoveryUptimeNs < Self.remoteRendererRecoveryCooldownNs {
                    continue
                }
                let inboundFlow = await self.session.cachedInboundRemoteVideoFlow(connectionId: connectionId)
                if let flow = inboundFlow {
                    self.logger.log(
                        level: .warning,
                        message: "Remote renderer stall probe (callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState), inAudioPackets=\(flow.audioPacketsReceived), inVideoPackets=\(flow.packetsReceived), inFrames=\(flow.framesReceived), inDecoded=\(flow.framesDecoded), dAudioPackets=\(flow.deltaAudioPacketsReceived), dVideoPackets=\(flow.deltaPacketsReceived), dFrames=\(flow.deltaFramesReceived), dDecoded=\(flow.deltaFramesDecoded))"
                    )
                } else {
                    self.logger.log(
                        level: .warning,
                        message: "Remote renderer stall probe (callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs)) could not read inbound flow stats"
                    )
                }

                let shouldRecoverRenderer = RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
                    inboundFlow: inboundFlow,
                    callbackAgeMs: callbackAgeMs,
                    hasAnyCallbacks: hasAnyCallbacks,
                    expectationAgeMs: expectationAgeMs
                )
                guard shouldRecoverRenderer else {
                    self.logger.log(
                        level: .warning,
                        message: "Skipping renderer recovery: inbound media counters not advancing enough for local-renderer recovery; likelyCause=\(inboundFlow?.likelyCause ?? "unknown") connectionId=\(connectionId)"
                    )
                    continue
                }

                self.logger.log(
                    level: .warning,
                    message: "Remote renderer stalled with advancing inbound media; restarting stream + rebinding track for connectionId=\(connectionId)"
                )
                self.lastRemoteRendererRecoveryUptimeNs = now
                await self.session.recoverInboundRemoteVideoAfterDecodeStall(connectionId: connectionId)
                await renderer.startStream()
                await self.session.renderRemoteVideo(to: renderer.rtcVideoRenderWrapper, with: connectionId)
                await self.applyMainRemoteTileInboundExpectation(connectionId: connectionId)
            }
        }
    }

    private func startRemoteScreenShareRendererRecoveryIfNeeded(
        renderer: SampleBufferViewRenderer,
        connectionId: String,
        participantId: String
    ) {
        let normalizedConnectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        let trimmedParticipantId = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConnectionId.isEmpty, !trimmedParticipantId.isEmpty else { return }
        let key = screenShareRendererRecoveryKey(connectionId: normalizedConnectionId, participantId: trimmedParticipantId)
        if let existing = screenShareRendererRecoveryTasksByKey[key], !existing.isCancelled {
            return
        }

        screenShareRendererRecoveryTasksByKey[key] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard self.isRunning else { continue }
                guard self.currentCallState != .waiting else { continue }
                guard RTCSession.remoteScreenShareParticipantMatches(
                    self.activeRemoteScreenShareParticipantId,
                    trimmedParticipantId
                ) else { return }
                guard self.screenShareModel(matching: trimmedParticipantId, allowSingleFallback: false) != nil else {
                    return
                }

                let callbackAgeMs = await renderer.ageMillisecondsSinceLastVideoFrameCallback()
                let expectationAgeMs = await renderer.ageMillisecondsSinceInboundVideoExpectationBegan()
                let hasAnyCallbacks = await renderer.hasReceivedAnyVideoFrameCallbacks()
                let noCallbacksYet = callbackAgeMs < 0
                    && expectationAgeMs >= 3_000
                    && !hasAnyCallbacks
                guard callbackAgeMs > 3_000 || noCallbacksYet else { continue }

                let now = DispatchTime.now().uptimeNanoseconds
                let last = self.lastScreenShareRendererRecoveryUptimeNsByKey[key] ?? 0
                if last > 0, now >= last, now - last < Self.remoteRendererRecoveryCooldownNs {
                    continue
                }
                let inboundFlow = await self.session.cachedInboundRemoteVideoFlow(connectionId: normalizedConnectionId)
                let screenFlow = await self.session.cachedInboundRemoteScreenVideoFlow(connectionId: normalizedConnectionId)
                if let flow = screenFlow ?? inboundFlow {
                    self.logger.log(
                        level: .warning,
                        message: "macOS remote screen-share stall probe (participant=\(trimmedParticipantId), callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs), screenFlow=\(screenFlow?.state.rawValue ?? "nil"), screenCause=\(screenFlow?.likelyCause ?? "nil"), aggregateFlow=\(inboundFlow?.state.rawValue ?? "nil"), aggregateCause=\(inboundFlow?.likelyCause ?? "nil"), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState), screenPackets=\(screenFlow?.packetsReceived ?? -1), screenDecoded=\(screenFlow?.framesDecoded ?? -1), dScreenPackets=\(screenFlow?.deltaPacketsReceived ?? -1), dScreenDecoded=\(screenFlow?.deltaFramesDecoded ?? -1))"
                    )
                } else {
                    self.logger.log(
                        level: .warning,
                        message: "macOS remote screen-share stall probe (participant=\(trimmedParticipantId), callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs)) could not read inbound flow stats"
                    )
                }

                let shouldRecoverRenderer = RTCSession.shouldAttemptInboundRemoteScreenRendererRecovery(
                    screenFlow: screenFlow,
                    aggregateFlow: inboundFlow,
                    callbackAgeMs: callbackAgeMs,
                    hasAnyCallbacks: hasAnyCallbacks,
                    expectationAgeMs: expectationAgeMs
                )
                guard shouldRecoverRenderer else {
                    self.logger.log(
                        level: .warning,
                        message: "macOS remote screen-share recovery skipped: inbound counters not advancing enough; participant=\(trimmedParticipantId) screenCause=\(screenFlow?.likelyCause ?? "unknown") aggregateCause=\(inboundFlow?.likelyCause ?? "unknown") connectionId=\(normalizedConnectionId)"
                    )
                    continue
                }

                let transportRecovery = (screenFlow?.likelyCause == "transport_or_ice_instability")
                    || (inboundFlow?.likelyCause == "transport_or_ice_instability")
                self.logger.log(
                    level: .warning,
                    message: "macOS remote screen-share renderer stalled; restarting stream + rebinding screen track participant=\(trimmedParticipantId) connectionId=\(normalizedConnectionId) transportRecovery=\(transportRecovery)"
                )
                self.lastScreenShareRendererRecoveryUptimeNsByKey[key] = now
                if transportRecovery {
                    await self.session.attemptIceRestartRenegotiationIfNeeded(
                        connectionId: normalizedConnectionId,
                        reason: "remote_screen_renderer_stall"
                    )
                }
                await self.session.recoverInboundRemoteScreenAfterDecodeStall(connectionId: normalizedConnectionId)
                await renderer.startStream()
                let didAttach = await self.session.renderRemoteScreenVideo(
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

        participantRendererRecoveryTasksByKey[key] = Task { [weak self] in
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
                if last > 0, now >= last, now - last < Self.remoteRendererRecoveryCooldownNs {
                    continue
                }
                let inboundFlow = await self.session.cachedInboundRemoteVideoFlow(connectionId: normalizedConnectionId)
                let bindingDiagnostics = await self.session.participantCameraRendererBindingDiagnostics(
                    connectionId: normalizedConnectionId,
                    participantId: trimmedParticipantId,
                    renderer: renderer.rtcVideoRenderWrapper
                )
                if let flow = inboundFlow {
                    self.logger.log(
                        level: .warning,
                        message: "macOS participant camera stall probe (participant=\(trimmedParticipantId), callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState), inAudioPackets=\(flow.audioPacketsReceived), inVideoPackets=\(flow.packetsReceived), inFrames=\(flow.framesReceived), inDecoded=\(flow.framesDecoded), dAudioPackets=\(flow.deltaAudioPacketsReceived), dVideoPackets=\(flow.deltaPacketsReceived), dFrames=\(flow.deltaFramesReceived), dDecoded=\(flow.deltaFramesDecoded), binding=\(bindingDiagnostics))"
                    )
                } else {
                    self.logger.log(
                        level: .warning,
                        message: "macOS participant camera stall probe (participant=\(trimmedParticipantId), callbackAgeMs=\(callbackAgeMs), expectationAgeMs=\(expectationAgeMs), binding=\(bindingDiagnostics)) could not read inbound flow stats"
                    )
                }

                let shouldRecoverRenderer = RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
                    inboundFlow: inboundFlow,
                    callbackAgeMs: callbackAgeMs,
                    hasAnyCallbacks: hasAnyCallbacks,
                    expectationAgeMs: expectationAgeMs
                )
                guard shouldRecoverRenderer else {
                    self.logger.log(
                        level: .warning,
                        message: "macOS participant camera recovery skipped: inbound counters not advancing enough; participant=\(trimmedParticipantId) likelyCause=\(inboundFlow?.likelyCause ?? "unknown") connectionId=\(normalizedConnectionId)"
                    )
                    continue
                }

                self.logger.log(
                    level: .warning,
                    message: "macOS participant camera renderer stalled with advancing inbound media; re-attaching participant track participant=\(trimmedParticipantId) connectionId=\(normalizedConnectionId)"
                )
                self.lastParticipantRendererRecoveryUptimeNsByKey[key] = now
                await self.session.recoverInboundRemoteVideoAfterDecodeStall(connectionId: normalizedConnectionId)
                await renderer.clearCachedMetalDisplayFrame()
                await renderer.startStream()
                let didAttach = await self.session.renderRemoteVideoForParticipant(
                    to: renderer.rtcVideoRenderWrapper,
                    connectionId: normalizedConnectionId,
                    participantId: trimmedParticipantId,
                    forceParticipantRendererRebind: true
                )
                if didAttach {
                    await renderer.setRemoteVideoInboundExpected(true)
                }
            }
        }
    }
    
    
    /// Rebuilds and applies the diffable-data-source snapshot from the current Metal view list.
    func performQuery(removePreview: Bool = false) async {
        var snapshot = NSDiffableDataSourceSnapshot<ConferenceCallSections, VideoViewModel>()
        
        var data = await videoViews.getViews()
        if removePreview || previewDetachedToOverlay {
            data.removeAll(where: { $0.videoView.contextName == "preview" })
        }
        let hasVisibleScreenShare = data.contains(where: isScreenShareModel)
        let hadVisibleScreenShare = hasVisibleScreenShareInCollection
        let hadActiveRemoteScreenShare = hasActiveRemoteScreenShare
        hasActiveRemoteScreenShare = data.contains(where: isRemoteScreenShareModel)
        hasVisibleScreenShareInCollection = hasVisibleScreenShare
        if hadActiveRemoteScreenShare != hasActiveRemoteScreenShare {
            let participantId = activeRemoteScreenShareParticipantId ?? ""
            scheduleRemoteScreenShareDidChange(
                participantId: participantId,
                isSharing: hasActiveRemoteScreenShare
            )
        }
        await syncVoiceCallWindowForScreenShare(hasVisibleScreenShare: hasVisibleScreenShare)
        if hasVisibleScreenShare {
            data = screenShareFirst(data)
        }
        if let collectionView = mainCollectionView() {
            collectionView.collectionViewLayout = createLayout(itemCount: max(1, data.count))
        }
        await syncParticipantCameraTileAspectModes()
        if data.isEmpty {
            await applySnapshotAsync(snapshot, animatingDifferences: false)
        } else {
            snapshot.appendSections([.initial])
            snapshot.appendItems(data, toSection: .initial)
            await applySnapshotAsync(snapshot, animatingDifferences: false)
        }
        if let collectionView = mainCollectionView() {
            collectionView.layoutSubtreeIfNeeded()
            if hadVisibleScreenShare != hasVisibleScreenShare {
                collectionView.collectionViewLayout?.invalidateLayout()
                collectionView.layoutSubtreeIfNeeded()
            }
        }
        reconfigureVisibleVideoCells()
        await refreshMountedVideoRendererBounds()
        if hadVisibleScreenShare, !hasVisibleScreenShare {
            await rebindRemoteCameraRenderersAfterScreenShareEnd()
            schedulePostScreenShareLayoutHeal()
        } else if hadVisibleScreenShare != hasVisibleScreenShare {
            scheduleScreenShareLayoutTransitionHeal(expectingScreenShareVisible: hasVisibleScreenShare)
        }
        
        // Self-heal: if preview is detached, keep it pinned in the overlay after every snapshot/layout
        // update so collection-view churn cannot strand it behind/inside cells.
        if previewDetachedToOverlay,
           let controllerView = self.view as? ControllerView,
           let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView {
            controllerView.addConnectedLocalVideoView(view: localView)
            scheduleConfigureLocalPreviewIfNeeded(animated: false)
        }
        applyConferenceRaisedHandIndicators()
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
    
    /// Installs a custom controls overlay.
    ///
    /// This is primarily used when the host app wants to provide a bespoke control
    /// surface (mute/end/pip) while reusing PQSRTC's rendering and state wiring.
    @MainActor
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
            controllerView.setCallInfoChromeHidden(true)
            controllerView.bringLocalPreviewOverlayToFront()
            controllerView.layoutSubtreeIfNeeded()
        }
    }
    
    @objc private func dragPreviewView(_ sender: NSPanGestureRecognizer) {
        guard let controllerView = self.view as? ControllerView else { return }
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        let location = sender.location(in: controllerView.localPreviewOverlay)
        if sender.state == .began {
            previewPanAccumulatedDistance = 0
            isDraggingPreview = localView.frame.insetBy(dx: -8, dy: -8).contains(location)
        }
        if sender.view === controllerView.localPreviewOverlay, !isDraggingPreview {
            return
        }
        let translation = sender.translation(in: controllerView.localPreviewOverlay)
        previewPanAccumulatedDistance += hypot(translation.x, translation.y)
        controllerView.moveLocalPreview(by: translation, view: localView)
        sender.setTranslation(.zero, in: controllerView.localPreviewOverlay)
        
        switch sender.state {
        case .ended, .cancelled, .failed:
            isDraggingPreview = false
            controllerView.snapLocalPreviewToNearestCorner(view: localView)
            if previewPanAccumulatedDistance > previewPanSuppressionDistanceThreshold {
                previewToggleClickSuppressionDeadline = Date().addingTimeInterval(0.22)
            }
            previewPanAccumulatedDistance = 0
        default:
            break
        }
    }
    
    @objc private func tapPreviewView(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
        if let deadline = previewToggleClickSuppressionDeadline, Date() < deadline { return }
        guard let controllerView = self.view as? ControllerView else { return }
        guard let localView = detachedPreviewView ?? videoViews.views.first(where: { $0.videoView.contextName == "preview" })?.videoView else { return }
        guard let host = localPreviewGestureHostView, sender.view === host else { return }
        let point = sender.location(in: host)
        guard host.bounds.insetBy(dx: -2, dy: -2).contains(point) else { return }
        isPreviewMinimized.toggle()
        controllerView.updateLocalVideoSize(
            isConnected: true,
            view: localView,
            minimize: isPreviewMinimized,
            animated: true
        )
        controllerView.snapLocalPreviewToNearestCorner(view: localView)
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
                self.configureVideoItemCell(item, model: model)
                return item
            }
    }
    
    
    /// Creates the compositional layout used for the call video grid.
    fileprivate func createLayout(itemCount: Int? = nil) -> NSCollectionViewLayout {
        let layout = NSCollectionViewCompositionalLayout { [weak self]
            (_: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection in
            guard let self else {
                return CollectionViewSections().fullScreenItem()
            }
            let rawEffective = layoutEnvironment.container.effectiveContentSize
            let controllerView = self.view as? ControllerView
            let collectionView = controllerView?.scrollView.documentView as? NSCollectionView
            var effective = rawEffective
            if effective.width < 1 || effective.height < 1 {
                if let cv = collectionView {
                    let bb = cv.bounds.size
                    if bb.width >= 1, bb.height >= 1 {
                        effective = bb
                    } else {
                        let fs = cv.frame.size
                        if fs.width >= 1, fs.height >= 1 {
                            effective = fs
                        } else {
                            effective = self.lastStableCompositionalContentSize
                        }
                    }
                } else {
                    effective = self.lastStableCompositionalContentSize
                }
            }
            if effective.width >= 1, effective.height >= 1 {
                self.lastStableCompositionalContentSize = effective
            }
            let liveCount: Int = {
                guard let collectionView else { return 0 }
                guard collectionView.numberOfSections > 0 else { return 0 }
                return collectionView.numberOfItems(inSection: 0)
            }()
            let snapshotCount = self.dataSource?.snapshot().numberOfItems ?? 0
            // Prefer live `NSCollectionView` counts when non-zero: the diffable snapshot can briefly
            // read `0` during apply/resize while cells are still mounted (remote tile looked “removed”).
            let resolvedItemCount = itemCount ?? (liveCount > 0 ? liveCount : snapshotCount)
            let sectionKind: String = {
                if self.hasVisibleScreenShareInCollection, resolvedItemCount > 1 {
                    return "screenShareDominant"
                }
                return resolvedItemCount > 1 ? "conference" : "fullscreen"
            }()
            let compSig = "\(Int(effective.width))x\(Int(effective.height))|\(liveCount)|\(snapshotCount)|\(resolvedItemCount)|\(sectionKind)"
            if compSig != self.lastCompositionalLayoutProbeSignature {
                self.lastCompositionalLayoutProbeSignature = compSig
                self.logLayoutProbe("compositionalSection effectiveContent=\(Int(effective.width))x\(Int(effective.height)) liveCount=\(liveCount) snapshotCount=\(snapshotCount) resolved=\(resolvedItemCount) section=\(sectionKind)")
            }
            if self.hasVisibleScreenShareInCollection, resolvedItemCount > 1 {
                let cameraTileCount = resolvedItemCount - 1
                return self.sections.screenShareDominantSection(cameraTileCount: cameraTileCount, groupAbsoluteExtent: effective)
            }
            if resolvedItemCount > 1 {
                return self.sections.conferenceViewSection(itemCount: resolvedItemCount, groupAbsoluteExtent: effective)
            }
            return self.sections.fullScreenItem(groupAbsoluteExtent: effective)
        }
        return layout
    }

    private func logLayoutProbe(_ message: String) {
        guard Self.isLayoutProbeEnabled else { return }
        logger.log(level: .debug, message: "[VideoCallLayoutProbe] \(message)")
    }

    private func installWindowCloseObserverIfNeeded() {
        guard windowWillCloseObserver == nil, let window = view.window else { return }
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentCall != nil {
                    await self.tearDownCall()
                }
            }
        }
    }

    private func removeWindowCloseObserver() {
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
            self.windowWillCloseObserver = nil
        }
    }
}


extension VideoCallViewController: CallActionDelegate {
    /// Ends the current call and tears down local/remote rendering.
    public func endCall() async {
        await tearDownCall()
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
        let displayChanged = isMutingAudio != muted
        do {
            try await session.setAudioTrack(isEnabled: !muted, connectionId: callId)
            isMutingAudio = muted
            if displayChanged {
                await videoCallDelegate?.localMuteDisplayDidChange(videoMuted: isMutingVideo, audioMuted: isMutingAudio)
            }
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

    public func toggleSpeakerPhone() {
        // No-op on macOS; not applicable
    }

    public func setSpeakerOutputEnabled(_ enabled: Bool) {
        _ = enabled
    }
    
    public func showPictureInPicture(_ show: Bool) async {
        // No-op on macOS; not implemented
    }

    /// Starts screen sharing with the given target.
    public func startScreenShare(target: ScreenShareTarget) async {
        await startScreenShare(target: target, options: ScreenShareOptions())
    }

    /// Starts screen sharing with the given target and capture preferences.
    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        _ = await startScreenShareAndReport(target: target, options: options)
    }

    /// Starts screen sharing and reports whether the local sender setup succeeded.
    public func startScreenShareAndReport(target: ScreenShareTarget, options: ScreenShareOptions) async -> Bool {
        guard let connectionId = await resolvedMuteConnectionId() else {
            logger.log(level: .warning, message: "startScreenShare: no active connection")
            return false
        }
        do {
            try await session.addScreenTrackToStream(target: target, options: options, connectionId: connectionId)
            return true
        } catch {
            logger.log(level: .error, message: "startScreenShare failed: \(error)")
            await videoCallDelegate?.passErrorMessage(error.localizedDescription)
            await videoCallDelegate?.screenShareDidChange(isSharing: false)
            return false
        }
    }

    /// Stops the active screen share.
    public func stopScreenShare() async {
        guard let connectionId = await resolvedMuteConnectionId() else { return }
        await session.removeScreenTrackFromStream(connectionId: connectionId)
    }
}
#endif
