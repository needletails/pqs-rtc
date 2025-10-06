#if os(Android)
import Foundation

@MainActor
public final class AndroidVideoCallController: CallActionDelegate {
    public weak var videoCallDelegate: VideoCallDelegate?

    private unowned let session: RTCSession
    private var currentCall: Call?
    private var currentCallState: CallStateMachine.State = .waiting
    private var isRunning = true
    private var didUpgradeDowngrade = false
    private var upgradedToVideo = false
    private var isMutingAudio = false
    private var isMutingVideo = false

    private var localView: AndroidPreviewCaptureView?
    private var remoteView: AndroidSampleCaptureView?
    private var remoteViews: [AndroidSampleCaptureView] = []

    private var stateStreamTask: Task<Void, Never>?

    public init(session: RTCSession) {
        self.session = session
    }

    public func attachViews(local: AndroidPreviewCaptureView, remote: AndroidSampleCaptureView) {
        self.localView = local
        self.remoteView = remote
    }

    public func attachViews(local: AndroidPreviewCaptureView, remotes: [AndroidSampleCaptureView]) {
        self.localView = local
        self.remoteViews = remotes
        self.remoteView = remotes.first
    }

    public func start() {
        guard stateStreamTask == nil else { return }
        stateStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let stateStream = await session.callState.getCurrentCallStream().last else { return }
            for await state in stateStream {
                guard state != self.currentCallState else { continue }
                self.currentCallState = state
                await videoCallDelegate?.deliverCallState(state)
                switch state {
                case .waiting:
                    break
                case .ready:
                    break
                case .connecting(let direction, let call):
                    self.currentCall = call
                    switch direction {
                    case .inbound(let type), .outbound(let type):
                        switch type {
                        case .voice:
                            break
                        case .video:
                            self.upgradedToVideo = true
                            await self.createPreviewView()
                        }
                    }
                case .connected(let direction, let call):
                    self.currentCall = call
                    switch direction {
                    case .inbound(let type), .outbound(let type):
                        switch type {
                        case .voice:
                            break
                        case .video:
                            self.upgradedToVideo = true
                            await self.createSampleView()
                        }
                    }
                case .held:
                    break
                case .ended:
                    await tearDownCall()
                case .failed(_, _, let errorMessage):
                    await videoCallDelegate?.passErrorMessage(errorMessage)
                    await tearDownCall()
                case .receivedVideoUpgrade:
                    self.upgradedToVideo = true
                    await createPreviewView(shouldQuery: false)
                    await createSampleView()
                    await videoCallDelegate?.videoUpgraded(true)
                case .receivedVoiceDowngrade:
                    self.upgradedToVideo = false
                    await tearDownPreviewView()
                    await tearDownSampleView()
                    await videoCallDelegate?.videoUpgraded(false)
                case .callAnsweredAuxDevice:
                    await tearDownCall()
                }
            }
        }
    }

    public func stop() async {
        await tearDownCall()
    }

    // MARK: - Actions
    public func endCall() {
        Task { [weak self] in
            guard let self else { return }
            if let call = self.currentCall {
                try? await self.session.getDelegate()?.invokeEnd(call: call, endState: .userInitiated)
            }
            await self.tearDownCall()
        }
    }

    public func muteAudio() {
        isMutingAudio.toggle()
        Task { [weak self] in
            guard let self = self, let callId = self.currentCall?.sharedCommunicationId else { return }
            do {
                try await self.session.setAudioTrack(isEnabled: !self.isMutingAudio, connectionId: callId)
            } catch {
                // swallow in release; delegate already receives failures
            }
            if await self.session.callState.getCallType() == .video {
                self.muteVideo()
            }
        }
    }

    public func muteVideo() {
        isMutingVideo.toggle()
        Task { [weak self] in
            guard let self = self, let callId = self.currentCall?.sharedCommunicationId else { return }
            await self.session.setVideoTrack(isEnabled: !self.isMutingVideo, connectionId: callId)
        }
    }

    public func upgradeDowngrade() {
        if didUpgradeDowngrade { return }
        didUpgradeDowngrade = true
        Task { @MainActor [weak self] in
            guard let self = self, let callId = self.currentCall?.sharedCommunicationId else {
                self?.didUpgradeDowngrade = false; return
            }
            do {
                if upgradedToVideo {
                    try await self.downgradeToVoice(callId: callId)
                } else {
                    try await self.upgradeToVideo(callId: callId)
                }
            } catch {
                self.didUpgradeDowngrade = false
            }
        }
    }

    public func toggleSpeakerPhone() {
        // Optional: implement via Android AudioManager if needed
    }

    public func showPictureInPicture(_ show: Bool) {
        // Optional: implement Android PiP if needed
    }

    // MARK: - View Management
    private func createPreviewView(shouldQuery: Bool = true) async {
        guard let connectionId = currentCall?.sharedCommunicationId, let localView else { return }
        await session.renderLocalVideo(to: localView, connectionId: connectionId)
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }

    private func createSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if !remoteViews.isEmpty {
            for view in remoteViews {
                await session.renderRemoteVideo(to: view, connectionId: connectionId)
            }
        } else if let remoteView {
            await session.renderRemoteVideo(to: remoteView, connectionId: connectionId)
        }
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }

    private func tearDownPreviewView() async {
        guard let connectionId = currentCall?.sharedCommunicationId, let localView else { return }
        await session.removeLocal(view: localView, connectionId: connectionId)
    }

    private func tearDownSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        if !remoteViews.isEmpty {
            for view in remoteViews {
                await session.removeRemote(view: view, connectionId: connectionId)
            }
        } else if let remoteView {
            await session.removeRemote(view: remoteView, connectionId: connectionId)
        }
    }

    // MARK: - Upgrade/Downgrade
    private func downgradeToVoice(callId: String) async throws {
        await tearDownPreviewView()
        await tearDownSampleView()
        let call = try await session.downgradeToVoice(connectionId: callId)
        try await session.getDelegate()?.sendUpDowngrade(to: call, isUpgrade: false)
        upgradedToVideo = false
        didUpgradeDowngrade = false
        await videoCallDelegate?.videoUpgraded(false)
    }

    private func upgradeToVideo(callId: String) async throws {
        await createPreviewView(shouldQuery: false)
        await createSampleView()
        let call = try await session.upgradeToVideo(connectionId: callId)
        try await session.getDelegate()?.sendUpDowngrade(to: call, isUpgrade: true)
        upgradedToVideo = true
        didUpgradeDowngrade = false
        await videoCallDelegate?.videoUpgraded(true)
    }

    // MARK: - Teardown
    private func tearDownCall() async {
        guard isRunning else { return }
        await tearDownPreviewView()
        await tearDownSampleView()
        isRunning = false
        await session.shutdown()
        stateStreamTask?.cancel(); stateStreamTask = nil
        currentCall = nil
    }
}
#endif
