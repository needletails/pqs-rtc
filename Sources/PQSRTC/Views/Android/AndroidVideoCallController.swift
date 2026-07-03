//  AndroidVideoCallController.swift
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

#if os(Android)
import Foundation
import NeedleTailLogger

/// Android-side call controller that coordinates `RTCSession` state with UI views.
///
/// This actor listens to the session's call state stream and:
/// - Notifies a `VideoCallDelegate` about state changes and errors.
/// - Attaches/detaches local and remote video renderers.
/// - Dynamically assigns per-participant tracks to views for group/conference calls.
/// - Exposes user actions (end call, mute audio/video) via `CallActionDelegate`.
public actor AndroidVideoCallController: CallActionDelegate {
    public weak var videoCallDelegate: VideoCallDelegate?

    private unowned let session: RTCSession
    private var currentCall: Call?
    private var currentCallState: CallStateMachine.State = .waiting
    private var _currentCallState: CallStateMachine.State {
        get async {
            currentCallState
        }
    }
    private let logger = NeedleTailLogger()
    private var isRunning = true
    private var didUpgradeDowngrade = false
    private var upgradedToVideo = false
    private var isMutingAudio = false
    private var isMutingVideo = false

    private var localView: AndroidPreviewCaptureView?
    private var remoteView: AndroidSampleCaptureView?
    private var remoteViews: [AndroidSampleCaptureView] = []

    private var stateStreamTask: Task<Void, Never>?
    private var localScreenShareStateTask: Task<Void, Never>?
    private var screenTrackStreamTask: Task<Void, Never>?
    private var participantTrackStreamTask: Task<Void, Never>?
    private var screenView: AndroidSampleCaptureView?
    private(set) var hasActiveRemoteScreenShare = false
    private var activeRemoteScreenShareParticipantId: String?
    private var conferenceRaisedHands: [String: Bool] = [:]

    /// Tracks which participant is currently rendered by which view.
    private var participantViewAssignments: [String: AndroidSampleCaptureView] = [:]
    /// Last successfully attached camera track id for each stable participant identity.
    private var participantAttachedTrackIdsByKey: [String: String] = [:]
    /// Serializes concurrent renderer attach attempts for the same participant tile.
    private var participantVideoAttachInFlightKeys: Set<String> = []
    /// Set when an attach was requested while another attach for the same participant was in flight.
    private var participantVideoAttachCoalescedKeys: Set<String> = []
    /// One renderer recovery attempt per participant stall episode.
    private var participantRendererRecoveryIssuedKeys: Set<String> = []
    /// Participants whose tile bind was settled by the post-renegotiation coordinator.
    private var participantCoordinatorSettledKeys: Set<String> = []
    private var inboundVideoFlowStreamTask: Task<Void, Never>?
    private var postRenegotiationAttachEpisodeStreamTask: Task<Void, Never>?
    private var sfuGroupSignalingStableStreamTask: Task<Void, Never>?
    /// Post-SFU renegotiation attach episode currently owned by the coordinator.
    private var postRenegotiationEpisodeConnectionId: String?
    private var postRenegotiationEpisodeParticipantIds: Set<String> = []
    private var postRenegotiationEpisodeIncludesGridLayout = false
    private var postRenegotiationCoordinatorInFlight = false
    private var postRenegotiationCoordinatorRerunNeeded = false
    /// Counts coordinator passes within one post-renegotiation episode (rebind runs once on pass 1 only).
    private var postRenegotiationCoordinatorPassIndex = 0
    /// Participants coordinator-bound during the active post-renegotiation episode.
    private var postRenegotiationCoordinatorBoundParticipantKeys: Set<String> = []
    /// Participants that received a full coordinator attach (not skip) during the current pass.
    private var postRenegotiationCoordinatorFullAttachedParticipantKeys: Set<String> = []
    /// Participants whose live-wrapper sink rebind succeeded during the active episode.
    private var postRenegotiationCoordinatorSinkReboundParticipantKeys: Set<String> = []
    /// Participants whose coordinator-settlement sink-only rebind already warmed the tile this episode.
    private var coordinatorSettlementSinkOnlySucceededKeys: Set<String> = []
    /// Participants pass-end stale sweep warmed this coordinator pass; settlement must not re-churn them.
    private var coordinatorPassEndMediaReadyParticipantKeys: Set<String> = []
    /// Participants whose pending live-wrapper rebind succeeded during the current finalize pass.
    private var coordinatorFinalizePendingRebindAppliedKeys: Set<String> = []
    /// Coordinator-settled tiles waiting for stale-tail stop before post-coordinator pending apply.
    private var postCoordinatorPendingWrapperApplyParticipantKeys: Set<String> = []
    /// Participants confirmed media-ready during the current finalize pass (before final sweep).
    private var coordinatorFinalizeMediaReadyConfirmedKeys: Set<String> = []
    /// Serializes bind/EGL work per participant tile during a post-renegotiation episode.
    private var participantAttachLaneBusyKeys: Set<String> = []
    private var participantAttachLaneWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var postRenegotiationCoordinatorFinalizeInProgress = false
    private struct CoordinatorFinalizeMediaReadyWaiter {
        let connectionId: String
        let view: AndroidSampleCaptureView
        let continuation: CheckedContinuation<Void, Never>
    }
    private var coordinatorFinalizeMediaReadyWaiters: [String: CoordinatorFinalizeMediaReadyWaiter] = [:]
    /// Pool of views not yet assigned to any participant.
    private var unassignedViews: [AndroidSampleCaptureView] = []
    /// Whether this is a group/conference call (multiple remote participants).
    private var isGroupCall: Bool {
        guard let currentCall else { return false }
        guard !isEphemeralOneToOneSfuRoom(currentCall) else { return false }
        let normalizedSharedId = currentCall.sharedCommunicationId.normalizedConnectionId
        return currentCall.conferencePassword != nil
            || currentCall.resolvedChannelWireId != nil
            || currentCall.recipients.count > 1
            || currentCall.sharedCommunicationId.isGroupCall
            || normalizedSharedId.hasPrefix("conf-")
    }

    /// 1:1 calls relayed through the SFU use a transient `#<uuid>` room. They still have a single
    /// remote party, so Android should use the 1:1 renderer path rather than the group grid mapper.
    private func isEphemeralOneToOneSfuRoom(_ call: Call) -> Bool {
        RTCSession.isTrueOneToOneSfuRoom(call: call)
    }

    public init(session: RTCSession) {
        self.session = session
    }

    /// Sets the remote capture views that should render inbound video.
    public func setRemoteViews(remotes: [AndroidSampleCaptureView]) async {
        let assignmentsLost = installRemoteViewsPreservingAssignments(remotes)
        logger.log(level: .debug, message: "SET REMOTE VIEWS count=\(remotes.count)")
        await videoCallDelegate?.remoteParticipantTilesDidChange()
        await syncWithCurrentState(reason: "setRemoteViews")
        if assignmentsLost, isGroupCall, let connectionId = currentCall?.sharedCommunicationId {
            await assignExistingParticipantTracks(connectionId: connectionId)
            await reattachAssignedParticipantVideoIfNeeded()
        }
    }

    /// Sets the local preview capture view used for outbound video.
    public func setLocalView(local: AndroidPreviewCaptureView) async {
        self.localView = local
        logger.log(level: .debug, message: "SET LOCAL VIEW")
        await syncWithCurrentState(reason: "setLocalView")
    }

    /// Installs all renderer views before syncing call state.
    ///
    /// Android `CallView` can appear while the session is already in `connecting`. Syncing after
    /// only the remote view is set causes the local preview bootstrap to run without a local view.
    public func setVideoViews(local: AndroidPreviewCaptureView, remotes: [AndroidSampleCaptureView]) async {
        self.localView = local
        let assignmentsLost = installRemoteViewsPreservingAssignments(remotes)
        logger.log(level: .info, message: "AndroidVideoCallController installed video views local=true remoteCount=\(remotes.count)")
        await videoCallDelegate?.remoteParticipantTilesDidChange()
        await syncWithCurrentState(reason: "setVideoViews")
        if assignmentsLost, isGroupCall, let connectionId = currentCall?.sharedCommunicationId {
            await assignExistingParticipantTracks(connectionId: connectionId)
            await reattachAssignedParticipantVideoIfNeeded()
        }
    }

    public func setVideoCallDelegate(_ conformer: VideoCallDelegate?) async {
        self.videoCallDelegate = conformer
    }

    private func installRemoteViewsPreservingAssignments(_ remotes: [AndroidSampleCaptureView]) -> Bool {
        let previousAssignmentCount = participantViewAssignments.count
        self.remoteViews = remotes
        self.remoteView = remotes.first

        participantViewAssignments = participantViewAssignments.filter { _, assignedView in
            remotes.contains { $0 === assignedView }
        }
        let retainedParticipantKeys = Set(participantViewAssignments.keys.map(participantAssignmentKey))
        participantAttachedTrackIdsByKey = participantAttachedTrackIdsByKey.filter { retainedParticipantKeys.contains($0.key) }

        unassignedViews = remotes.filter { candidate in
            !participantViewAssignments.values.contains { $0 === candidate }
        }
        return participantViewAssignments.count < previousAssignmentCount
    }

    /// Updates conference raised-hand state used for per-tile overlays.
    public func updateConferenceRaisedHands(_ raisedHands: [String: Bool]) {
        conferenceRaisedHands = raisedHands
    }

    /// Returns raised-hand overlay flags aligned with the supplied remote renderer views.
    public func raisedHandFlags(for views: [AndroidSampleCaptureView]) -> [Bool] {
        views.map { view in
            guard let participantId = participantViewAssignments.first(where: { $0.value === view })?.key else {
                return false
            }
            return participantHasRaisedHand(participantId)
        }
    }

    /// Stable signature of participant-to-view assignments for SwiftUI overlay refresh.
    public func participantAssignmentSignature() -> String {
        remoteViews.enumerated().map { index, view in
            let participantId = participantViewAssignments.first(where: { $0.value === view })?.key ?? "-"
            return "\(index):\(participantId)"
        }.joined(separator: "|")
    }

    /// Renderer views that are currently assigned to an active remote participant, preserving the
    /// resource pool order so SwiftUI overlays stay stable across refreshes.
    public func assignedRemoteViews() -> [AndroidSampleCaptureView] {
        remoteViews.filter { view in
            participantViewAssignments.values.contains { $0 === view }
        }
    }

    public func assignedParticipantCount() -> Int {
        participantViewAssignments.count
    }

    public func hasAssignmentsWithoutActiveSink() -> Bool {
        participantViewAssignments.values.contains { !$0.hasActiveSink() }
    }

    private func participantHasRaisedHand(_ participantId: String) -> Bool {
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        guard !participantKey.isEmpty else { return false }
        return conferenceRaisedHands.contains { key, value in
            value && RTCSession.conferenceParticipantIdentityKey(key) == participantKey
        }
    }

    private func participantAssignmentKey(_ participantId: String) -> String {
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        if !participantKey.isEmpty {
            return participantKey
        }
        return participantId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func assignedParticipantKey(matching participantId: String) -> String? {
        let eventKey = participantAssignmentKey(participantId)
        return participantViewAssignments.keys.first { assignedId in
            assignedId == participantId || participantAssignmentKey(assignedId) == eventKey
        }
    }

    private func shouldSurfaceParticipantTrack(connectionId: String, participantId: String) async -> Bool {
        let participantKey = participantAssignmentKey(participantId)
        guard !participantKey.isEmpty else { return false }
        guard UUID(uuidString: participantId.trimmingCharacters(in: .whitespacesAndNewlines)) == nil else {
            return false
        }

        if let connection = await session.connectionManager.findConnection(with: connectionId.normalizedConnectionId) {
            let localKey = participantAssignmentKey(connection.localParticipantId)
            if !localKey.isEmpty, localKey == participantKey {
                return false
            }
        }

        let roomId = currentCall?.resolvedChannelWireId
            ?? currentCall?.sharedCommunicationId
            ?? connectionId
        guard let group = await session.groupCallForRoom(roomId) else {
            return true
        }
        return await group.currentParticipants().contains { participant in
            participant.id == participantId || participantAssignmentKey(participant.id) == participantKey
        }
    }

    /// Returns the lowest-index renderer slot that is not already bound to another participant.
    private func nextUnassignedRemoteView() -> AndroidSampleCaptureView? {
        remoteViews.first { candidate in
            !participantViewAssignments.values.contains { $0 === candidate }
        }
    }

    /// Keeps renderer slots reserved across SFU renegotiation, but frees them once the SFU roster
    /// no longer includes the participant.
    private func shouldReleaseParticipantViewAssignment(
        connectionId: String,
        participantId: String
    ) async -> Bool {
        let roomId = currentCall?.resolvedChannelWireId
            ?? currentCall?.sharedCommunicationId
            ?? connectionId
        guard let group = await session.groupCallForRoom(roomId) else {
            return true
        }
        let eventKey = participantAssignmentKey(participantId)
        let stillPresent = await group.currentParticipants().contains { participant in
            participant.id == participantId || participantAssignmentKey(participant.id) == eventKey
        }
        return !stillPresent
    }

    private func mappedCameraTrackId(connectionId: String, participantId: String) async -> String? {
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await session.connectionManager.findConnection(with: normalizedId) else {
            return nil
        }

        let eventKey = participantAssignmentKey(participantId)
        let mapped = connection.remoteVideoTracksByParticipantId.first { mappedParticipantId, _ in
            mappedParticipantId == participantId || participantAssignmentKey(mappedParticipantId) == eventKey
        }

        if let trackId = mapped?.value.trackIdIfAvailable,
           !trackId.isEmpty {
            return trackId
        }
        if let mappedParticipantId = mapped?.key,
           let cachedTrackId = connection.androidRemoteCameraResolvedTrackIdsByParticipantId[mappedParticipantId],
           !cachedTrackId.isEmpty {
            return cachedTrackId
        }
        if let cachedTrackId = connection.androidRemoteCameraResolvedTrackIdsByParticipantId[participantId],
           !cachedTrackId.isEmpty {
            return cachedTrackId
        }
        return nil
    }

    private func recordAttachedTrack(connectionId: String, participantId: String) async {
        guard let trackId = await mappedCameraTrackId(connectionId: connectionId, participantId: participantId),
              !trackId.isEmpty else {
            return
        }
        participantAttachedTrackIdsByKey[participantAssignmentKey(participantId)] = trackId
    }

    private func participantRendererRecoveryKey(_ participantId: String) -> String {
        participantAssignmentKey(participantId)
    }

    private func assignParticipantView(_ view: AndroidSampleCaptureView, to participantId: String) {
        view.setRendererParticipantLabel(participantId)
        participantViewAssignments[participantId] = view
    }

    /// One bind/EGL lane per participant during post-renegotiation episodes (actor-isolated mutex).
    private func withParticipantAttachLane<T>(
        participantId: String,
        operation: () async -> T
    ) async -> T {
        let key = participantAssignmentKey(participantId)
        if participantAttachLaneBusyKeys.contains(key) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                participantAttachLaneWaiters[key, default: []].append(continuation)
            }
        }
        participantAttachLaneBusyKeys.insert(key)
        defer {
            participantAttachLaneBusyKeys.remove(key)
            let waiters = participantAttachLaneWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
        return await operation()
    }

    /// Session-map live wrapper bind with Kotlin EGL promotion — the only coordinator-episode attach path.
    private func bindParticipantLiveWrapperFromSessionStore(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String
    ) async -> Bool {
        await withParticipantAttachLane(participantId: participantId) {
            let settlementKey = participantAssignmentKey(participantId)
            if let mappedTrack = await session.androidMappedLiveRemoteCameraTrack(
                connectionId: connectionId,
                participantId: participantId,
                preferFreshFromPeerConnection: false
            ) {
                let warmProbe = ParticipantRendererAttachSnapshot.from(view: view, track: mappedTrack)
                if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                    attachedTrackIsLive: warmProbe.attachedTrackIsLive,
                    hasActiveSink: warmProbe.hasActiveSink,
                    boundTrackSharesRendererSinkWithTarget: warmProbe.boundTrackSharesRendererSinkWithTarget,
                    rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                    rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
                ) {
                    return true
                }
            }
            guard let liveTrack = await resolvedLiveTrackForCoordinatorEpisodeSessionStoreBind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            ),
                  liveTrack.isLiveVideoTrack,
                  let liveTrackId = liveTrack.trackIdIfAvailable,
                  !liveTrackId.isEmpty else {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator episode session-store bind deferred; live wrapper unavailable \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                return false
            }
            if view.hasPendingLiveWrapperRebind() {
                _ = await applyPendingLiveWrapperRebindIfEligible(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: "coordinator-episode-session-store-bind",
                    forceApply: true
                )
                if await participantTileIsMediaReadyForEpisodeClear(
                    view: view,
                    connectionId: connectionId,
                    participantId: participantId,
                    liveTrack: liveTrack
                ) {
                    return true
                }
            }
            if view.attachedTrackIsLive(),
               view.attachedTrackSharesRendererSink(with: liveTrack),
               view.rendererHadConfirmedFirstFrameSinceSinkAttach() {
                return true
            }
            logger.log(
                level: .info,
                message: """
                Coordinator episode session-store EGL bind participant=\(participantId) \
                reason=\(reason) trackId=\(liveTrackId) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            view.rendererDidUpdateLayout()
            guard view.attach(liveTrack) else {
                view.requestPendingLiveWrapperRebind()
                return false
            }
            await session.persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                liveTrack: liveTrack
            )
            await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
            participantCoordinatorSettledKeys.insert(settlementKey)
            postRenegotiationCoordinatorBoundParticipantKeys.insert(settlementKey)
            return true
        }
    }

    private func awaitFirstFrameForParticipantIfNeeded(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String
    ) async {
        if viewRendererHadConfirmedFirstFrame(view)
            || view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
            return
        }
        if await participantTileIsMediaReady(
            view: view,
            connectionId: connectionId,
            participantId: participantId
        ) {
            return
        }
        let settlementKey = participantAssignmentKey(participantId)
        let context = CoordinatorFinalizeParticipantContext(
            participantId: participantId,
            settlementKey: settlementKey,
            view: view,
            awaitingAfterPendingApply: true
        )
        await awaitCoordinatorFinalizeSinkFirstFrame(
            context: context,
            connectionId: connectionId
        )
    }

    /// Event-driven stabilization before episode clear — session-store bind per tile, no coordinator rerun.
    private func stabilizeEpisodeForClear(
        participantIds: [String],
        connectionId: String
    ) async -> Bool {
        await ensureViewsAssignedForCoordinatorParticipants(
            participantIds: participantIds,
            connectionId: connectionId
        )
        let maxPasses = max(participantIds.count * 2, 2)
        for passIndex in 1 ... maxPasses {
            var attemptedBind = false
            for participantId in participantIds {
                guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                    continue
                }
                guard let assignmentKey = assignedParticipantKey(matching: participantId),
                      let view = participantViewAssignments[assignmentKey] else {
                    continue
                }
                if await participantTileIsMediaReadyForEpisodeClear(
                    view: view,
                    connectionId: connectionId,
                    participantId: participantId
                ) {
                    continue
                }
                attemptedBind = true
                _ = await bindParticipantLiveWrapperFromSessionStore(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: "coordinator-episode-stabilize-pass-\(passIndex)"
                )
                await awaitFirstFrameForParticipantIfNeeded(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId
                )
            }
            if await coordinatorParticipantsAllMediaReady(
                participantIds: participantIds,
                connectionId: connectionId
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator episode stabilization complete pass=\(passIndex)/\(maxPasses) \
                    connection=\(connectionId)
                    """
                )
                return true
            }
            if !attemptedBind {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator episode stabilization stalled pass=\(passIndex)/\(maxPasses) \
                    connection=\(connectionId)
                    """
                )
                return false
            }
        }
        return false
    }

    /// Single attach owner per participant: coalesce duplicate attach requests into one follow-up.
    private func performParticipantVideoAttach(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String
    ) async -> Bool {
        if reason == "post-renegotiation-first-frame-reconcile",
           view.rendererEverConfirmedFirstFrameForAttachedTrack()
            || view.rendererHadConfirmedFirstFrameSinceSinkAttach() {
            logger.log(
                level: .info,
                message: "Skipping post-renegotiation first-frame reconcile; tile already confirmed first frame participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            return true
        }
        let settlementKey = participantAssignmentKey(participantId)
        let episodeActive = isPostRenegotiationAttachEpisodeActive(for: connectionId)
        if AndroidGroupParticipantRendererAttachPolicy.coordinatorEpisodeRequiresSessionStoreEglBind(
            postRenegotiationEpisodeActive: episodeActive,
            attachReason: reason
        ) {
            return await bindParticipantLiveWrapperFromSessionStore(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: reason
            )
        }
        let liveTrackForStableProbe = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        )
        // Coordinator passes run after SFU wrapper rotation; the connection map can still reference
        // the disposed Java wrapper while the live PC receiver is already available.
        let liveTrackForSinkOnlyEpisodeAttach = AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason(reason)
            ? await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
            : nil
        let probeTrack = liveTrackForSinkOnlyEpisodeAttach ?? liveTrackForStableProbe
        let stableProbe = probeTrack.map {
            ParticipantRendererAttachSnapshot.from(view: view, track: $0)
        } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
            hasActiveSink: view.hasActiveSink(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
            attachedTrackIsLive: view.attachedTrackIsLive()
        )
        if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: stableProbe.attachedTrackIsLive,
            hasActiveSink: stableProbe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: stableProbe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        ) {
            logger.log(
                level: .info,
                message: "Skipping participant video attach; renderer already rendering smoothly participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            return true
        }
        if AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason(reason),
           AndroidGroupParticipantRendererAttachPolicy.participantRendererStillDeliveringRecentFramesOnStaleWrapper(
            attachedTrackIsLive: view.attachedTrackIsLive(),
            hasActiveSink: stableProbe.hasActiveSink || view.hasActiveSink(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack()
           ) {
            view.requestPendingLiveWrapperRebind()
            logger.log(
                level: .info,
                message: """
                Skipping coordinator sink-only attach; stale wrapper still delivering recent frames \
                participant=\(participantId) reason=\(reason) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return true
        }
        if AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason(reason),
           !episodeActive,
           let liveTrack = liveTrackForSinkOnlyEpisodeAttach ?? liveTrackForStableProbe,
           liveTrack.isLiveVideoTrack,
           AndroidGroupParticipantRendererAttachPolicy.coordinatorSettlementPrefersSinkOnlyLiveWrapperRebind(
            attachedTrackId: view.attachedTrackId(),
            mappedLiveTrackId: liveTrack.trackIdIfAvailable,
            attachedTrackIsLive: stableProbe.attachedTrackIsLive,
            hasActiveSink: stableProbe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: stableProbe.boundTrackSharesRendererSinkWithTarget
           ) {
            logger.log(
                level: .info,
                message: """
                Coordinator episode using sink-only live wrapper rebind participant=\(participantId) \
                reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            let didRebind = await rebindParticipantRendererSinkIfNeeded(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: reason,
                forceLiveWrapperRecovery: true
            )
            if didRebind {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            }
            if AndroidGroupParticipantRendererAttachPolicy.isCoordinatorSettlementAttachReason(reason),
               didRebind {
                coordinatorSettlementSinkOnlySucceededKeys.insert(settlementKey)
            }
            if await participantTileIsMediaReady(
                view: view,
                connectionId: connectionId,
                participantId: participantId,
                liveTrack: liveTrack
            ) {
                if AndroidGroupParticipantRendererAttachPolicy.isCoordinatorSettlementAttachReason(reason) {
                    coordinatorSettlementSinkOnlySucceededKeys.insert(settlementKey)
                }
                return true
            }
            return didRebind
        }
        if AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            reason,
            episodeActive: isPostRenegotiationAttachEpisodeActive(for: connectionId)
        ) {
            logger.log(
                level: .info,
                message: "Suppressed participant video attach during post-renegotiation episode participant=\(participantId) reason=\(reason)"
            )
            notePostRenegotiationEpisodeParticipant(participantId, connectionId: connectionId)
            if !postRenegotiationCoordinatorInFlight {
                schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
            } else {
                logger.log(
                    level: .info,
                    message: """
                    Skipped coordinator rerun for suppressed in-flight attach participant=\(participantId) \
                    reason=\(reason)
                    """
                )
            }
            return false
        }
        let key = participantAssignmentKey(participantId)
        if participantVideoAttachInFlightKeys.contains(key) {
            participantVideoAttachCoalescedKeys.insert(key)
            logger.log(
                level: .info,
                message: "Coalesced duplicate participant video attach participant=\(participantId) reason=\(reason)"
            )
            return false
        }
        participantVideoAttachInFlightKeys.insert(key)
        defer {
            participantVideoAttachInFlightKeys.remove(key)
            if participantVideoAttachCoalescedKeys.remove(key) != nil {
                Task { [weak self] in
                    guard let self else { return }
                    let didAttach = await self.performParticipantVideoAttach(
                        participantId: participantId,
                        view: view,
                        connectionId: connectionId,
                        reason: "coalesced-\(reason)"
                    )
                    if didAttach {
                        await self.recordAttachedTrack(
                            connectionId: connectionId,
                            participantId: participantId
                        )
                    }
                }
            }
        }
        logger.log(
            level: .info,
            message: "Android participant video attach begin participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())"
        )
        let didAttach = await session.renderRemoteVideoForParticipant(
            to: view,
            connectionId: connectionId,
            participantId: participantId,
            preferFreshPeerConnectionTrack: AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
                forAttachReason: reason,
                coordinatorSettledParticipant: participantCoordinatorSettledKeys.contains(settlementKey)
                    || reason == "inbound-render-recovery",
                postRenegotiationEpisodeActive: episodeActive
            )
        )
        logger.log(
            level: didAttach ? .info : .warning,
            message: "Android participant video attach end participant=\(participantId) reason=\(reason) didAttach=\(didAttach) diagnostics=\(view.rendererAttachDiagnosticSummary())"
        )
        if didAttach {
            let key = participantAssignmentKey(participantId)
            let coordinatorAttachReason = reason == "post-renegotiation-coordinator"
                || reason == "post-renegotiation-grid-layout"
                || reason == "post-renegotiation-first-frame-reconcile"
                || reason == "coordinator-settlement"
                || reason == "grid-layout-reattach"
            if coordinatorAttachReason {
                // First frame is async; ownership must survive sibling attach and transient
                // attached_track_not_live probes until track id or roster ownership changes.
                participantCoordinatorSettledKeys.insert(key)
                postRenegotiationCoordinatorBoundParticipantKeys.insert(key)
            }
            if view.hasActiveSink() {
                if reason == "inbound-render-recovery" {
                    let storedTrack = await session.androidMappedLiveRemoteCameraTrack(
                        connectionId: connectionId,
                        participantId: participantId,
                        preferFreshFromPeerConnection: false
                    )
                    let sharesSink = storedTrack.map {
                        view.attachedTrackSharesRendererSink(with: $0)
                    } ?? false
                    if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                        attachedTrackIsLive: view.attachedTrackIsLive(),
                        hasActiveSink: view.hasActiveSink(),
                        boundTrackSharesRendererSinkWithTarget: sharesSink,
                        rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                        rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
                    ) {
                        participantRendererRecoveryIssuedKeys.remove(key)
                    }
                } else {
                    participantRendererRecoveryIssuedKeys.remove(key)
                }
            }
        }
        return didAttach
    }

    /// Starts consuming the session's call state and participant track streams.
    public func start() async {
        guard stateStreamTask == nil else {
            logger.log(level: .warning, message: "AndroidVideoCallController.start() called while already running; ignoring")
            await syncWithCurrentState(reason: "start-already-running")
            return
        }
        isRunning = true
        logger.log(level: .info, message: "AndroidVideoCallController starting")
        startLocalScreenShareStateObservation()
        startRemoteScreenTrackObservation()
        startParticipantTrackObservation()
        startInboundVideoFlowObservation()
        startPostRenegotiationAttachEpisodeObservation()
        startSfuGroupSignalingStableObservation()
        stateStreamTask = Task { [weak self] in
            guard let self else { return }

            var stateStream: AsyncStream<CallStateMachine.State>?
            while !Task.isCancelled {
                if let stream = await self.session.callState._currentCallStream.last {
                    stateStream = stream
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let stateStream else {
                logger.log(level: .error, message: "No call state stream available; cannot observe call state")
                return
            }

            let bootstrapState = await self._currentCallState
            if let current = await self.session.callState.currentState,
               current != bootstrapState {
                logger.log(level: .info, message: "AndroidVideoCallController bootstrapping state: \(current)")
                await self.handleObservedState(current)
            }

            for await state in stateStream {
                let currentState = await self._currentCallState
                guard state != currentState else { continue }
                logger.log(level: .info, message: "AndroidVideoCallController observed state: \(state)")
                await self.handleObservedState(state)
            }
        }
    }

    private func syncWithCurrentState(reason: String) async {
        guard let state = await session.callState.currentState else {
            logger.log(level: .debug, message: "AndroidVideoCallController sync skipped (\(reason)): no current state")
            return
        }
        logger.log(level: .info, message: "AndroidVideoCallController syncing with state (\(reason)): \(state)")
        await handleObservedState(state)
    }

    private func handleObservedState(_ state: CallStateMachine.State) async {
        logger.log(level: .info, message: "AndroidVideoCallController handling state: \(state)")
        await setCurrentCallState(state)
        await videoCallDelegate?.deliverCallState(state)

        switch state {
        case .waiting:
            break
        case .ready(let call):
            await setCurrentCall(call)
        case .connecting(let direction, let call):
            await setCurrentCall(call)
            switch direction {
            case .inbound(let type), .outbound(let type):
                switch type {
                case .voice:
                    break
                case .video:
                    await upgradedVideo(true)
                    await self.createPreviewView()
                }
            }
        case .connected(let direction, let call):
            await setCurrentCall(call)

            switch direction {
            case .inbound(let type), .outbound(let type):
                switch type {
                case .voice:
                    break
                case .video:
                    await self.createPreviewView()
                    await self.createSampleView()
                }
            }
        case .held:
            break
        case .ended:
            markCallEndedLocally()
        case .failed(_, _, let errorMessage):
            await videoCallDelegate?.passErrorMessage(errorMessage)
            markCallEndedLocally()
        case .callAnsweredAuxDevice:
            markCallEndedLocally()
        }
    }

    private func setCurrentCall(_ call: Call) async {
        currentCall = call
    }

    private func setCurrentCallState(_ state: CallStateMachine.State) async {
        currentCallState = state
    }

    private func upgradedVideo(_ shouldUpgrade: Bool) async {
        self.upgradedToVideo = shouldUpgrade
    }

    public func stop() async {
        markCallEndedLocally()
    }

    // MARK: - Actions

    public func endCall() async {
        let call = self.currentCall
        let session = self.session

        // Dismiss call UI before any WebRTC/camera work. Android renderer and camera
        // teardown can block long enough to trip input ANRs when awaited from UI actions.
        markCallEndedLocally()
        await videoCallDelegate?.endedCall(true)

        Task.detached(priority: .userInitiated) {
            guard let call else {
                await session.releaseLocalMediaResourcesForCallEnding(call: nil)
                await session.shutdown(with: nil)
                return
            }

            await session.releaseLocalMediaResourcesForCallEnding(call: call)
            do {
                let transport = try await session.requireTransport()
                try await transport.didEnd(call: call, endState: CallStateMachine.EndState.userInitiated)
            } catch {
                // Continue with local shutdown even if the transport is already gone.
            }
            await session.shutdown(with: call)
        }
    }

    public func muteAudio() async {
        await setAudioMuted(!isMutingAudio)
    }

    public func setAudioMuted(_ muted: Bool) async {
        guard let callId = self.currentCall?.sharedCommunicationId else {
            logger.log(level: .warning, message: "setAudioMuted(\(muted)) ignored; no current call on AndroidVideoCallController")
            return
        }
        do {
            try await self.session.setAudioTrack(isEnabled: !muted, connectionId: callId)
            isMutingAudio = muted
        } catch {
            logger.log(level: .error, message: "setAudioMuted(\(muted)) failed for connection \(callId): \(error)")
        }
    }

    public func muteVideo() async {
        await setVideoMuted(!isMutingVideo)
    }

    public func setVideoMuted(_ muted: Bool) async {
        guard let callId = self.currentCall?.sharedCommunicationId else {
            logger.log(level: .warning, message: "setVideoMuted(\(muted)) ignored; no current call on AndroidVideoCallController")
            return
        }
        isMutingVideo = muted
        await self.session.setVideoTrack(isEnabled: !muted, connectionId: callId)
    }

    // MARK: - Screen Share Actions

    public func startScreenShare(target: ScreenShareTarget) async {
        await startScreenShare(target: target, options: ScreenShareOptions())
    }

    public func startScreenShare(target: ScreenShareTarget, options: ScreenShareOptions) async {
        _ = await startScreenShareAndReport(target: target, options: options)
    }

    public func startScreenShareAndReport(target: ScreenShareTarget, options: ScreenShareOptions) async -> Bool {
        guard let connectionId = currentCall?.sharedCommunicationId else {
            logger.log(level: .warning, message: "startScreenShare: no active connection")
            return false
        }
        do {
            try await session.addScreenTrackToStream(target: target, options: options, connectionId: connectionId)
            return true
        } catch {
            logger.log(level: .error, message: "Failed to start screen share: \(error)")
            await videoCallDelegate?.passErrorMessage(error.localizedDescription)
            return false
        }
    }

    public func stopScreenShare() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.removeScreenTrackFromStream(connectionId: connectionId)
    }

    // MARK: - Local Screen Share State Observation

    private func startLocalScreenShareStateObservation() {
        guard localScreenShareStateTask == nil else { return }
        localScreenShareStateTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.session.localScreenShareStateStream()
            for await isSharing in stream {
                guard !Task.isCancelled else { break }
                await self.videoCallDelegate?.screenShareDidChange(isSharing: isSharing)
            }
        }
    }

    private func stopLocalScreenShareStateObservation() {
        localScreenShareStateTask?.cancel()
        localScreenShareStateTask = nil
    }

    // MARK: - Remote Screen Track Observation

    private func startRemoteScreenTrackObservation() {
        guard screenTrackStreamTask == nil else { return }
        screenTrackStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.remoteScreenTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.handleRemoteScreenTrackEvent(event)
            }
        }
    }

    private func stopRemoteScreenTrackObservation() {
        screenTrackStreamTask?.cancel()
        screenTrackStreamTask = nil
    }

    private func handleRemoteScreenTrackEvent(_ event: RemoteScreenTrackEvent) async {
        if event.isActive {
            // Stale SFU renegotiation can replay an activation after the sharer already stopped;
            // require a live mapped track so the screen UI is not re-activated for a zombie mid.
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
            logger.log(level: .info, message: "Remote screen share started from participant=\(event.participantId)")
            if let view = screenView,
               let previousParticipantId = activeRemoteScreenShareParticipantId,
               !RTCSession.remoteScreenShareParticipantMatches(previousParticipantId, event.participantId) {
                await session.removeRemoteScreenVideoRenderer(
                    view,
                    connectionId: event.connectionId,
                    participantId: previousParticipantId
                )
            }
            activeRemoteScreenShareParticipantId = event.participantId
            hasActiveRemoteScreenShare = true
            if let view = screenView {
                await session.renderRemoteScreenVideo(
                    to: view,
                    connectionId: event.connectionId,
                    participantId: event.participantId
                )
            }
            await videoCallDelegate?.remoteScreenShareDidChange(participantId: event.participantId, isSharing: true)
        } else {
            logger.log(level: .info, message: "Remote screen share ended from participant=\(event.participantId)")
            // Stop is authoritative: also tear down when a share is visibly active even if
            // participant-id aliases drifted between announce and stop.
            let endedActiveShare = RTCSession.shouldAcceptRemoteScreenShareEnd(
                activeParticipantId: activeRemoteScreenShareParticipantId,
                endedParticipantId: event.participantId
            )
            let hasVisibleScreenShareView = screenView != nil
            guard endedActiveShare || hasActiveRemoteScreenShare || hasVisibleScreenShareView else {
                logger.log(
                    level: .debug,
                    message: "Ignoring remote screen-share removal for inactive participant=\(event.participantId); activeParticipant=\(activeRemoteScreenShareParticipantId ?? "nil")"
                )
                return
            }
            if let view = screenView {
                let rendererParticipantId = activeRemoteScreenShareParticipantId ?? event.participantId
                await session.removeRemoteScreenVideoRenderer(view, connectionId: event.connectionId, participantId: rendererParticipantId)
            }
            activeRemoteScreenShareParticipantId = nil
            hasActiveRemoteScreenShare = false
            await videoCallDelegate?.remoteScreenShareDidChange(participantId: event.participantId, isSharing: false)
        }
    }

    // MARK: - Remote Participant Track Observation (Group Calls)

    private func startParticipantTrackObservation() {
        guard participantTrackStreamTask == nil else { return }
        participantTrackStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.remoteParticipantTrackStream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.handleParticipantTrackEvent(event)
            }
        }
    }

    private func stopParticipantTrackObservation() {
        participantTrackStreamTask?.cancel()
        participantTrackStreamTask = nil
    }

    private func startInboundVideoFlowObservation() {
        guard inboundVideoFlowStreamTask == nil else { return }
        if isGroupCall,
           let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            Task { [session] in
                await session.startInboundVideoFlowSamplerIfNeeded(connectionId: raw)
            }
        }
        inboundVideoFlowStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await session.inboundVideoFlowUpdateStream()
            for await flow in stream {
                guard !Task.isCancelled else { break }
                await self.checkParticipantRendererRecoveryIfNeeded(inboundFlow: flow)
            }
        }
    }

    private func stopInboundVideoFlowObservation() {
        inboundVideoFlowStreamTask?.cancel()
        inboundVideoFlowStreamTask = nil
        if let raw = currentCall?.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            Task { [session] in
                await session.stopInboundVideoFlowSampler(connectionId: raw)
            }
        }
    }

    private func startPostRenegotiationAttachEpisodeObservation() {
        guard postRenegotiationAttachEpisodeStreamTask == nil else { return }
        postRenegotiationAttachEpisodeStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.session.postSfuRenegotiationAttachEpisodeStream()
            for await episode in stream {
                guard !Task.isCancelled else { break }
                await self.handlePostRenegotiationAttachEpisode(episode)
            }
        }
    }

    private func stopPostRenegotiationAttachEpisodeObservation() {
        postRenegotiationAttachEpisodeStreamTask?.cancel()
        postRenegotiationAttachEpisodeStreamTask = nil
    }

    private func startSfuGroupSignalingStableObservation() {
        guard sfuGroupSignalingStableStreamTask == nil else { return }
        sfuGroupSignalingStableStreamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.session.sfuGroupSignalingStableStream()
            for await connectionId in stream {
                guard !Task.isCancelled else { break }
                await self.handleSfuGroupSignalingBecameStable(connectionId: connectionId)
            }
        }
    }

    private func stopSfuGroupSignalingStableObservation() {
        sfuGroupSignalingStableStreamTask?.cancel()
        sfuGroupSignalingStableStreamTask = nil
    }

    private func isPostRenegotiationAttachEpisodeActive(for connectionId: String) -> Bool {
        guard let episodeConnectionId = postRenegotiationEpisodeConnectionId else { return false }
        return episodeConnectionId == connectionId.normalizedConnectionId
            && !postRenegotiationEpisodeParticipantIds.isEmpty
    }

    private func notePostRenegotiationEpisodeParticipant(_ participantId: String, connectionId: String) {
        let participantKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        let wasKnown = postRenegotiationEpisodeParticipantIds.contains { candidate in
            candidate == participantId
                || (!participantKey.isEmpty
                    && RTCSession.conferenceParticipantIdentityKey(candidate) == participantKey)
        }
        postRenegotiationEpisodeConnectionId = connectionId.normalizedConnectionId
        postRenegotiationEpisodeParticipantIds.insert(participantId)
        guard !wasKnown, postRenegotiationCoordinatorFinalizeInProgress else { return }
        cancelCoordinatorFinalizeMediaReadyWaits(
            reason: "episode-participant-added participant=\(participantId)"
        )
        postRenegotiationCoordinatorRerunNeeded = true
    }

    private func handlePostRenegotiationAttachEpisode(_ episode: PostSfuRenegotiationAttachEpisode) async {
        guard isGroupCall else { return }
        let previousParticipantIds = postRenegotiationEpisodeParticipantIds
        postRenegotiationEpisodeConnectionId = episode.connectionId.normalizedConnectionId
        postRenegotiationEpisodeParticipantIds.formUnion(episode.participantIds)
        let participantSetGrew = !Set(episode.participantIds).isSubset(of: previousParticipantIds)
        logger.log(
            level: .info,
            message: "Android post-SFU renegotiation attach episode participants=\(Array(postRenegotiationEpisodeParticipantIds).sorted().joined(separator: ",")) connection=\(episode.connectionId)"
        )
        for participantId in postRenegotiationEpisodeParticipantIds {
            await ensureParticipantViewAssigned(participantId: participantId, connectionId: episode.connectionId)
        }
        if postRenegotiationCoordinatorFinalizeInProgress, participantSetGrew {
            cancelCoordinatorFinalizeMediaReadyWaits(
                reason: "episode-participants-expanded participants=\(episode.participantIds.joined(separator: ","))"
            )
            postRenegotiationCoordinatorRerunNeeded = true
            return
        }
        if await shouldSkipPostRenegotiationAttachEpisodeCoordinator(
            participantIds: episode.participantIds,
            connectionId: episode.connectionId
        ) {
            logger.log(
                level: .info,
                message: """
                Skipping post-renegotiation attach coordinator; episode participants already settled \
                participants=\(episode.participantIds.sorted().joined(separator: ",")) connection=\(episode.connectionId)
                """
            )
            return
        }
        requestPostRenegotiationAttachCoordinator(connectionId: episode.connectionId)
    }

    private func shouldSkipPostRenegotiationAttachEpisodeCoordinator(
        participantIds: [String],
        connectionId: String
    ) async -> Bool {
        guard !participantIds.isEmpty else { return false }
        for participantId in participantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                return false
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            guard participantCoordinatorSettledKeys.contains(settlementKey) else {
                return false
            }
            guard await shouldSkipPostRenegotiationCoordinatorAttach(
                participantId: participantId,
                settlementKey: settlementKey,
                view: view,
                connectionId: connectionId
            ) else {
                return false
            }
        }
        return true
    }

    private func requestPostRenegotiationAttachCoordinator(connectionId: String) {
        guard isGroupCall else { return }
        if postRenegotiationCoordinatorInFlight {
            postRenegotiationCoordinatorRerunNeeded = true
            logger.log(
                level: .info,
                message: "Queued post-renegotiation attach coordinator rerun connection=\(connectionId.normalizedConnectionId)"
            )
            return
        }
        postRenegotiationCoordinatorInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.runPostRenegotiationAttachCoordinatorTask(connectionId: connectionId)
        }
    }

    private func schedulePostRenegotiationAttachCoordinator(connectionId: String) {
        requestPostRenegotiationAttachCoordinator(connectionId: connectionId)
    }

    private func runPostRenegotiationAttachCoordinatorTask(connectionId: String) async {
        defer { postRenegotiationCoordinatorInFlight = false }
        let norm = connectionId.normalizedConnectionId
        repeat {
            repeat {
                postRenegotiationCoordinatorRerunNeeded = false
                postRenegotiationCoordinatorPassIndex += 1
                await runPostRenegotiationAttachCoordinatorIfReady(connectionId: connectionId)
                guard isPostRenegotiationAttachEpisodeActive(for: norm) else { return }
                if await session.shouldDeferSfuGroupParticipantVideoAttach(for: norm) {
                    logger.log(
                        level: .info,
                        message: "Pausing post-renegotiation attach coordinator until SFU signaling settles connection=\(norm)"
                    )
                    return
                }
            } while postRenegotiationCoordinatorRerunNeeded
                && isPostRenegotiationAttachEpisodeActive(for: norm)

            guard isPostRenegotiationAttachEpisodeActive(for: norm),
                  !(await session.shouldDeferSfuGroupParticipantVideoAttach(for: norm)) else {
                return
            }
            let episodeCleared = await finalizePostRenegotiationAttachEpisode(connectionId: norm)
            if episodeCleared {
                return
            }
        } while postRenegotiationCoordinatorRerunNeeded
            && isPostRenegotiationAttachEpisodeActive(for: norm)
    }

    @discardableResult
    private func finalizePostRenegotiationAttachEpisode(connectionId: String) async -> Bool {
        postRenegotiationCoordinatorFinalizeInProgress = true
        coordinatorFinalizePendingRebindAppliedKeys.removeAll()
        coordinatorFinalizeMediaReadyConfirmedKeys.removeAll()
        defer {
            postRenegotiationCoordinatorFinalizeInProgress = false
            cancelCoordinatorFinalizeMediaReadyWaits(reason: "finalize-complete")
        }
        let participantIds = await coordinatorAttachParticipantIds(connectionId: connectionId)
        await ensureViewsAssignedForCoordinatorParticipants(
            participantIds: participantIds,
            connectionId: connectionId
        )
        await attachUnsettledCoordinatorParticipantsIfNeeded(
            participantIds: participantIds,
            connectionId: connectionId,
            reason: "coordinator-settlement"
        )
        await applyPendingLiveWrapperRebindsForParticipants(
            participantIds: participantIds,
            connectionId: connectionId,
            reason: "coordinator-finalize-pending-wrapper",
            forceApply: true
        )
        await ensureCoordinatorParticipantsMediaReady(
            participantIds: participantIds,
            connectionId: connectionId
        )
        if postRenegotiationCoordinatorRerunNeeded {
            logger.log(
                level: .info,
                message: """
                Deferring post-renegotiation episode clear; participant set changed during finalize \
                connection=\(connectionId)
                """
            )
            return false
        }
        await reconcileFinalizeConfirmedParticipantsBeforeProceeding(
            participantIds: participantIds,
            connectionId: connectionId
        )
        if !(await coordinatorParticipantsAllMediaReady(
            participantIds: participantIds,
            connectionId: connectionId
        )) {
            if await stabilizeEpisodeForClear(
                participantIds: participantIds,
                connectionId: connectionId
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator episode cleared after stabilization without coordinator rerun \
                    connection=\(connectionId)
                    """
                )
            } else {
                postRenegotiationCoordinatorRerunNeeded = true
                logger.log(
                    level: .info,
                    message: """
                    Deferring post-renegotiation episode clear; final media-ready sweep found \
                    rotated wrapper connection=\(connectionId)
                    """
                )
                return false
            }
        }

        logger.log(
            level: .info,
            message: "Android post-renegotiation attach coordinator end connection=\(connectionId)"
        )
        clearPostRenegotiationAttachEpisode()
        await recoverStalledParticipantRenderersAfterCoordinatorEpisode(connectionId: connectionId)
        await videoCallDelegate?.remoteParticipantTilesDidChange()
        return true
    }

    private func coordinatorParticipantRequiresVideoBinding(
        participantId: String,
        connectionId: String
    ) async -> Bool {
        if await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        ) != nil {
            return true
        }
        let normalizedConnectionId = connectionId.normalizedConnectionId
        if let connection = await session.connectionManager.findConnection(with: normalizedConnectionId) {
            let participantKey = participantAssignmentKey(participantId)
            for (mappedParticipantId, _) in connection.remoteVideoTracksByParticipantId {
                if mappedParticipantId == participantId
                    || participantAssignmentKey(mappedParticipantId) == participantKey {
                    return true
                }
            }
        }
        let eventKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        return postRenegotiationEpisodeParticipantIds.contains { candidate in
            candidate == participantId
                || (!eventKey.isEmpty
                    && RTCSession.conferenceParticipantIdentityKey(candidate) == eventKey)
        }
    }

    private func coordinatorParticipantsAllMediaReady(
        participantIds: [String],
        connectionId: String
    ) async -> Bool {
        for participantId in participantIds {
            let shouldSurface = await shouldSurfaceParticipantTrack(
                connectionId: connectionId,
                participantId: participantId
            )
            let hasAssignedView = assignedParticipantKey(matching: participantId)
                .flatMap { participantViewAssignments[$0] } != nil
            let requiresVideoBinding = await coordinatorParticipantRequiresVideoBinding(
                participantId: participantId,
                connectionId: connectionId
            )
            if AndroidGroupPostRenegotiationAttachCoordinator.coordinatorMediaReadySweepMissingAssignedView(
                shouldSurfaceParticipant: shouldSurface,
                hasAssignedView: hasAssignedView,
                participantRequiresVideoBinding: requiresVideoBinding
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize media-ready final sweep failed; missing assigned view \
                    participant=\(participantId) connection=\(connectionId)
                    """
                )
                return false
            }
            guard shouldSurface else {
                continue
            }
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            if await participantTileIsMediaReadyForEpisodeClear(
                view: view,
                connectionId: connectionId,
                participantId: participantId
            ) {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            if shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
                settlementKey: settlementKey,
                view: view,
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile()
            ) {
                continue
            }
            logger.log(
                level: .info,
                message: """
                Coordinator finalize media-ready final sweep failed participant=\(participantId) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return false
        }
        return true
    }

    /// Session map first, then fresh PC probe — `?? await` is invalid in Swift guard expressions.
    private func resolvedLiveTrackForPostEpisodeSessionStoreBind(
        connectionId: String,
        participantId: String
    ) async -> RTCVideoTrack? {
        if let storedTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        ) {
            return storedTrack
        }
        return await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: true
        )
    }

    /// Post-episode session-store EGL bind when a dead wrapper or deferred pending swap must complete.
    private func bindParticipantLiveWrapperFromSessionStoreAfterEpisode(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String
    ) async -> Bool {
        if view.hasPendingLiveWrapperRebind(),
           await applyPendingLiveWrapperRebindIfEligible(
            participantId: participantId,
            view: view,
            connectionId: connectionId,
            reason: reason,
            forceApply: true
           ),
           await participantTileIsMediaReadyForEpisodeClear(
            view: view,
            connectionId: connectionId,
            participantId: participantId
           ) {
            return true
        }
        guard let liveTrack = await resolvedLiveTrackForPostEpisodeSessionStoreBind(
            connectionId: connectionId,
            participantId: participantId
        ),
              liveTrack.isLiveVideoTrack,
              let liveTrackId = liveTrack.trackIdIfAvailable,
              !liveTrackId.isEmpty else {
            return false
        }
        let probe = ParticipantRendererAttachSnapshot.from(view: view, track: liveTrack)
        if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        ) {
            return true
        }
        logger.log(
            level: .info,
            message: """
            Post-coordinator session-store EGL bind participant=\(participantId) reason=\(reason) \
            trackId=\(liveTrackId) diagnostics=\(view.rendererAttachDiagnosticSummary())
            """
        )
        view.rendererDidUpdateLayout()
        guard view.attach(liveTrack) else {
            view.requestPendingLiveWrapperRebind()
            return false
        }
        let settlementKey = participantAssignmentKey(participantId)
        await session.persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
            connectionId: connectionId,
            participantId: participantId,
            liveTrack: liveTrack
        )
        await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
        postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
        participantCoordinatorSettledKeys.insert(settlementKey)
        participantRendererRecoveryIssuedKeys.remove(settlementKey)
        return true
    }

    /// One-shot sweep after the coordinator episode ends. Aggregate inbound stats cannot identify
    /// which participant stalled; inspect each tile directly.
    private func recoverStalledParticipantRenderersAfterCoordinatorEpisode(connectionId: String) async {
        guard isGroupCall else { return }
        for (participantId, view) in participantViewAssignments {
            let recoveryKey = participantRendererRecoveryKey(participantId)
            participantRendererRecoveryIssuedKeys.remove(recoveryKey)

            guard AndroidGroupPostRenegotiationAttachCoordinator
                .postCoordinatorRecoveryTargetsParticipant(
                    coordinatorSettledParticipant: participantCoordinatorSettledKeys.contains(recoveryKey)
                ) else {
                continue
            }
            if participantAttachLaneBusyKeys.contains(recoveryKey)
                || participantVideoAttachInFlightKeys.contains(recoveryKey) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping post-coordinator participant renderer recovery; attach in flight \
                    participant=\(participantId)
                    """
                )
                continue
            }
            if AndroidGroupPostRenegotiationAttachCoordinator
                .postCoordinatorRecoveryShouldDeferToPendingLiveWrapperRebind(
                    hasPendingLiveWrapperRebind: view.hasPendingLiveWrapperRebind()
                ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping post-coordinator participant renderer recovery; pending live-wrapper \
                    rebind already queued participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                let settlementKey = participantAssignmentKey(participantId)
                if await tryApplyPostCoordinatorPendingLiveWrapperRebind(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: "post-coordinator-pending-wrapper-apply"
                ) {
                    postCoordinatorPendingWrapperApplyParticipantKeys.remove(settlementKey)
                } else if view.hasPendingLiveWrapperRebind() {
                    postCoordinatorPendingWrapperApplyParticipantKeys.insert(settlementKey)
                    logger.log(
                        level: .info,
                        message: """
                        Deferred post-coordinator pending wrapper apply until stale tail stops \
                        participant=\(participantId) \
                        diagnostics=\(view.rendererAttachDiagnosticSummary())
                        """
                    )
                }
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy
                .participantRendererStillDeliveringRecentFramesOnStaleWrapper(
                    attachedTrackIsLive: view.attachedTrackIsLive(),
                    hasActiveSink: view.hasActiveSink(),
                    rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                    rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack()
                ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping post-coordinator participant renderer recovery; stale wrapper still \
                    delivering recent frames participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }

            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                continue
            }
            let liveTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
            if let liveTrack {
                let probe = ParticipantRendererAttachSnapshot.from(view: view, track: liveTrack)
                if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                    attachedTrackIsLive: probe.attachedTrackIsLive,
                    hasActiveSink: probe.hasActiveSink,
                    boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                    rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                    rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
                ) {
                    continue
                }

                if AndroidGroupParticipantRendererAttachPolicy
                    .shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
                        tileAttachedTrackIsLive: view.attachedTrackIsLive(),
                        tileHasActiveSink: view.hasActiveSink(),
                        probeHasActiveSink: probe.hasActiveSink,
                        probeBoundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                        rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                        rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
                    ) {
                    continue
                }
                let needsLiveWrapperRebind = AndroidGroupPostRenegotiationAttachCoordinator
                    .participantNeedsLiveWrapperSinkRebind(
                        attachedTrackId: view.attachedTrackId(),
                        mappedLiveTrackId: liveTrack.trackIdIfAvailable,
                        hasActiveSink: probe.hasActiveSink || view.hasActiveSink(),
                        boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                        attachedTrackIsLive: view.attachedTrackIsLive()
                    )
                let staleAfterCoordinator = view.rendererEverConfirmedFirstFrameForAttachedTrack()
                    && view.rendererFramesStaleWhileBound(staleThresholdMs: 2_000)
                guard needsLiveWrapperRebind || staleAfterCoordinator else { continue }

                logger.log(
                    level: .info,
                    message: """
                    Post-coordinator participant renderer recovery participant=\(participantId) \
                    deadWrapper=\(needsLiveWrapperRebind) staleAfterCoordinator=\(staleAfterCoordinator) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                let didRecover = await bindParticipantLiveWrapperFromSessionStoreAfterEpisode(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: needsLiveWrapperRebind
                        ? "post-coordinator-dead-wrapper"
                        : "post-coordinator-stale-after-episode"
                )
                if didRecover {
                    await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                }
                continue
            }
            if view.attachedTrackId() != nil || view.rendererEverConfirmedFirstFrameForAttachedTrack() {
                _ = await bindParticipantLiveWrapperFromSessionStoreAfterEpisode(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: "post-coordinator-no-session-map-track"
                )
            }
        }
        await applyPostCoordinatorDeferredPendingWrapperRebinds(connectionId: connectionId)
    }

    /// Applies queued pending live-wrapper rebind after coordinator end without competing with stale tail.
    private func tryApplyPostCoordinatorPendingLiveWrapperRebind(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String
    ) async -> Bool {
        guard view.hasPendingLiveWrapperRebind() else { return false }
        let staleStillPainting = AndroidGroupParticipantRendererAttachPolicy
            .participantRendererStillDeliveringRecentFramesOnStaleWrapper(
                attachedTrackIsLive: view.attachedTrackIsLive(),
                hasActiveSink: view.hasActiveSink(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack()
            )
        guard AndroidGroupPostRenegotiationAttachCoordinator
            .postCoordinatorPendingWrapperApplyShouldRetryWhenStaleTailStopped(
                staleWrapperStillDeliveringRecentFrames: staleStillPainting
            ) else {
            return false
        }
        if await applyPendingLiveWrapperRebindIfEligible(
            participantId: participantId,
            view: view,
            connectionId: connectionId,
            reason: reason,
            forceApply: false
        ) {
            return true
        }
        guard let liveTrack = await resolvedLiveTrackForPostEpisodeSessionStoreBind(
            connectionId: connectionId,
            participantId: participantId
        ),
              liveTrack.isLiveVideoTrack else {
            return false
        }
        return await applyPendingLiveWrapperRebindIfEligible(
            participantId: participantId,
            view: view,
            connectionId: connectionId,
            reason: "\(reason)-fresh-pc",
            forceApply: true
        )
    }

    private func applyPostCoordinatorDeferredPendingWrapperRebinds(connectionId: String) async {
        guard !postCoordinatorPendingWrapperApplyParticipantKeys.isEmpty else { return }
        var completedKeys: [String] = []
        for settlementKey in postCoordinatorPendingWrapperApplyParticipantKeys {
            guard participantCoordinatorSettledKeys.contains(settlementKey),
                  let participantId = participantViewAssignments.first(where: {
                      participantRendererRecoveryKey($0.key) == settlementKey
                  })?.key,
                  let view = participantViewAssignments[participantId] else {
                continue
            }
            if await tryApplyPostCoordinatorPendingLiveWrapperRebind(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "post-coordinator-pending-wrapper-deferred"
            ) {
                completedKeys.append(settlementKey)
            }
        }
        for key in completedKeys {
            postCoordinatorPendingWrapperApplyParticipantKeys.remove(key)
        }
    }

    private func handleSfuGroupSignalingBecameStable(connectionId: String) async {
        guard isGroupCall,
              isPostRenegotiationAttachEpisodeActive(for: connectionId) else {
            return
        }
        schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
    }

    /// Session map first, then SFU map refresh + fresh PC when the attached wrapper ENDed during an episode.
    private func resolvedLiveTrackForCoordinatorEpisodeSessionStoreBind(
        connectionId: String,
        participantId: String,
        view: AndroidSampleCaptureView
    ) async -> RTCVideoTrack? {
        let normalizedConnectionId = connectionId.normalizedConnectionId
        func storedLiveTrack() async -> RTCVideoTrack? {
            guard let storedTrack = await session.androidMappedLiveRemoteCameraTrack(
                connectionId: connectionId,
                participantId: participantId,
                preferFreshFromPeerConnection: false
            ),
                  storedTrack.isLiveVideoTrack,
                  let storedTrackId = storedTrack.trackIdIfAvailable,
                  !storedTrackId.isEmpty else {
                return nil
            }
            return storedTrack
        }
        if let storedTrack = await storedLiveTrack() {
            return storedTrack
        }
        let staleDeliversRecentFrames = AndroidGroupParticipantRendererAttachPolicy
            .participantRendererStillDeliveringRecentFramesOnStaleWrapper(
                attachedTrackIsLive: view.attachedTrackIsLive(),
                hasActiveSink: view.hasActiveSink(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack()
            )
        guard isPostRenegotiationAttachEpisodeActive(for: normalizedConnectionId),
              AndroidGroupParticipantRendererAttachPolicy
                .coordinatorEpisodeAllowsFreshPeerConnectionProbeForDeadAttachedWrapper(
                    postRenegotiationEpisodeActive: true,
                    sessionMapTrackIsLive: false,
                    attachedTrackIsLive: view.attachedTrackIsLive(),
                    rendererStillDeliveringRecentFramesOnStaleWrapper: staleDeliversRecentFrames
                ) else {
            if staleDeliversRecentFrames {
                view.requestPendingLiveWrapperRebind()
                logger.log(
                    level: .info,
                    message: """
                    Deferring coordinator episode fresh PC probe; stale wrapper still delivering recent \
                    frames participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
            }
            return nil
        }
        guard let freshTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: true
        ),
              freshTrack.isLiveVideoTrack,
              let freshTrackId = freshTrack.trackIdIfAvailable,
              !freshTrackId.isEmpty else {
            logger.log(
                level: .info,
                message: """
                Coordinator episode fresh PC probe found no live wrapper \
                participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return nil
        }
        logger.log(
            level: .info,
            message: """
            Coordinator episode fresh PC probe for dead attached wrapper \
            participant=\(participantId) trackId=\(freshTrackId) \
            diagnostics=\(view.rendererAttachDiagnosticSummary())
            """
        )
        return freshTrack
    }

    private func resolveLiveTrackForSinkRebind(
        connectionId: String,
        participantId: String,
        view: AndroidSampleCaptureView
    ) async -> RTCVideoTrack? {
        let normalizedConnectionId = connectionId.normalizedConnectionId
        let storedTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        )
        if let storedTrack,
           storedTrack.isLiveVideoTrack,
           let storedTrackId = storedTrack.trackIdIfAvailable,
           !storedTrackId.isEmpty {
            if view.attachedTrackIsLive(),
               view.attachedTrackSharesRendererSink(with: storedTrack) {
                return storedTrack
            }
            if isPostRenegotiationAttachEpisodeActive(for: normalizedConnectionId) {
                logger.log(
                    level: .debug,
                    message: """
                    Using stored live receiver wrapper during coordinator episode \
                    participant=\(participantId) trackId=\(storedTrackId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                return storedTrack
            }
        }
        if isPostRenegotiationAttachEpisodeActive(for: normalizedConnectionId) {
            if let episodeTrack = await resolvedLiveTrackForCoordinatorEpisodeSessionStoreBind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            ) {
                return episodeTrack
            }
            logger.log(
                level: .info,
                message: """
                Coordinator episode live wrapper unavailable in session map \
                participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return nil
        }
        if let freshTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: true
        ),
           freshTrack.isLiveVideoTrack,
           let freshTrackId = freshTrack.trackIdIfAvailable,
           !freshTrackId.isEmpty {
            return freshTrack
        }
        if let storedTrack,
           storedTrack.isLiveVideoTrack,
           let storedTrackId = storedTrack.trackIdIfAvailable,
           !storedTrackId.isEmpty {
            return storedTrack
        }
        logger.log(
            level: .info,
            message: "Deferred coordinator sink rebind; live receiver wrapper not ready participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
        )
        return nil
    }

    private func resolveFreshLiveTrackForPendingWrapperRebind(
        connectionId: String,
        participantId: String
    ) async -> RTCVideoTrack? {
        if isPostRenegotiationAttachEpisodeActive(for: connectionId.normalizedConnectionId),
           let storedTrack = await session.androidMappedLiveRemoteCameraTrack(
               connectionId: connectionId,
               participantId: participantId,
               preferFreshFromPeerConnection: false
           ),
           storedTrack.isLiveVideoTrack,
           let storedTrackId = storedTrack.trackIdIfAvailable,
           !storedTrackId.isEmpty {
            return storedTrack
        }
        if isPostRenegotiationAttachEpisodeActive(for: connectionId.normalizedConnectionId),
           let freshTrack = await session.androidMappedLiveRemoteCameraTrack(
               connectionId: connectionId,
               participantId: participantId,
               preferFreshFromPeerConnection: true
           ),
           freshTrack.isLiveVideoTrack,
           let freshTrackId = freshTrack.trackIdIfAvailable,
           !freshTrackId.isEmpty {
            return freshTrack
        }
        if isPostRenegotiationAttachEpisodeActive(for: connectionId.normalizedConnectionId) {
            return nil
        }
        if let freshTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: true
        ),
           freshTrack.isLiveVideoTrack,
           let freshTrackId = freshTrack.trackIdIfAvailable,
           !freshTrackId.isEmpty {
            return freshTrack
        }
        if let storedTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        ),
           storedTrack.isLiveVideoTrack,
           let storedTrackId = storedTrack.trackIdIfAvailable,
           !storedTrackId.isEmpty {
            return storedTrack
        }
        logger.log(
            level: .info,
            message: "Deferred pending live wrapper rebind; live receiver wrapper not ready participant=\(participantId)"
        )
        return nil
    }

    private func shouldDeferLiveWrapperSinkRebindWhileStaleHasRecentFrames(
        view: AndroidSampleCaptureView,
        probe: ParticipantRendererAttachSnapshot,
        connectionId: String
    ) -> Bool {
        return AndroidGroupParticipantRendererAttachPolicy
            .shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
                tileAttachedTrackIsLive: view.attachedTrackIsLive(),
                tileHasActiveSink: view.hasActiveSink(),
                probeHasActiveSink: probe.hasActiveSink,
                probeBoundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
            )
    }

    private func reconcileSettledParticipantWrapperSyncIfNeeded(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        settlementKey: String
    ) async -> Bool {
        let liveTrack = await resolveLiveTrackForSinkRebind(
            connectionId: connectionId,
            participantId: participantId,
            view: view
        )
        let probe = liveTrack.map {
            ParticipantRendererAttachSnapshot.from(view: view, track: $0)
        } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
            hasActiveSink: view.hasActiveSink(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
            attachedTrackIsLive: view.attachedTrackIsLive()
        )
        if AndroidGroupParticipantRendererAttachPolicy.shouldSkipSettledParticipantLiveWrapperSyncAfterMapRefresh(
            tileAttachedTrackIsLive: view.attachedTrackIsLive(),
            tileHasActiveSink: view.hasActiveSink(),
            probeHasActiveSink: probe.hasActiveSink,
            probeAttachedTrackIsLive: probe.attachedTrackIsLive,
            probeBoundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        ) {
            if shouldDeferLiveWrapperSinkRebindWhileStaleHasRecentFrames(
                view: view,
                probe: probe,
                connectionId: connectionId
            ) {
                view.requestPendingLiveWrapperRebind()
                logger.log(
                    level: .info,
                    message: """
                    Deferred settled wrapper sync until stale wrapper stalls participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
            } else {
                logger.log(
                    level: .info,
                    message: """
                    Skipping settled wrapper sync; participant already smoothly rendering participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
            }
            return true
        }
        if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        ) {
            return false
        }
        if shouldDeferLiveWrapperSinkRebindWhileStaleHasRecentFrames(
            view: view,
            probe: probe,
            connectionId: connectionId
        ) {
            view.requestPendingLiveWrapperRebind()
            logger.log(
                level: .info,
                message: """
                Deferred settled wrapper sync until stale wrapper stalls participant=\(participantId) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return true
        }
        if !probe.attachedTrackIsLive || !probe.boundTrackSharesRendererSinkWithTarget {
            logger.log(
                level: .info,
                message: """
                Syncing settled participant live wrapper after SFU map refresh participant=\(participantId) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            let didRebind = await rebindParticipantRendererSinkIfNeeded(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "coordinator-settled-wrapper-sync",
                forceLiveWrapperRecovery: true
            )
            if didRebind, !view.hasPendingLiveWrapperRebind() {
                postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
            }
            return didRebind || view.hasPendingLiveWrapperRebind()
        }
        let didRebind = await rebindParticipantRendererSinkIfNeeded(
            participantId: participantId,
            view: view,
            connectionId: connectionId,
            reason: "coordinator-settled-wrapper-sync",
            forceLiveWrapperRecovery: true
        )
        if didRebind, !view.hasPendingLiveWrapperRebind() {
            postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
        }
        return didRebind
    }

    private func hasSiblingSmoothlyRenderingFullAttachThisPass(
        excludingParticipantId participantId: String,
        fullAttachedThisPassKeys: Set<String>
    ) -> Bool {
        for (otherParticipantId, otherView) in participantViewAssignments where otherParticipantId != participantId {
            let otherKey = participantAssignmentKey(otherParticipantId)
            guard fullAttachedThisPassKeys.contains(otherKey) else { continue }
            if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: otherView.attachedTrackIsLive(),
                hasActiveSink: otherView.hasActiveSink(),
                boundTrackSharesRendererSinkWithTarget: otherView.attachedTrackIsLive()
                    && otherView.hasActiveSink(),
                rendererHadConfirmedFirstFrameSinceSinkAttach: otherView.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: otherView.rendererFramesStaleWhileBound()
            ) {
                return true
            }
        }
        return false
    }

    private func rebindParticipantRendererSinkIfNeeded(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String,
        allowWhenAlreadyReboundThisEpisode: Bool = false,
        forceLiveWrapperRecovery: Bool = false
    ) async -> Bool {
        if isPostRenegotiationAttachEpisodeActive(for: connectionId.normalizedConnectionId) {
            return await withParticipantAttachLane(participantId: participantId) {
                await rebindParticipantRendererSinkIfNeededUnserialized(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: reason,
                    allowWhenAlreadyReboundThisEpisode: allowWhenAlreadyReboundThisEpisode,
                    forceLiveWrapperRecovery: forceLiveWrapperRecovery
                )
            }
        }
        return await rebindParticipantRendererSinkIfNeededUnserialized(
            participantId: participantId,
            view: view,
            connectionId: connectionId,
            reason: reason,
            allowWhenAlreadyReboundThisEpisode: allowWhenAlreadyReboundThisEpisode,
            forceLiveWrapperRecovery: forceLiveWrapperRecovery
        )
    }

    private func rebindParticipantRendererSinkIfNeededUnserialized(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String,
        allowWhenAlreadyReboundThisEpisode: Bool = false,
        forceLiveWrapperRecovery: Bool = false
    ) async -> Bool {
        let norm = connectionId.normalizedConnectionId
        if await session.shouldDeferSfuGroupParticipantVideoAttach(for: norm) {
            postRenegotiationCoordinatorRerunNeeded = true
            logger.log(
                level: .info,
                message: "Deferred coordinator sink rebind; SFU signaling still settling participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            return false
        }
        let settlementKey = participantAssignmentKey(participantId)
        let layoutNeedsSinkReconcile = view.rendererLayoutNeedsSinkReconcile()
        if view.hasPendingLiveWrapperRebind() {
            if forceLiveWrapperRecovery,
               !isPostRenegotiationAttachEpisodeActive(for: norm) {
                if await applyPendingLiveWrapperRebindIfEligible(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: reason,
                    forceApply: true
                ) {
                    return true
                }
                return await bindParticipantLiveWrapperFromSessionStoreAfterEpisode(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: reason
                )
            }
            logger.log(
                level: .info,
                message: """
                Skipped coordinator sink rebind; live wrapper swap already deferred participant=\(participantId) \
                reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return true
        }
        guard let liveTrack = await resolveLiveTrackForSinkRebind(
            connectionId: connectionId,
            participantId: participantId,
            view: view
        ) else {
            logger.log(
                level: .info,
                message: "Deferred coordinator sink rebind; live receiver unavailable participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            return false
        }
        guard liveTrack.isLiveVideoTrack,
              let liveTrackId = liveTrack.trackIdIfAvailable,
              !liveTrackId.isEmpty else {
            logger.log(
                level: .info,
                message: "Deferred coordinator sink rebind; live receiver not ready participant=\(participantId) reason=\(reason) trackId=\(liveTrack.trackIdIfAvailable ?? "<unknown>") diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            return false
        }
        let probe = ParticipantRendererAttachSnapshot.from(view: view, track: liveTrack)
        if AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressAlreadyReboundSinkRebind(
            allowWhenAlreadyReboundThisEpisode: allowWhenAlreadyReboundThisEpisode,
            alreadyReboundThisEpisode: postRenegotiationCoordinatorSinkReboundParticipantKeys.contains(settlementKey),
            hasActiveSink: probe.hasActiveSink,
            rendererLayoutNeedsSinkReconcile: layoutNeedsSinkReconcile,
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
            attachedTrackIsLive: probe.attachedTrackIsLive,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget
        ) {
            return false
        }
        guard AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: view.attachedTrackId(),
            mappedLiveTrackId: liveTrack.trackIdIfAvailable,
            hasActiveSink: probe.hasActiveSink || view.hasActiveSink(),
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            attachedTrackIsLive: view.attachedTrackIsLive(),
            rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
            forceLiveWrapperRecovery: forceLiveWrapperRecovery
        ) else {
            logger.log(
                level: .debug,
                message: "Skipped coordinator sink rebind after fresh probe participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            return false
        }
        if shouldDeferLiveWrapperSinkRebindWhileStaleHasRecentFrames(
            view: view,
            probe: probe,
            connectionId: connectionId
        ) {
            view.requestPendingLiveWrapperRebind()
            logger.log(
                level: .info,
                message: """
                Deferred live wrapper rebind until stale wrapper stalls participant=\(participantId) \
                reason=\(reason) trackId=\(liveTrack.trackIdIfAvailable ?? "<unknown>") \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return true
        }
        logger.log(
            level: .info,
            message: """
            Rebinding coordinator-settled participant sink without session attach \
            participant=\(participantId) reason=\(reason) trackId=\(liveTrack.trackIdIfAvailable ?? "<unknown>") \
            diagnostics=\(view.rendererAttachDiagnosticSummary())
            """
        )
        view.rendererDidUpdateLayout()
        let didAttach = view.attach(liveTrack)
        let sharesLiveWrapper = view.attachedTrackSharesRendererSink(with: liveTrack)
        let attachedLiveAfterBind = view.attachedTrackIsLive()
        if didAttach && (sharesLiveWrapper || attachedLiveAfterBind) {
            await session.persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                liveTrack: liveTrack
            )
            await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
        } else if view.hasPendingLiveWrapperRebind() {
            logger.log(
                level: .info,
                message: """
                Deferred live wrapper rebind until stale wrapper stalls participant=\(participantId) \
                reason=\(reason) trackId=\(liveTrack.trackIdIfAvailable ?? "<unknown>") \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
        }
        return (didAttach && (sharesLiveWrapper || attachedLiveAfterBind)) || view.hasPendingLiveWrapperRebind()
    }

    private func applyPendingLiveWrapperRebindIfEligible(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String,
        reason: String,
        forceApply: Bool = false
    ) async -> Bool {
        guard view.hasPendingLiveWrapperRebind() else { return false }
        if !forceApply,
           view.rendererEverConfirmedFirstFrameForAttachedTrack(),
           !view.rendererFramesStaleWhileBound() {
            return false
        }
        guard let liveTrack = await resolveFreshLiveTrackForPendingWrapperRebind(
            connectionId: connectionId,
            participantId: participantId
        ),
              liveTrack.isLiveVideoTrack,
              let liveTrackId = liveTrack.trackIdIfAvailable,
              !liveTrackId.isEmpty else {
            return false
        }
        view.rendererDidUpdateLayout()
        guard view.applyPendingLiveWrapperRebindIfEligible(track: liveTrack, forceApply: forceApply) else {
            return false
        }
        let settlementKey = participantAssignmentKey(participantId)
        if view.attachedTrackSharesRendererSink(with: liveTrack) {
            await session.persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                liveTrack: liveTrack
            )
            await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
            participantRendererRecoveryIssuedKeys.remove(settlementKey)
        }
        logger.log(
            level: .info,
            message: """
            Applied deferred live wrapper rebind participant=\(participantId) reason=\(reason) \
            trackId=\(liveTrack.trackIdIfAvailable ?? "<unknown>") \
            diagnostics=\(view.rendererAttachDiagnosticSummary())
            """
        )
        if view.hasActiveSink() {
            coordinatorFinalizePendingRebindAppliedKeys.insert(settlementKey)
        }
        return view.hasActiveSink()
    }

    /// Rebind using the session-stored live wrapper after pending apply when the attached wrapper
    /// ENDed before the finalize first-frame observer could confirm the current sink generation.
    private func recoverLiveWrapperForPendingApplyFirstFrameWait(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String
    ) async -> Bool {
        if await applyPendingLiveWrapperRebindIfEligible(
            participantId: participantId,
            view: view,
            connectionId: connectionId,
            reason: "coordinator-finalize-pending-await-recovery",
            forceApply: true
        ) {
            return true
        }
        guard let liveTrack = await resolveFreshLiveTrackForPendingWrapperRebind(
            connectionId: connectionId,
            participantId: participantId
        ),
              liveTrack.isLiveVideoTrack,
              let liveTrackId = liveTrack.trackIdIfAvailable,
              !liveTrackId.isEmpty else {
            return false
        }
        view.rendererDidUpdateLayout()
        guard view.attach(liveTrack) else {
            view.requestPendingLiveWrapperRebind()
            logger.log(
                level: .info,
                message: """
                Pending-await session-store attach declined participant=\(participantId) \
                trackId=\(liveTrackId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return false
        }
        let settlementKey = participantAssignmentKey(participantId)
        if view.attachedTrackSharesRendererSink(with: liveTrack) || view.attachedTrackIsLive() {
            await session.persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                liveTrack: liveTrack
            )
            await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
            logger.log(
                level: .info,
                message: """
                Recovered pending-await live wrapper from session store participant=\(participantId) \
                trackId=\(liveTrackId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            return true
        }
        view.requestPendingLiveWrapperRebind()
        return false
    }

    private func shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
        settlementKey: String,
        view: AndroidSampleCaptureView,
        probe: ParticipantRendererAttachSnapshot
    ) -> Bool {
        let settlementOrPassEndWarmedThisEpisode = coordinatorSettlementSinkOnlySucceededKeys.contains(settlementKey)
            || coordinatorPassEndMediaReadyParticipantKeys.contains(settlementKey)
        guard settlementOrPassEndWarmedThisEpisode else { return false }
        return AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
            settlementSinkOnlySucceededThisEpisode: true,
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererHasDeliveredFramesSinceCurrentSinkAttach: view.rendererHasDeliveredFramesSinceCurrentSinkAttach(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
            rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile
        )
    }

    private func shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
        settlementKey: String,
        view: AndroidSampleCaptureView,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
            pendingApplySucceededThisFinalize: coordinatorFinalizePendingRebindAppliedKeys.contains(settlementKey),
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererLayoutNeedsSinkReconcile: rendererLayoutNeedsSinkReconcile
        )
    }

    private func shouldAwaitFinalizeFirstFrameAfterPendingApply(
        settlementKey: String,
        view: AndroidSampleCaptureView,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        AndroidGroupParticipantRendererAttachPolicy.shouldAwaitFinalizeFirstFrameAfterPendingApply(
            pendingApplySucceededThisFinalize: coordinatorFinalizePendingRebindAppliedKeys.contains(settlementKey),
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererLayoutNeedsSinkReconcile: rendererLayoutNeedsSinkReconcile
        )
    }

    private func applyPendingLiveWrapperRebindsForParticipants(
        participantIds: [String],
        connectionId: String,
        reason: String,
        forceApply: Bool = false
    ) async {
        for participantId in participantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            if coordinatorSettlementSinkOnlySucceededKeys.contains(settlementKey),
               let liveTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
               ) {
                let probe = ParticipantRendererAttachSnapshot.from(view: view, track: liveTrack)
                if shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
                    settlementKey: settlementKey,
                    view: view,
                    probe: probe
                ) {
                    logger.log(
                        level: .info,
                        message: """
                        Skipping coordinator pending wrapper rebind; settlement sink-only already warmed tile \
                        participant=\(participantId) reason=\(reason) \
                        diagnostics=\(view.rendererAttachDiagnosticSummary())
                        """
                    )
                    continue
                }
            }
            _ = await applyPendingLiveWrapperRebindIfEligible(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: reason,
                forceApply: forceApply
            )
        }
    }

    private func rebindStaleWrapperSinksForSettledParticipants(
        participantIds: [String],
        connectionId: String,
        reason: String,
        fullAttachedThisPassKeys: Set<String> = [],
        allowWhenAlreadyReboundThisEpisode: Bool = false,
        episodeSettlementFollows: Bool = false
    ) async {
        var siblingPassEndRebindConfirmedFirstFrame = false
        for participantId in participantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            let settledPreviously = participantCoordinatorSettledKeys.contains(settlementKey)
            let boundThisEpisode = postRenegotiationCoordinatorBoundParticipantKeys.contains(settlementKey)
            guard settledPreviously || boundThisEpisode else {
                continue
            }
            if view.hasPendingLiveWrapperRebind() {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; live wrapper swap already deferred \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            let liveTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
            let probe = liveTrack.map {
                ParticipantRendererAttachSnapshot.from(view: view, track: $0)
            } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                hasActiveSink: view.hasActiveSink(),
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
                attachedTrackIsLive: view.attachedTrackIsLive()
            )
            if shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
                settlementKey: settlementKey,
                view: view,
                probe: probe
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; settlement sink-only already warmed tile \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            if coordinatorPassEndMediaReadyParticipantKeys.contains(settlementKey),
               AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
               ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; pass-end warmth still rendering \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndSinkRebindBeforeEpisodeSettlement(
                episodeSettlementFollows: episodeSettlementFollows,
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererHasDeliveredFramesSinceCurrentSinkAttach: view.rendererHasDeliveredFramesSinceCurrentSinkAttach(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; episode settlement follows participant=\(participantId) \
                    reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndStaleWrapperRebindForEpisodeWarmedTile(
                fullAttachedThisCoordinatorPass: fullAttachedThisPassKeys.contains(settlementKey),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                tileAttachedTrackIsLive: view.attachedTrackIsLive()
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; episode-warmed tile still recovering \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            let needsLiveWrapperRebind = AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
                attachedTrackId: view.attachedTrackId(),
                mappedLiveTrackId: liveTrack?.trackIdIfAvailable,
                hasActiveSink: probe.hasActiveSink || view.hasActiveSink(),
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                attachedTrackIsLive: view.attachedTrackIsLive()
            )
            if !needsLiveWrapperRebind,
               hasSiblingSmoothlyRenderingFullAttachThisPass(
                excludingParticipantId: participantId,
                fullAttachedThisPassKeys: fullAttachedThisPassKeys
               ),
               !fullAttachedThisPassKeys.contains(settlementKey),
               !AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
               ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; sibling full attach still settling \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            if postRenegotiationCoordinatorSinkReboundParticipantKeys.contains(settlementKey),
               probe.attachedTrackIsLive,
               probe.boundTrackSharesRendererSinkWithTarget,
               !view.rendererFramesStaleWhileBound() {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; wrapper sync already attempted this episode \
                    participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            let staleFramesBeforeRebind = view.rendererFramesStaleWhileBound()
            if AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPassEndSinkRebindAfterSiblingRecovery(
                siblingPassEndRebindConfirmedFirstFrame: siblingPassEndRebindConfirmedFirstFrame,
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: staleFramesBeforeRebind
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator pass-end sink rebind; sibling just recovered and tile is \
                    smoothly rendering participant=\(participantId) reason=\(reason) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            guard AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
                fullAttachedThisCoordinatorPass: fullAttachedThisPassKeys.contains(settlementKey),
                attachedTrackId: view.attachedTrackId(),
                mappedLiveTrackId: liveTrack?.trackIdIfAvailable,
                hasActiveSink: probe.hasActiveSink || view.hasActiveSink(),
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                attachedTrackIsLive: view.attachedTrackIsLive(),
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererFramesStaleWhileBound: staleFramesBeforeRebind
            ) else {
                continue
            }
            logger.log(
                level: .info,
                message: """
                Coordinator settled sink rebind selected participant=\(participantId) reason=\(reason) \
                fullAttachedThisPass=\(fullAttachedThisPassKeys.contains(settlementKey)) \
                settledPreviously=\(settledPreviously) boundThisEpisode=\(boundThisEpisode) \
                probeActiveSink=\(probe.hasActiveSink) probeSharesSink=\(probe.boundTrackSharesRendererSinkWithTarget) \
                probeLayoutReconcile=\(probe.rendererLayoutNeedsSinkReconcile) staleFrames=\(staleFramesBeforeRebind) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            let didRebind: Bool
            if isPostRenegotiationAttachEpisodeActive(for: connectionId.normalizedConnectionId) {
                didRebind = await bindParticipantLiveWrapperFromSessionStore(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: reason
                )
            } else {
                didRebind = await rebindParticipantRendererSinkIfNeeded(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: reason,
                    allowWhenAlreadyReboundThisEpisode: allowWhenAlreadyReboundThisEpisode,
                    forceLiveWrapperRecovery: !view.attachedTrackIsLive()
                )
            }
            if didRebind {
                if view.hasPendingLiveWrapperRebind() {
                    logger.log(
                        level: .info,
                        message: """
                        Coordinator settled sink rebind deferred until stale wrapper stalls \
                        participant=\(participantId) reason=\(reason) \
                        diagnostics=\(view.rendererAttachDiagnosticSummary())
                        """
                    )
                } else {
                    await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                    if view.rendererHadConfirmedFirstFrameSinceSinkAttach() {
                        coordinatorPassEndMediaReadyParticipantKeys.insert(settlementKey)
                    }
                    logger.log(
                        level: .info,
                        message: """
                        Coordinator settled sink rebind completed participant=\(participantId) reason=\(reason) \
                        staleFramesBeforeRebind=\(staleFramesBeforeRebind) \
                        diagnostics=\(view.rendererAttachDiagnosticSummary())
                        """
                    )
                }
                if view.rendererEverConfirmedFirstFrameForAttachedTrack()
                    || view.rendererHadConfirmedFirstFrameSinceSinkAttach() {
                    siblingPassEndRebindConfirmedFirstFrame = true
                }
            }
        }
    }

    private func rebindAllCoordinatorSettledParticipantSinksForRecovery(
        connectionId: String,
        triggeringParticipantId: String
    ) async {
        for participantId in participantViewAssignments.keys.sorted() {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            guard participantCoordinatorSettledKeys.contains(settlementKey),
                  let liveTrack = await resolveLiveTrackForSinkRebind(
                    connectionId: connectionId,
                    participantId: participantId,
                    view: view
                  ) else {
                continue
            }
            let probe = ParticipantRendererAttachSnapshot.from(view: view, track: liveTrack)
            let staleFramesBeforeRebind = view.rendererFramesStaleWhileBound()
            let isTriggeringParticipant = participantAssignmentKey(participantId)
                == participantAssignmentKey(triggeringParticipantId)
            if !isTriggeringParticipant,
               AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: staleFramesBeforeRebind
               ) {
                continue
            }
            guard AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
                fullAttachedThisCoordinatorPass: false,
                attachedTrackId: view.attachedTrackId(),
                mappedLiveTrackId: liveTrack.trackIdIfAvailable,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                attachedTrackIsLive: probe.attachedTrackIsLive,
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererFramesStaleWhileBound: staleFramesBeforeRebind
            ) else {
                continue
            }
            logger.log(
                level: .info,
                message: """
                Rebinding coordinator-settled participant set after recovery event \
                trigger=\(triggeringParticipantId) participant=\(participantId) \
                trackId=\(liveTrack.trackIdIfAvailable ?? "<unknown>") diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            view.rendererDidUpdateLayout()
            if view.attach(liveTrack) {
                await session.persistAndroidLiveRemoteCameraTrackAfterSinkRebind(
                    connectionId: connectionId,
                    participantId: participantId,
                    liveTrack: liveTrack
                )
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                postRenegotiationCoordinatorSinkReboundParticipantKeys.insert(settlementKey)
                participantRendererRecoveryIssuedKeys.remove(settlementKey)
            }
        }
    }

    private func coordinatorAttachParticipantIds(connectionId: String) async -> [String] {
        var attachTargets = postRenegotiationEpisodeParticipantIds
        if let connection = await session.connectionManager.findConnection(with: connectionId) {
            for participantId in connection.remoteVideoTracksByParticipantId.keys {
                let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                attachTargets.insert(trimmed)
            }
        }
        return AndroidGroupPostRenegotiationAttachCoordinator.coordinatedAttachParticipantIds(
            episodeParticipantIds: Array(attachTargets),
            assignedParticipantIds: Array(participantViewAssignments.keys),
            includeAllAssignedForGridLayout: postRenegotiationEpisodeIncludesGridLayout
        )
    }

    private func shouldSkipPostRenegotiationCoordinatorAttach(
        participantId: String,
        settlementKey: String,
        view: AndroidSampleCaptureView,
        connectionId: String
    ) async -> Bool {
        let mappedLiveTrackId = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        )?.trackIdIfAvailable
        let probeTrack = await resolveLiveTrackForSinkRebind(
            connectionId: connectionId,
            participantId: participantId,
            view: view
        )
        let probe = probeTrack.map {
            ParticipantRendererAttachSnapshot.from(view: view, track: $0)
        } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
            hasActiveSink: view.hasActiveSink(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
            attachedTrackIsLive: view.attachedTrackIsLive()
        )
        return AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorAttach(
            coordinatorBoundThisEpisode: postRenegotiationCoordinatorBoundParticipantKeys.contains(settlementKey),
            coordinatorSettledPreviously: participantCoordinatorSettledKeys.contains(settlementKey),
            attachedTrackId: view.attachedTrackId(),
            mappedLiveTrackId: mappedLiveTrackId,
            attachedTrackIsLive: view.attachedTrackIsLive(),
            probe: probe,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        )
    }

    /// LiveKit-style episode finalize: every rebound tile must reach media-ready before the episode clears.
    private struct CoordinatorFinalizeParticipantContext {
        let participantId: String
        let settlementKey: String
        let view: AndroidSampleCaptureView
        let awaitingAfterPendingApply: Bool
    }

    private func ensureCoordinatorParticipantsMediaReady(
        participantIds: [String],
        connectionId: String
    ) async {
        var awaitingFirstFrame: [CoordinatorFinalizeParticipantContext] = []
        for participantId in participantIds {
            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                continue
            }
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            guard let liveTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            ) else {
                if view.hasPendingLiveWrapperRebind() {
                    participantCoordinatorSettledKeys.insert(settlementKey)
                    logger.log(
                        level: .info,
                        message: """
                        Coordinator finalize media-ready deferred; pending live-wrapper rebind owns \
                        settlement participant=\(participantId) \
                        diagnostics=\(view.rendererAttachDiagnosticSummary())
                        """
                    )
                } else {
                    logger.log(
                        level: .info,
                        message: """
                        Coordinator finalize media-ready skipped; live receiver unavailable \
                        participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                        """
                    )
                }
                continue
            }
            if await participantTileIsMediaReady(
                view: view,
                connectionId: connectionId,
                participantId: participantId,
                liveTrack: liveTrack
            ) {
                participantCoordinatorSettledKeys.insert(settlementKey)
                continue
            }
            let probe = ParticipantRendererAttachSnapshot.from(view: view, track: liveTrack)
            if shouldAwaitFinalizeFirstFrameAfterPendingApply(
                settlementKey: settlementKey,
                view: view,
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize awaiting first frame after pending apply \
                    participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                awaitingFirstFrame.append(
                    CoordinatorFinalizeParticipantContext(
                        participantId: participantId,
                        settlementKey: settlementKey,
                        view: view,
                        awaitingAfterPendingApply: true
                    )
                )
                continue
            }
            if shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
                settlementKey: settlementKey,
                view: view,
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator finalize recovery; pending apply already confirmed frames \
                    participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                participantCoordinatorSettledKeys.insert(settlementKey)
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeMediaReadyPromotion(
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererHasDeliveredFramesSinceCurrentSinkAttach: view.rendererHasDeliveredFramesSinceCurrentSinkAttach(),
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize media-ready awaiting first frame participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                awaitingFirstFrame.append(
                    CoordinatorFinalizeParticipantContext(
                        participantId: participantId,
                        settlementKey: settlementKey,
                        view: view,
                        awaitingAfterPendingApply: false
                    )
                )
                continue
            }
            if shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
                settlementKey: settlementKey,
                view: view,
                probe: probe
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator finalize churn; settlement sink-only already warmed tile \
                    participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                if await participantTileIsMediaReady(
                    view: view,
                    connectionId: connectionId,
                    participantId: participantId,
                    liveTrack: liveTrack
                ) {
                    participantCoordinatorSettledKeys.insert(settlementKey)
                    continue
                }
                awaitingFirstFrame.append(
                    CoordinatorFinalizeParticipantContext(
                        participantId: participantId,
                        settlementKey: settlementKey,
                        view: view,
                        awaitingAfterPendingApply: false
                    )
                )
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy.shouldDeferFinalizeMediaReadyToWrapperSync(
                attachedTrackId: view.attachedTrackId(),
                mappedLiveTrackId: liveTrack.trackIdIfAvailable,
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize media-ready wrapper sync participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                let didRebind = await rebindParticipantRendererSinkIfNeeded(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: "coordinator-finalize-pending-wrapper",
                    allowWhenAlreadyReboundThisEpisode: true,
                    forceLiveWrapperRecovery: true
                )
                if !didRebind {
                    _ = await performParticipantVideoAttach(
                        participantId: participantId,
                        view: view,
                        connectionId: connectionId,
                        reason: "coordinator-finalize-pending-wrapper"
                    )
                }
                if await participantTileIsMediaReady(
                    view: view,
                    connectionId: connectionId,
                    participantId: participantId
                ) {
                    participantCoordinatorSettledKeys.insert(settlementKey)
                    continue
                }
                awaitingFirstFrame.append(
                    CoordinatorFinalizeParticipantContext(
                        participantId: participantId,
                        settlementKey: settlementKey,
                        view: view,
                        awaitingAfterPendingApply: false
                    )
                )
                continue
            }
            logger.log(
                level: .info,
                message: """
                Coordinator finalize media-ready rebind participant=\(participantId) \
                diagnostics=\(view.rendererAttachDiagnosticSummary())
                """
            )
            _ = await rebindParticipantRendererSinkIfNeeded(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "coordinator-finalize-media-ready",
                allowWhenAlreadyReboundThisEpisode: true,
                forceLiveWrapperRecovery: true
            )
            if await participantTileIsMediaReady(
                view: view,
                connectionId: connectionId,
                participantId: participantId
            ) {
                participantCoordinatorSettledKeys.insert(settlementKey)
                continue
            }
            let didAttach = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "coordinator-finalize-media-ready"
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            }
            if await participantTileIsMediaReady(
                view: view,
                connectionId: connectionId,
                participantId: participantId
            ) {
                participantCoordinatorSettledKeys.insert(settlementKey)
                continue
            }
            let postAttachTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            ) ?? liveTrack
            let postAttachProbe = ParticipantRendererAttachSnapshot.from(view: view, track: postAttachTrack)
            if AndroidGroupParticipantRendererAttachPolicy.participantTileAwaitingSinkAttachFirstFrameAfterPromotion(
                attachedTrackIsLive: postAttachProbe.attachedTrackIsLive,
                hasActiveSink: postAttachProbe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: postAttachProbe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererHasDeliveredFramesSinceCurrentSinkAttach: view.rendererHasDeliveredFramesSinceCurrentSinkAttach()
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize media-ready awaiting first frame after promotion \
                    participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                awaitingFirstFrame.append(
                    CoordinatorFinalizeParticipantContext(
                        participantId: participantId,
                        settlementKey: settlementKey,
                        view: view,
                        awaitingAfterPendingApply: false
                    )
                )
            } else {
                logger.log(
                    level: .warning,
                    message: """
                    Coordinator finalize media-ready incomplete participant=\(participantId) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
            }
        }

        for context in awaitingFirstFrame {
            await reconcileFinalizeConfirmedParticipantsBeforeProceeding(
                participantIds: participantIds.filter { $0 != context.participantId },
                connectionId: connectionId
            )
            await awaitCoordinatorFinalizeSinkFirstFrame(
                context: context,
                connectionId: connectionId
            )
        }
    }

    private func awaitCoordinatorFinalizeSinkFirstFrame(
        context: CoordinatorFinalizeParticipantContext,
        connectionId: String
    ) async {
        if viewRendererHadConfirmedFirstFrame(context.view)
            || context.view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
            await markCoordinatorFinalizeMediaReadyIfEligible(
                context: context,
                connectionId: connectionId
            )
            return
        }
        if await participantTileIsMediaReady(
            view: context.view,
            connectionId: connectionId,
            participantId: context.participantId
        ) {
            await markCoordinatorFinalizeMediaReadyIfEligible(
                context: context,
                connectionId: connectionId
            )
            return
        }
        if !context.view.attachedTrackIsLive() {
            if context.awaitingAfterPendingApply {
                _ = await recoverLiveWrapperForPendingApplyFirstFrameWait(
                    participantId: context.participantId,
                    view: context.view,
                    connectionId: connectionId
                )
                if viewRendererHadConfirmedFirstFrame(context.view)
                    || context.view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
                    await markCoordinatorFinalizeMediaReadyIfEligible(
                        context: context,
                        connectionId: connectionId
                    )
                    return
                }
                if await participantTileIsMediaReady(
                    view: context.view,
                    connectionId: connectionId,
                    participantId: context.participantId
                ) {
                    await markCoordinatorFinalizeMediaReadyIfEligible(
                        context: context,
                        connectionId: connectionId
                    )
                    return
                }
                if !context.view.attachedTrackIsLive(), !context.view.hasActiveSink() {
                    logger.log(
                        level: .warning,
                        message: """
                        Coordinator finalize pending-await recovery incomplete; awaiting sink first frame \
                        participant=\(context.participantId) diagnostics=\(context.view.rendererAttachDiagnosticSummary())
                        """
                    )
                }
                if context.view.hasPendingLiveWrapperRebind() {
                    _ = await applyPendingLiveWrapperRebindIfEligible(
                        participantId: context.participantId,
                        view: context.view,
                        connectionId: connectionId,
                        reason: "coordinator-finalize-pending-await-rebind",
                        forceApply: true
                    )
                    if viewRendererHadConfirmedFirstFrame(context.view)
                        || context.view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
                        await markCoordinatorFinalizeMediaReadyIfEligible(
                            context: context,
                            connectionId: connectionId
                        )
                        return
                    }
                    if await participantTileIsMediaReady(
                        view: context.view,
                        connectionId: connectionId,
                        participantId: context.participantId
                    ) {
                        await markCoordinatorFinalizeMediaReadyIfEligible(
                            context: context,
                            connectionId: connectionId
                        )
                        return
                    }
                }
            } else {
                await markCoordinatorFinalizeMediaReadyIfEligible(
                    context: context,
                    connectionId: connectionId
                )
                return
            }
        }
        if viewRendererHadConfirmedFirstFrame(context.view)
            || context.view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
            await markCoordinatorFinalizeMediaReadyIfEligible(
                context: context,
                connectionId: connectionId
            )
            return
        }
        if await participantTileIsMediaReady(
            view: context.view,
            connectionId: connectionId,
            participantId: context.participantId
        ) {
            await markCoordinatorFinalizeMediaReadyIfEligible(
                context: context,
                connectionId: connectionId
            )
            return
        }
        let normalizedConnectionId = connectionId.normalizedConnectionId
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coordinatorFinalizeMediaReadyWaiters[context.settlementKey] = CoordinatorFinalizeMediaReadyWaiter(
                connectionId: normalizedConnectionId,
                view: context.view,
                continuation: continuation
            )
            context.view.setSinkAttachFirstFrameObserver { [weak view = context.view] in
                Task { [weak view] in
                    await self.handleCoordinatorFinalizeSinkFirstFrame(
                        settlementKey: context.settlementKey,
                        view: view
                    )
                }
            }
        }
        await recoverCoordinatorFinalizeParticipantAfterSinkWaitIfNeeded(
            context: context,
            connectionId: connectionId
        )
        await markCoordinatorFinalizeMediaReadyIfEligible(
            context: context,
            connectionId: connectionId
        )
    }

    /// Event-driven recovery when a finalize first-frame wait ends without current-sink frame evidence.
    private func recoverCoordinatorFinalizeParticipantAfterSinkWaitIfNeeded(
        context: CoordinatorFinalizeParticipantContext,
        connectionId: String
    ) async {
        if viewRendererHadConfirmedFirstFrame(context.view)
            || context.view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
            return
        }
        if await participantTileIsMediaReady(
            view: context.view,
            connectionId: connectionId,
            participantId: context.participantId
        ) {
            return
        }
        logger.log(
            level: .info,
            message: """
            Coordinator finalize sink wait ended without current-sink first frame; recovering \
            participant=\(context.participantId) diagnostics=\(context.view.rendererAttachDiagnosticSummary())
            """
        )
        if context.view.hasPendingLiveWrapperRebind() {
            _ = await applyPendingLiveWrapperRebindIfEligible(
                participantId: context.participantId,
                view: context.view,
                connectionId: connectionId,
                reason: "coordinator-finalize-sink-wait-recovery",
                forceApply: true
            )
        }
        if viewRendererHadConfirmedFirstFrame(context.view)
            || context.view.rendererHasDeliveredFramesSinceCurrentSinkAttach() {
            return
        }
        if await participantTileIsMediaReady(
            view: context.view,
            connectionId: connectionId,
            participantId: context.participantId
        ) {
            return
        }
        _ = await recoverLiveWrapperForPendingApplyFirstFrameWait(
            participantId: context.participantId,
            view: context.view,
            connectionId: connectionId
        )
    }

    private func handleCoordinatorFinalizeSinkFirstFrame(
        settlementKey: String,
        view: AndroidSampleCaptureView?
    ) async {
        guard let waiter = coordinatorFinalizeMediaReadyWaiters.removeValue(forKey: settlementKey) else {
            return
        }
        view?.clearSinkAttachFirstFrameObserver()
        waiter.continuation.resume()
    }

    private func cancelCoordinatorFinalizeMediaReadyWaits(reason: String) {
        guard !coordinatorFinalizeMediaReadyWaiters.isEmpty else { return }
        let waiters = coordinatorFinalizeMediaReadyWaiters
        coordinatorFinalizeMediaReadyWaiters.removeAll()
        for (settlementKey, waiter) in waiters {
            waiter.view.clearSinkAttachFirstFrameObserver()
            waiter.continuation.resume()
            logger.log(
                level: .info,
                message: "Cancelled coordinator finalize media-ready wait settlementKey=\(settlementKey) reason=\(reason)"
            )
        }
    }

    private func markCoordinatorFinalizeMediaReadyIfEligible(
        context: CoordinatorFinalizeParticipantContext,
        connectionId: String
    ) async {
        guard isPostRenegotiationAttachEpisodeActive(for: connectionId) else { return }
        guard await resolveLiveTrackForSinkRebind(
            connectionId: connectionId,
            participantId: context.participantId,
            view: context.view
        ) != nil else {
            return
        }
        if await participantTileIsMediaReady(
            view: context.view,
            connectionId: connectionId,
            participantId: context.participantId
        ) {
            participantCoordinatorSettledKeys.insert(context.settlementKey)
            coordinatorFinalizeMediaReadyConfirmedKeys.insert(context.settlementKey)
            logger.log(
                level: .info,
                message: """
                Coordinator finalize media-ready confirmed participant=\(context.participantId) \
                diagnostics=\(context.view.rendererAttachDiagnosticSummary())
                """
            )
            return
        }
        if !context.view.attachedTrackIsLive() {
            if shouldAwaitFinalizeFirstFrameAfterPendingApply(
                settlementKey: context.settlementKey,
                view: context.view,
                rendererLayoutNeedsSinkReconcile: context.view.rendererLayoutNeedsSinkReconcile()
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize pending-await still awaiting current-sink first frame \
                    participant=\(context.participantId) diagnostics=\(context.view.rendererAttachDiagnosticSummary())
                    """
                )
                return
            }
            if shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
                settlementKey: context.settlementKey,
                view: context.view,
                rendererLayoutNeedsSinkReconcile: context.view.rendererLayoutNeedsSinkReconcile()
            ) {
                participantCoordinatorSettledKeys.insert(context.settlementKey)
                coordinatorFinalizeMediaReadyConfirmedKeys.insert(context.settlementKey)
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize media-ready confirmed after pending apply first frame \
                    participant=\(context.participantId) diagnostics=\(context.view.rendererAttachDiagnosticSummary())
                    """
                )
                return
            }
            let didRebind = await rebindParticipantRendererSinkIfNeeded(
                participantId: context.participantId,
                view: context.view,
                connectionId: connectionId,
                reason: "coordinator-finalize-post-wait-wrapper-sync",
                allowWhenAlreadyReboundThisEpisode: true,
                forceLiveWrapperRecovery: true
            )
            if !didRebind {
                _ = await performParticipantVideoAttach(
                    participantId: context.participantId,
                    view: context.view,
                    connectionId: connectionId,
                    reason: "coordinator-finalize-post-wait-wrapper-sync"
                )
            }
            if await participantTileIsMediaReady(
                view: context.view,
                connectionId: connectionId,
                participantId: context.participantId
            ) {
                participantCoordinatorSettledKeys.insert(context.settlementKey)
                coordinatorFinalizeMediaReadyConfirmedKeys.insert(context.settlementKey)
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize media-ready confirmed after post-wait recovery \
                    participant=\(context.participantId) diagnostics=\(context.view.rendererAttachDiagnosticSummary())
                    """
                )
                return
            }
        }
        if !postRenegotiationCoordinatorRerunNeeded {
            logger.log(
                level: .warning,
                message: """
                Coordinator finalize media-ready incomplete after first-frame wait \
                participant=\(context.participantId) diagnostics=\(context.view.rendererAttachDiagnosticSummary())
                """
            )
        }
    }

    private func viewRendererHadConfirmedFirstFrame(_ view: AndroidSampleCaptureView) -> Bool {
        view.rendererHadConfirmedFirstFrameSinceSinkAttach()
    }

    private func participantTileIsMediaReady(
        view: AndroidSampleCaptureView,
        connectionId: String,
        participantId: String,
        liveTrack: RTCVideoTrack? = nil
    ) async -> Bool {
        let probeTrack: RTCVideoTrack?
        if let liveTrack {
            probeTrack = liveTrack
        } else {
            probeTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
        }
        let probe = probeTrack.map {
            ParticipantRendererAttachSnapshot.from(view: view, track: $0)
        } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
            hasActiveSink: view.hasActiveSink(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
            attachedTrackIsLive: view.attachedTrackIsLive()
        )
        return AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererHasDeliveredFramesSinceCurrentSinkAttach: view.rendererHasDeliveredFramesSinceCurrentSinkAttach(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        )
    }

    private func participantTileIsMediaReadyForEpisodeClear(
        view: AndroidSampleCaptureView,
        connectionId: String,
        participantId: String,
        liveTrack: RTCVideoTrack? = nil
    ) async -> Bool {
        let probeTrack: RTCVideoTrack?
        if let liveTrack {
            probeTrack = liveTrack
        } else {
            probeTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
        }
        let probe = probeTrack.map {
            ParticipantRendererAttachSnapshot.from(view: view, track: $0)
        } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
            hasActiveSink: view.hasActiveSink(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
            attachedTrackIsLive: view.attachedTrackIsLive()
        )
        return AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReadyForEpisodeClear(
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererHasDeliveredFramesSinceCurrentSinkAttach: view.rendererHasDeliveredFramesSinceCurrentSinkAttach(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
            hasPendingLiveWrapperRebind: view.hasPendingLiveWrapperRebind()
        )
    }

    private func participantNeedsCoordinatorSettlementAttach(
        participantId: String,
        view: AndroidSampleCaptureView,
        connectionId: String
    ) async -> Bool {
        let settlementKey = participantAssignmentKey(participantId)
        if AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
            passEndWarmedThisEpisode: coordinatorPassEndMediaReadyParticipantKeys.contains(settlementKey),
            attachedTrackIsLive: view.attachedTrackIsLive(),
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile()
        ) {
            return false
        }
        if AndroidGroupParticipantRendererAttachPolicy.participantRendererStillDeliveringRecentFramesOnStaleWrapper(
            attachedTrackIsLive: view.attachedTrackIsLive(),
            hasActiveSink: view.hasActiveSink(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
            rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack()
        ) {
            return false
        }
        if coordinatorSettlementSinkOnlySucceededKeys.contains(settlementKey) {
            if await participantTileIsMediaReady(
                view: view,
                connectionId: connectionId,
                participantId: participantId
            ) {
                return false
            }
            let liveTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
            let probe = liveTrack.map {
                ParticipantRendererAttachSnapshot.from(view: view, track: $0)
            } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                hasActiveSink: view.hasActiveSink(),
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
                attachedTrackIsLive: view.attachedTrackIsLive()
            )
            if shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
                settlementKey: settlementKey,
                view: view,
                probe: probe
            ) {
                return false
            }
        }
        let liveTrack = await session.androidMappedLiveRemoteCameraTrack(
            connectionId: connectionId,
            participantId: participantId,
            preferFreshFromPeerConnection: false
        )
        if AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: postRenegotiationCoordinatorBoundParticipantKeys.contains(settlementKey),
            coordinatorSettledPreviously: participantCoordinatorSettledKeys.contains(settlementKey),
            attachedTrackId: view.attachedTrackId(),
            mappedLiveTrackId: liveTrack?.trackIdIfAvailable,
            attachedTrackIsLive: view.attachedTrackIsLive(),
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach()
        ) {
            return false
        }
        let probe = liveTrack.map {
            ParticipantRendererAttachSnapshot.from(view: view, track: $0)
        } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
            hasActiveSink: view.hasActiveSink(),
            rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
            attachedTrackIsLive: view.attachedTrackIsLive()
        )
        if probe.hasActiveSink, probe.boundTrackSharesRendererSinkWithTarget {
            return false
        }
        if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
            rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
        ) {
            return false
        }
        return liveTrack?.isLiveVideoTrack == true || view.attachedTrackId() != nil
    }

    private func ensureViewsAssignedForCoordinatorParticipants(
        participantIds: [String],
        connectionId: String
    ) async {
        for participantId in participantIds {
            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                continue
            }
            await ensureParticipantViewAssigned(participantId: participantId, connectionId: connectionId)
        }
    }

    private func attachUnsettledCoordinatorParticipantsIfNeeded(
        participantIds: [String],
        connectionId: String,
        reason: String
    ) async {
        for participantId in participantIds {
            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                continue
            }
            await ensureParticipantViewAssigned(participantId: participantId, connectionId: connectionId)
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                logger.log(
                    level: .warning,
                    message: "Coordinator settlement missing assigned view participant=\(participantId) connection=\(connectionId)"
                )
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            if postRenegotiationCoordinatorBoundParticipantKeys.contains(settlementKey),
               await participantTileIsMediaReady(
                view: view,
                connectionId: connectionId,
                participantId: participantId
               ) {
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator settlement attach; participant already media-ready this episode \
                    participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
                passEndWarmedThisEpisode: coordinatorPassEndMediaReadyParticipantKeys.contains(settlementKey),
                attachedTrackIsLive: view.attachedTrackIsLive(),
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile()
            ) {
                if !view.attachedTrackIsLive() {
                    view.requestPendingLiveWrapperRebind()
                }
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator settlement attach; pass-end stale sweep already warmed tile \
                    participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            if AndroidGroupParticipantRendererAttachPolicy.participantRendererStillDeliveringRecentFramesOnStaleWrapper(
                attachedTrackIsLive: view.attachedTrackIsLive(),
                hasActiveSink: view.hasActiveSink(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack()
            ), view.attachedTrackIsLive() {
                view.requestPendingLiveWrapperRebind()
                logger.log(
                    level: .info,
                    message: """
                    Skipping coordinator settlement attach; stale wrapper still delivering recent frames \
                    participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                continue
            }
            guard await participantNeedsCoordinatorSettlementAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId
            ) else {
                continue
            }
            logger.log(
                level: .info,
                message: "Coordinator settlement attach participant=\(participantId) reason=\(reason) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            let didAttach = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: reason
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            }
        }
    }

    private func syncSettledParticipantLiveWrapperSinksAfterMapRefresh(
        participantIds: [String],
        connectionId: String
    ) async {
        for participantId in participantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            guard participantCoordinatorSettledKeys.contains(settlementKey) else {
                continue
            }
            _ = await reconcileSettledParticipantWrapperSyncIfNeeded(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                settlementKey: settlementKey
            )
        }
    }

    private func runPostRenegotiationAttachCoordinatorIfReady(connectionId: String) async {
        let norm = connectionId.normalizedConnectionId
        guard isPostRenegotiationAttachEpisodeActive(for: norm) else { return }
        if await session.shouldDeferSfuGroupParticipantVideoAttach(for: norm) {
            postRenegotiationCoordinatorRerunNeeded = true
            logger.log(
                level: .info,
                message: "Deferred Android post-renegotiation attach coordinator; SFU signaling still settling connection=\(norm)"
            )
            return
        }
        await executePostRenegotiationAttachCoordinator(connectionId: norm)
    }

    private func executePostRenegotiationAttachCoordinator(connectionId: String) async {
        let participantIds = await coordinatorAttachParticipantIds(connectionId: connectionId)
        guard !participantIds.isEmpty else { return }

        logger.log(
            level: .info,
            message: "Android post-renegotiation attach coordinator begin participants=\(participantIds.joined(separator: ",")) connection=\(connectionId)"
        )

        await ensureViewsAssignedForCoordinatorParticipants(
            participantIds: participantIds,
            connectionId: connectionId
        )

        if AndroidGroupPostRenegotiationAttachCoordinator.coordinatorEpisodeUsesGlobalConnectionMapRefresh(
            passIndex: postRenegotiationCoordinatorPassIndex
        ) {
            await session.rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(connectionId: connectionId)
            await syncSettledParticipantLiveWrapperSinksAfterMapRefresh(
                participantIds: participantIds,
                connectionId: connectionId
            )
        } else {
            logger.log(
                level: .info,
                message: """
                Skipping post-renegotiation connection map refresh; episode participants already settled \
                participants=\(participantIds.joined(separator: ",")) connection=\(connectionId)
                """
            )
        }

        for view in participantViewAssignments.values {
            view.rendererDidUpdateLayout()
        }

        let attachParticipantIds = await coordinatorAttachParticipantIds(connectionId: connectionId)
        await ensureViewsAssignedForCoordinatorParticipants(
            participantIds: attachParticipantIds,
            connectionId: connectionId
        )

        var coordinatorFullAttachedKeys = Set<String>()
        for participantId in attachParticipantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            if await shouldSkipPostRenegotiationCoordinatorAttach(
                participantId: participantId,
                settlementKey: settlementKey,
                view: view,
                connectionId: connectionId
            ) {
                continue
            }
            participantAttachedTrackIdsByKey.removeValue(forKey: settlementKey)
            participantRendererRecoveryIssuedKeys.remove(settlementKey)
            let attachReason = postRenegotiationEpisodeIncludesGridLayout
                ? "post-renegotiation-grid-layout"
                : "post-renegotiation-coordinator"
            let didAttach = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: attachReason
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                postRenegotiationCoordinatorBoundParticipantKeys.insert(settlementKey)
                coordinatorFullAttachedKeys.insert(settlementKey)
            }
        }

        for participantId in attachParticipantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            guard await shouldSkipPostRenegotiationCoordinatorAttach(
                participantId: participantId,
                settlementKey: settlementKey,
                view: view,
                connectionId: connectionId
            ) else {
                continue
            }
            postRenegotiationCoordinatorBoundParticipantKeys.insert(settlementKey)
            logger.log(
                level: .info,
                message: "Skipping post-renegotiation coordinator attach; participant already settled participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            let didSync = await reconcileSettledParticipantWrapperSyncIfNeeded(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                settlementKey: settlementKey
            )
            _ = didSync
        }

        for participantId in attachParticipantIds {
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            let settlementKey = participantAssignmentKey(assignmentKey)
            let liveTrack = await resolveLiveTrackForSinkRebind(
                connectionId: connectionId,
                participantId: participantId,
                view: view
            )
            let probe = liveTrack.map {
                ParticipantRendererAttachSnapshot.from(view: view, track: $0)
            } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                hasActiveSink: view.hasActiveSink(),
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
                attachedTrackIsLive: view.attachedTrackIsLive()
            )
            if AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                attachedTrackIsLive: probe.attachedTrackIsLive,
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
            ) {
                logger.log(
                    level: .info,
                    message: "Skipping post-renegotiation reconcile pass; tile already rendering participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
                )
                continue
            }
            if participantCoordinatorSettledKeys.contains(settlementKey) {
                continue
            }
            guard !view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                  !view.rendererHadConfirmedFirstFrameSinceSinkAttach() else {
                continue
            }
            view.rendererDidUpdateLayout()
            if view.hasActiveSink() {
                if view.forceReinitializeRendererForAttachedTrackIfPreFirstFrame() {
                    logger.log(
                        level: .info,
                        message: "Android post-renegotiation pre-first-frame EGL reconcile participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
                    )
                    await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                }
                continue
            }
            let didReconcile = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "post-renegotiation-first-frame-reconcile"
            )
            if didReconcile {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            }
        }

        if AndroidGroupPostRenegotiationAttachCoordinator.shouldRunCoordinatorPassStaleSweep(
            passIndex: postRenegotiationCoordinatorPassIndex,
            rerunQueued: postRenegotiationCoordinatorRerunNeeded
        ) {
            postRenegotiationCoordinatorFullAttachedParticipantKeys.formUnion(coordinatorFullAttachedKeys)
            await rebindStaleWrapperSinksForSettledParticipants(
                participantIds: attachParticipantIds,
                connectionId: connectionId,
                reason: "coordinator-pass-stale-wrapper",
                fullAttachedThisPassKeys: coordinatorFullAttachedKeys,
                episodeSettlementFollows: !postRenegotiationCoordinatorRerunNeeded
            )
            await applyPendingLiveWrapperRebindsForParticipants(
                participantIds: attachParticipantIds,
                connectionId: connectionId,
                reason: "coordinator-pass-pending-wrapper",
                forceApply: true
            )
        }

        let finalParticipantIds = await coordinatorAttachParticipantIds(connectionId: connectionId)
        if Set(finalParticipantIds) != Set(attachParticipantIds) {
            postRenegotiationCoordinatorRerunNeeded = true
            logger.log(
                level: .info,
                message: "Queued post-renegotiation attach coordinator rerun; participant set grew during pass connection=\(connectionId)"
            )
        }

        logger.log(
            level: .info,
            message: "Android post-renegotiation attach coordinator pass end participants=\(finalParticipantIds.joined(separator: ",")) connection=\(connectionId)"
        )
    }

    private func clearPostRenegotiationAttachEpisode() {
        postRenegotiationEpisodeConnectionId = nil
        postRenegotiationEpisodeParticipantIds.removeAll()
        postRenegotiationEpisodeIncludesGridLayout = false
        postRenegotiationCoordinatorPassIndex = 0
        postRenegotiationCoordinatorBoundParticipantKeys.removeAll()
        postRenegotiationCoordinatorFullAttachedParticipantKeys.removeAll()
        postRenegotiationCoordinatorSinkReboundParticipantKeys.removeAll()
        coordinatorSettlementSinkOnlySucceededKeys.removeAll()
        coordinatorPassEndMediaReadyParticipantKeys.removeAll()
        coordinatorFinalizePendingRebindAppliedKeys.removeAll()
        coordinatorFinalizeMediaReadyConfirmedKeys.removeAll()
        postCoordinatorPendingWrapperApplyParticipantKeys.removeAll()
    }

    /// Sequential finalize await can take seconds per participant; wrappers may END on an already-
    /// confirmed tile before the final sweep. Rebind from session store when that happens.
    /// Reconciling one tile can END another; repeat passes until all confirmed tiles are media-ready
    /// or a pass makes no progress (event-driven first-frame await after each recovery).
    private func reconcileFinalizeConfirmedParticipantsBeforeProceeding(
        participantIds: [String],
        connectionId: String
    ) async {
        guard !coordinatorFinalizeMediaReadyConfirmedKeys.isEmpty else { return }
        let maxStabilizationPasses = max(participantIds.count * 2, 2)
        for passIndex in 1 ... maxStabilizationPasses {
            var attemptedReconcile = false
            for participantId in participantIds {
                let settlementKey = participantAssignmentKey(participantId)
                guard coordinatorFinalizeMediaReadyConfirmedKeys.contains(settlementKey) else { continue }
                guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                    continue
                }
                guard let assignmentKey = assignedParticipantKey(matching: participantId),
                      let view = participantViewAssignments[assignmentKey] else {
                    continue
                }
                if await participantTileIsMediaReady(
                    view: view,
                    connectionId: connectionId,
                    participantId: participantId
                ) {
                    continue
                }
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize re-reconciling previously confirmed participant=\(participantId) \
                    pass=\(passIndex)/\(maxStabilizationPasses) \
                    diagnostics=\(view.rendererAttachDiagnosticSummary())
                    """
                )
                attemptedReconcile = true
                if view.hasPendingLiveWrapperRebind() {
                    _ = await applyPendingLiveWrapperRebindIfEligible(
                        participantId: participantId,
                        view: view,
                        connectionId: connectionId,
                        reason: "coordinator-finalize-confirmed-reconcile",
                        forceApply: true
                    )
                }
                if await participantTileIsMediaReady(
                    view: view,
                    connectionId: connectionId,
                    participantId: participantId
                ) {
                    continue
                }
                _ = await recoverLiveWrapperForPendingApplyFirstFrameWait(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId
                )
                await awaitCoordinatorFinalizeSinkFirstFrame(
                    context: CoordinatorFinalizeParticipantContext(
                        participantId: participantId,
                        settlementKey: settlementKey,
                        view: view,
                        awaitingAfterPendingApply: true
                    ),
                    connectionId: connectionId
                )
            }
            if await coordinatorConfirmedParticipantsAllMediaReady(
                participantIds: participantIds,
                connectionId: connectionId
            ) {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize confirmed-participant stabilization complete \
                    pass=\(passIndex)/\(maxStabilizationPasses) connection=\(connectionId)
                    """
                )
                return
            }
            if !attemptedReconcile {
                logger.log(
                    level: .info,
                    message: """
                    Coordinator finalize confirmed-participant stabilization stalled \
                    pass=\(passIndex)/\(maxStabilizationPasses) connection=\(connectionId)
                    """
                )
                return
            }
        }
    }

    private func coordinatorConfirmedParticipantsAllMediaReady(
        participantIds: [String],
        connectionId: String
    ) async -> Bool {
        for participantId in participantIds {
            let settlementKey = participantAssignmentKey(participantId)
            guard coordinatorFinalizeMediaReadyConfirmedKeys.contains(settlementKey) else { continue }
            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                continue
            }
            guard let assignmentKey = assignedParticipantKey(matching: participantId),
                  let view = participantViewAssignments[assignmentKey] else {
                continue
            }
            if await participantTileIsMediaReadyForEpisodeClear(
                view: view,
                connectionId: connectionId,
                participantId: participantId
            ) {
                continue
            }
            return false
        }
        return true
    }

    private func ensureParticipantViewAssigned(participantId: String, connectionId: String) async {
        guard assignedParticipantKey(matching: participantId) == nil else { return }
        guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
            return
        }
        guard let view = nextUnassignedRemoteView() else {
            logger.log(level: .warning, message: "No unassigned views for post-renegotiation participant=\(participantId)")
            return
        }
        unassignedViews.removeAll { $0 === view }
        assignParticipantView(view, to: participantId)
        await videoCallDelegate?.remoteParticipantTilesDidChange()
    }

    private func hasOtherParticipantSmoothlyRendering(
        excludingParticipantId participantId: String,
        connectionId: String
    ) async -> Bool {
        for (otherParticipantId, otherView) in participantViewAssignments where otherParticipantId != participantId {
            let otherTrack = await session.androidMappedLiveRemoteCameraTrack(
                connectionId: connectionId,
                participantId: otherParticipantId,
                preferFreshFromPeerConnection: false
            )
            let otherProbe = otherTrack.map {
                ParticipantRendererAttachSnapshot.from(view: otherView, track: $0)
            } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                hasActiveSink: otherView.hasActiveSink(),
                rendererLayoutNeedsSinkReconcile: otherView.rendererLayoutNeedsSinkReconcile(),
                attachedTrackIsLive: otherView.attachedTrackIsLive()
            )
            if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: otherProbe.attachedTrackIsLive,
                hasActiveSink: otherProbe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: otherProbe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: otherView.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: otherView.rendererFramesStaleWhileBound()
            ) {
                return true
            }
        }
        return false
    }

    private func checkParticipantRendererRecoveryIfNeeded(inboundFlow: RTCSession.InboundVideoFlowSnapshot) async {
        guard isGroupCall, let connectionId = currentCall?.sharedCommunicationId else { return }
        if isPostRenegotiationAttachEpisodeActive(for: connectionId) {
            return
        }
        if await session.shouldDeferSfuGroupParticipantVideoAttach(for: connectionId) {
            return
        }

        await applyPostCoordinatorDeferredPendingWrapperRebinds(connectionId: connectionId)

        for (participantId, view) in participantViewAssignments {
            let recoveryKey = participantRendererRecoveryKey(participantId)

            let liveTrack = await session.androidMappedLiveRemoteCameraTrack(
                connectionId: connectionId,
                participantId: participantId,
                preferFreshFromPeerConnection: false
            )
            let probe = liveTrack.map {
                ParticipantRendererAttachSnapshot.from(view: view, track: $0)
            } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                hasActiveSink: view.hasActiveSink(),
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
                attachedTrackIsLive: view.attachedTrackIsLive()
            )

            if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: probe.attachedTrackIsLive,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound()
            ) {
                participantRendererRecoveryIssuedKeys.remove(recoveryKey)
                continue
            }
            if view.hasPendingLiveWrapperRebind(),
               await applyPendingLiveWrapperRebindIfEligible(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "pending-wrapper-stall",
                forceApply: !probe.attachedTrackIsLive
               ) {
                continue
            }
            if participantRendererRecoveryIssuedKeys.contains(recoveryKey) {
                continue
            }
            if participantViewAssignments.count > 1,
               view.rendererEverConfirmedFirstFrameForAttachedTrack(),
               !view.rendererFramesStaleWhileBound(),
               !probe.hasActiveSink,
               await hasOtherParticipantSmoothlyRendering(
                excludingParticipantId: participantId,
                connectionId: connectionId
               ) {
                continue
            }

            let hasTrackContext = liveTrack?.isLiveVideoTrack == true
                || view.attachedTrackId() != nil
            let localTileNeedsRecovery = AndroidGroupParticipantRendererRecoveryPolicy
                .shouldRequestSinkRefreshForLocalTileState(
                    attachedTrackIsLive: probe.attachedTrackIsLive,
                    hasLiveTrack: hasTrackContext,
                    hasActiveSink: probe.hasActiveSink,
                    boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                    rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                    rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                    rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                    rendererHasPendingTrackBind: view.rendererHasPendingTrackBind(),
                    recoveryAlreadyIssuedForStallEpisode: participantRendererRecoveryIssuedKeys.contains(recoveryKey)
                )
            let shouldRecover = localTileNeedsRecovery
                || AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
                inboundDeltaFramesDecoded: inboundFlow.deltaFramesDecoded,
                inboundDeltaPacketsReceived: inboundFlow.deltaPacketsReceived,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrame: view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
                rendererEverConfirmedFirstFrameForAttachedTrack: view.rendererEverConfirmedFirstFrameForAttachedTrack(),
                rendererFramesStaleWhileBound: view.rendererFramesStaleWhileBound(),
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                rendererHasPendingTrackBind: view.rendererHasPendingTrackBind(),
                recoveryAlreadyIssuedForStallEpisode: participantRendererRecoveryIssuedKeys.contains(recoveryKey),
                hasLiveTrack: hasTrackContext,
                attachedTrackIsLive: probe.attachedTrackIsLive,
                coordinatorSettledParticipant: participantCoordinatorSettledKeys.contains(recoveryKey)
            )
            guard shouldRecover else { continue }

            participantRendererRecoveryIssuedKeys.insert(recoveryKey)
            logger.log(
                level: .info,
                message: "Recovering participant renderer after inbound/render mismatch participant=\(participantId) localTile=\(localTileNeedsRecovery) dFramesDecoded=\(inboundFlow.deltaFramesDecoded) dPackets=\(inboundFlow.deltaPacketsReceived) hasActiveSink=\(probe.hasActiveSink) sharesSink=\(probe.boundTrackSharesRendererSinkWithTarget) staleFrames=\(view.rendererFramesStaleWhileBound()) layoutReconcile=\(probe.rendererLayoutNeedsSinkReconcile) pendingBind=\(view.rendererHasPendingTrackBind()) everConfirmed=\(view.rendererEverConfirmedFirstFrameForAttachedTrack())"
            )
            if AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
                attachedTrackId: view.attachedTrackId(),
                mappedLiveTrackId: liveTrack?.trackIdIfAvailable,
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                attachedTrackIsLive: probe.attachedTrackIsLive
            ) {
                let didRebind = await rebindParticipantRendererSinkIfNeeded(
                    participantId: participantId,
                    view: view,
                    connectionId: connectionId,
                    reason: "inbound-render-recovery",
                    forceLiveWrapperRecovery: true
                )
                if didRebind {
                    await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                }
                continue
            }
            if participantCoordinatorSettledKeys.contains(recoveryKey) {
                await rebindAllCoordinatorSettledParticipantSinksForRecovery(
                    connectionId: connectionId,
                    triggeringParticipantId: participantId
                )
                continue
            }
            if !participantCoordinatorSettledKeys.contains(recoveryKey),
               !view.rendererEverConfirmedFirstFrameForAttachedTrack(),
               !view.rendererHadConfirmedFirstFrameSinceSinkAttach(),
               probe.hasActiveSink,
               !probe.boundTrackSharesRendererSinkWithTarget,
               view.forceReinitializeRendererForAttachedTrackIfPreFirstFrame() {
                logger.log(
                    level: .info,
                    message: "Recovered participant renderer with pre-first-frame EGL reconcile participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
                )
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                continue
            }
            if probe.hasActiveSink,
               !participantCoordinatorSettledKeys.contains(recoveryKey),
               view.rendererFramesStaleWhileBound(),
               view.forceReinitializeRendererForAttachedTrackIfFrameStale() {
                logger.log(
                    level: .info,
                    message: "Recovered participant renderer with stale-frame EGL reconcile participant=\(participantId) diagnostics=\(view.rendererAttachDiagnosticSummary())"
                )
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                continue
            }
            let didAttach = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "inbound-render-recovery"
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            }
        }
    }

    private func handleParticipantTrackEvent(_ event: RemoteParticipantTrackEvent) async {
        guard isRunning else { return }
        guard event.kind == "video" else { return }
        let connectionId = currentCall?.sharedCommunicationId ?? event.connectionId

        if event.isActive {
            logger.log(level: .info, message: "Participant track added: participant=\(event.participantId)")
            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: event.participantId) else {
                logger.log(level: .info, message: "Ignoring stale participant track event participant=\(event.participantId) connection=\(connectionId)")
                return
            }
            await reconcileRemoteScreenShareAfterParticipantCameraEvent(
                connectionId: connectionId,
                participantId: event.participantId
            )
            let deferAttach = await session.shouldDeferSfuGroupParticipantVideoAttach(for: connectionId)

            if let assignmentKey = assignedParticipantKey(matching: event.participantId),
               let assignedView = participantViewAssignments[assignmentKey] {
                if AndroidGroupPostRenegotiationAttachCoordinator.shouldDeferParticipantTrackEventAttach(
                    participantId: event.participantId,
                    episodeParticipantIds: postRenegotiationEpisodeParticipantIds
                ) {
                    logger.log(
                        level: .info,
                        message: "Deferred participant track refresh to post-renegotiation coordinator participant=\(event.participantId)"
                    )
                    await videoCallDelegate?.remoteParticipantTilesDidChange()
                    if !postRenegotiationCoordinatorInFlight {
                        schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
                    }
                    return
                }
                let liveTrack = await session.androidMappedLiveRemoteCameraTrack(
                    connectionId: connectionId,
                    participantId: event.participantId,
                    preferFreshFromPeerConnection: false
                )
                let probe = liveTrack.map {
                    ParticipantRendererAttachSnapshot.from(view: assignedView, track: $0)
                } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                    hasActiveSink: assignedView.hasActiveSink(),
                    rendererLayoutNeedsSinkReconcile: assignedView.rendererLayoutNeedsSinkReconcile(),
                    attachedTrackIsLive: assignedView.attachedTrackIsLive()
                )
                if RTCSession.shouldSkipParticipantTrackReattach(
                    hasActiveSink: probe.hasActiveSink,
                    boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                    rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                    targetTrackIsLive: liveTrack?.isLiveVideoTrack ?? false
                ) {
                    logger.log(
                        level: .info,
                        message: "Skipping participant track refresh; renderer already bound participant=\(event.participantId)"
                    )
                    return
                }
                if deferAttach {
                    assignedView.rendererDidUpdateLayout()
                    notePostRenegotiationEpisodeParticipant(event.participantId, connectionId: connectionId)
                    logger.log(level: .info, message: "Deferred participant track attach during SFU renegotiation participant=\(event.participantId)")
                    await videoCallDelegate?.remoteParticipantTilesDidChange()
                    schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
                    return
                }
                if let liveTrack,
                   !assignedView.attachedTrackSharesRendererSink(with: liveTrack) {
                    participantAttachedTrackIdsByKey.removeValue(
                        forKey: participantAssignmentKey(assignmentKey)
                    )
                }
                let didAttach = await performParticipantVideoAttach(
                    participantId: event.participantId,
                    view: assignedView,
                    connectionId: connectionId,
                    reason: "participant-track-refresh"
                )
                if didAttach {
                    await recordAttachedTrack(connectionId: connectionId, participantId: event.participantId)
                    logger.log(level: .info, message: "Reattached view to refreshed track for participant=\(event.participantId)")
                } else {
                    logger.log(level: .warning, message: "Deferred refreshed track attach for participant=\(event.participantId); waiting for surface or refreshed receiver")
                }
                await videoCallDelegate?.remoteParticipantTilesDidChange()
                return
            }
            guard let view = nextUnassignedRemoteView() else {
                logger.log(level: .warning, message: "No unassigned views for new participant=\(event.participantId)")
                return
            }
            unassignedViews.removeAll { $0 === view }
            assignParticipantView(view, to: event.participantId)
            if deferAttach {
                notePostRenegotiationEpisodeParticipant(event.participantId, connectionId: connectionId)
                logger.log(level: .warning, message: "Assigned view to participant=\(event.participantId) but deferred attach during SFU renegotiation")
                await videoCallDelegate?.remoteParticipantTilesDidChange()
                schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
                return
            }
            if let liveTrack = await session.androidMappedLiveRemoteCameraTrack(
                connectionId: connectionId,
                participantId: event.participantId,
                preferFreshFromPeerConnection: false
            ),
               !view.attachedTrackSharesRendererSink(with: liveTrack) {
                participantAttachedTrackIdsByKey.removeValue(
                    forKey: participantAssignmentKey(event.participantId)
                )
            }
            let didAttach = await performParticipantVideoAttach(
                participantId: event.participantId,
                view: view,
                connectionId: connectionId,
                reason: "participant-track-added"
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: event.participantId)
                logger.log(level: .info, message: "Assigned view to participant=\(event.participantId), remaining unassigned=\(unassignedViews.count)")
            } else {
                logger.log(level: .warning, message: "Assigned view to participant=\(event.participantId) but deferred attach until surface or live track is available")
            }
            await videoCallDelegate?.remoteParticipantTilesDidChange()
        } else {
            logger.log(level: .info, message: "Participant track removed: participant=\(event.participantId)")
            let eventKey = RTCSession.conferenceParticipantIdentityKey(event.participantId)
            let assignmentKey = participantViewAssignments.keys.first { participantId in
                participantId == event.participantId
                    || (!eventKey.isEmpty && RTCSession.conferenceParticipantIdentityKey(participantId) == eventKey)
            }
            guard let assignmentKey,
                  let view = participantViewAssignments[assignmentKey] else {
                return
            }
            await session.removeRemoteForParticipant(
                view: view,
                connectionId: connectionId,
                participantId: event.participantId
            )
            participantAttachedTrackIdsByKey.removeValue(forKey: participantAssignmentKey(assignmentKey))
            participantCoordinatorSettledKeys.remove(participantAssignmentKey(assignmentKey))
            if await shouldReleaseParticipantViewAssignment(
                connectionId: connectionId,
                participantId: event.participantId
            ) {
                participantViewAssignments.removeValue(forKey: assignmentKey)
                if !unassignedViews.contains(where: { $0 === view }) {
                    unassignedViews.append(view)
                }
                await assignExistingParticipantTracks(connectionId: connectionId)
            }
            await videoCallDelegate?.remoteParticipantTilesDidChange()
        }
    }

    /// Sets the view used to render a remote screen share and attaches it to the active screen track.
    public func setScreenView(_ view: AndroidSampleCaptureView) async {
        screenView = view
        guard hasActiveRemoteScreenShare,
              let participantId = activeRemoteScreenShareParticipantId,
              let connectionId = currentCall?.sharedCommunicationId else { return }
        await session.renderRemoteScreenVideo(
            to: view,
            connectionId: connectionId,
            participantId: participantId
        )
    }

    private func reconcileRemoteScreenShareAfterParticipantCameraEvent(
        connectionId: String,
        participantId: String
    ) async {
        guard hasActiveRemoteScreenShare else { return }
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
        if let view = screenView {
            await session.removeRemoteScreenVideoRenderer(
                view,
                connectionId: connectionId,
                participantId: screenParticipantId
            )
        }
        activeRemoteScreenShareParticipantId = nil
        hasActiveRemoteScreenShare = false
        logger.log(
            level: .info,
            message: "Clearing stale remote screen-share UI after participant camera restored participant=\(participantId)"
        )
        await videoCallDelegate?.remoteScreenShareDidChange(participantId: participantId, isSharing: false)
    }

    // MARK: - View Management

    private func createPreviewView(shouldQuery: Bool = true) async {
        guard let connectionId = currentCall?.sharedCommunicationId else {
            logger.log(level: .debug, message: "createPreviewView skipped: missing currentCall")
            return
        }
        guard let localView else {
            logger.log(level: .debug, message: "createPreviewView skipped: missing localView")
            return
        }
        logger.log(level: .info, message: "AndroidVideoCallController creating preview for connection: \(connectionId)")
        await session.renderLocalVideo(to: localView, connectionId: connectionId)
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }

    private func createSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else {
            logger.log(level: .debug, message: "createSampleView skipped: missing currentCall")
            return
        }
        logger.log(level: .info, message: "AndroidVideoCallController creating sample view for connection: \(connectionId)")

        if isGroupCall {
            // For group calls, the participant track stream handles dynamic assignment.
            // Try to assign any already-arrived tracks to views now.
            await assignExistingParticipantTracks(connectionId: connectionId)
        } else {
            // 1:1 call: use the single-track path.
            if let remoteView {
                await session.renderRemoteVideo(to: remoteView, connectionId: connectionId)
            } else if !remoteViews.isEmpty {
                await session.renderRemoteVideo(to: remoteViews[0], connectionId: connectionId)
            } else {
                logger.log(level: .debug, message: "Missing remote views for rendering sample")
            }
        }
        await session.setVideoTrack(isEnabled: true, connectionId: connectionId)
    }

    /// Re-resolves live receiver tracks for every assigned participant tile.
    ///
    /// Grid relayout can resize the first tile after a second participant joins; this keeps
    /// sinks bound to live receivers once the surface dimensions settle.
    func reattachAssignedParticipantVideoIfNeeded() async {
        guard isGroupCall, let connectionId = currentCall?.sharedCommunicationId else { return }
        if AndroidGroupPostRenegotiationAttachCoordinator.shouldDeferGridLayoutReattach(
            episodeActive: isPostRenegotiationAttachEpisodeActive(for: connectionId)
        ) {
            postRenegotiationEpisodeIncludesGridLayout = true
            logger.log(
                level: .info,
                message: "Deferred grid-layout reattach to post-renegotiation coordinator connection=\(connectionId)"
            )
            schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
            return
        }
        for view in participantViewAssignments.values {
            view.rendererDidUpdateLayout()
        }
        if await session.shouldDeferSfuGroupParticipantVideoAttach(for: connectionId) {
            return
        }
        for (participantId, view) in participantViewAssignments {
            let liveTrack = await session.androidMappedLiveRemoteCameraTrack(
                connectionId: connectionId,
                participantId: participantId
            )
            let probe = liveTrack.map {
                ParticipantRendererAttachSnapshot.from(view: view, track: $0)
            } ?? ParticipantRendererAttachSnapshot.withoutLiveTrack(
                hasActiveSink: view.hasActiveSink(),
                rendererLayoutNeedsSinkReconcile: view.rendererLayoutNeedsSinkReconcile(),
                attachedTrackIsLive: view.attachedTrackIsLive()
            )
            if !probe.rendererLayoutNeedsSinkReconcile,
               RTCSession.shouldSkipParticipantTrackReattach(
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererLayoutNeedsSinkReconcile: false,
                targetTrackIsLive: liveTrack?.isLiveVideoTrack ?? false
               ) {
                logger.log(
                    level: .debug,
                    message: "Skipping grid-layout reattach participant=\(participantId) probeActiveSink=\(probe.hasActiveSink) diagnostics=\(view.rendererAttachDiagnosticSummary())"
                )
                continue
            }
            if RTCSession.shouldSkipParticipantTrackReattach(
                hasActiveSink: probe.hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
                rendererLayoutNeedsSinkReconcile: probe.rendererLayoutNeedsSinkReconcile,
                targetTrackIsLive: liveTrack?.isLiveVideoTrack ?? false
            ) {
                logger.log(
                    level: .debug,
                    message: "Skipping grid-layout reattach participant=\(participantId) layoutReconcile=\(probe.rendererLayoutNeedsSinkReconcile) diagnostics=\(view.rendererAttachDiagnosticSummary())"
                )
                continue
            }
            logger.log(
                level: .info,
                message: "Grid-layout reattach participant=\(participantId) probeActiveSink=\(probe.hasActiveSink) probeLayoutReconcile=\(probe.rendererLayoutNeedsSinkReconcile) diagnostics=\(view.rendererAttachDiagnosticSummary())"
            )
            let didAttach = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "grid-layout-reattach"
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
            }
        }
    }

    /// Assigns views to participants whose tracks arrived before the UI was ready.
    private func assignExistingParticipantTracks(connectionId: String) async {
        let normalizedId = connectionId.normalizedConnectionId
        guard let connection = await session.connectionManager.findConnection(with: normalizedId) else { return }
        let deferAttach = await session.shouldDeferSfuGroupParticipantVideoAttach(for: connectionId)

        for participantId in connection.remoteVideoTracksByParticipantId.keys.sorted() {
            guard await shouldSurfaceParticipantTrack(connectionId: connectionId, participantId: participantId) else {
                logger.log(level: .info, message: "Skipping stale participant track assignment participant=\(participantId) connection=\(connectionId)")
                continue
            }
            guard assignedParticipantKey(matching: participantId) == nil else { continue }
            guard let view = nextUnassignedRemoteView() else { break }
            unassignedViews.removeAll { $0 === view }
            assignParticipantView(view, to: participantId)
            if deferAttach {
                notePostRenegotiationEpisodeParticipant(participantId, connectionId: connectionId)
                logger.log(level: .warning, message: "Late-assigned view to participant=\(participantId) but deferred attach during SFU renegotiation")
                await videoCallDelegate?.remoteParticipantTilesDidChange()
                schedulePostRenegotiationAttachCoordinator(connectionId: connectionId)
                continue
            }
            let didAttach = await performParticipantVideoAttach(
                participantId: participantId,
                view: view,
                connectionId: connectionId,
                reason: "late-participant-assignment"
            )
            if didAttach {
                await recordAttachedTrack(connectionId: connectionId, participantId: participantId)
                logger.log(level: .info, message: "Late-assigned view to participant=\(participantId)")
            } else {
                logger.log(level: .warning, message: "Late-assigned view to participant=\(participantId) but deferred attach until surface or live track is available")
            }
            await videoCallDelegate?.remoteParticipantTilesDidChange()
        }
    }

    private func tearDownPreviewView() async {
        guard let connectionId = currentCall?.sharedCommunicationId, let localView else { return }
        await session.removeLocal(view: localView, connectionId: connectionId)
    }

    private func tearDownSampleView() async {
        guard let connectionId = currentCall?.sharedCommunicationId else { return }

        if isGroupCall {
            for (participantId, view) in participantViewAssignments {
                await session.removeRemoteForParticipant(view: view, connectionId: connectionId, participantId: participantId)
            }
            participantViewAssignments.removeAll()
            participantAttachedTrackIdsByKey.removeAll()
            participantVideoAttachInFlightKeys.removeAll()
            participantVideoAttachCoalescedKeys.removeAll()
            unassignedViews.removeAll()
        } else {
            if let remoteView {
                await session.removeRemote(view: remoteView, connectionId: connectionId)
            } else if !remoteViews.isEmpty {
                await session.removeRemote(view: remoteViews[0], connectionId: connectionId)
            }
        }
    }

    // MARK: - Teardown

    private func markCallEndedLocally() {
        guard isRunning else { return }
        isRunning = false
        stopLocalScreenShareStateObservation()
        stopRemoteScreenTrackObservation()
        stopParticipantTrackObservation()
        stopInboundVideoFlowObservation()
        stopPostRenegotiationAttachEpisodeObservation()
        stopSfuGroupSignalingStableObservation()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        screenView = nil
        activeRemoteScreenShareParticipantId = nil
        hasActiveRemoteScreenShare = false
        participantAttachedTrackIdsByKey.removeAll()
        participantRendererRecoveryIssuedKeys.removeAll()
        participantCoordinatorSettledKeys.removeAll()
        postCoordinatorPendingWrapperApplyParticipantKeys.removeAll()
        clearPostRenegotiationAttachEpisode()
        currentCall = nil
    }

    private func tearDownCall() async {
        guard isRunning else { return }
        isRunning = false

        await tearDownPreviewView()
        await tearDownSampleView()
        stopLocalScreenShareStateObservation()
        stopRemoteScreenTrackObservation()
        stopParticipantTrackObservation()
        stopInboundVideoFlowObservation()
        if let view = screenView, let connectionId = currentCall?.sharedCommunicationId {
            await session.removeRemoteScreenVideoRenderer(
                view,
                connectionId: connectionId,
                participantId: activeRemoteScreenShareParticipantId ?? connectionId
            )
        }
        screenView = nil
        activeRemoteScreenShareParticipantId = nil
        hasActiveRemoteScreenShare = false
        participantAttachedTrackIdsByKey.removeAll()
        stateStreamTask?.cancel()
        stateStreamTask = nil
        currentCall = nil
    }
}
#endif
