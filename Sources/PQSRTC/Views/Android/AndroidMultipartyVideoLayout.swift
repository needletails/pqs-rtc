import Foundation

/// Atomic main-thread snapshot for Android participant renderer attach / skip decisions.
public struct ParticipantRendererAttachSnapshot: Sendable {
    public let hasActiveSink: Bool
    public let boundTrackSharesRendererSinkWithTarget: Bool
    public let rendererLayoutNeedsSinkReconcile: Bool
    public let attachedTrackIsLive: Bool

    public init(
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        attachedTrackIsLive: Bool
    ) {
        self.hasActiveSink = hasActiveSink
        self.boundTrackSharesRendererSinkWithTarget = boundTrackSharesRendererSinkWithTarget
        self.rendererLayoutNeedsSinkReconcile = rendererLayoutNeedsSinkReconcile
        self.attachedTrackIsLive = attachedTrackIsLive
    }

    /// Bit flags from native `participantRendererAttachProbeFlags`: 1 = active sink, 2 = shares sink, 4 = layout reconcile, 8 = attached track live.
    public init(nativeProbeFlags: Int) {
        hasActiveSink = (nativeProbeFlags & 1) != 0
        boundTrackSharesRendererSinkWithTarget = (nativeProbeFlags & 2) != 0
        rendererLayoutNeedsSinkReconcile = (nativeProbeFlags & 4) != 0
        attachedTrackIsLive = (nativeProbeFlags & 8) != 0
    }

    #if os(Android)
    /// Builds a snapshot from a remote tile's atomic native probe.
    public static func from(view: AndroidSampleCaptureView, track: RTCVideoTrack) -> ParticipantRendererAttachSnapshot {
        ParticipantRendererAttachSnapshot(nativeProbeFlags: view.participantRendererAttachProbeFlags(with: track))
    }

    /// Fallback when the live peer-connection track is not yet resolved.
    public static func withoutLiveTrack(
        hasActiveSink: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        attachedTrackIsLive: Bool
    ) -> ParticipantRendererAttachSnapshot {
        ParticipantRendererAttachSnapshot(
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererLayoutNeedsSinkReconcile: rendererLayoutNeedsSinkReconcile,
            attachedTrackIsLive: attachedTrackIsLive
        )
    }
    #endif
}

/// Cross-platform SFU group attach defer policy shared by Apple and Android call UIs.
enum GroupSfuVideoAttachPolicy {
    static func shouldDeferParticipantVideoAttach(
        renegotiationInFlight: Bool,
        signalingIsStable: Bool
    ) -> Bool {
        renegotiationInFlight || !signalingIsStable
    }

    /// Newly mapped late joiners emit `RemoteParticipantTrackEvent` during SFU renegotiation.
    /// Those events must be queued for post-settlement refresh: dropping them leaves mapped
    /// tracks with no UI tile when the live wrapper did not need a rebind.
    static func shouldQueueSuppressedParticipantTrackEventForPostRenegotiationRefresh(
        kind: String,
        isActive: Bool,
        renegotiationInFlight: Bool
    ) -> Bool {
        kind == "video" && isActive && renegotiationInFlight
    }

    /// One tile refresh per rebound participant after SFU renegotiation — not every mapped track.
    /// Resolves a single unmapped SFU receiver candidate when stream/msid evidence is missing.
    /// Audio already used this rule; video must match so a lone UUID relay can bind once a key is provisioned.
    static func resolvedUnresolvedSfuReceiverCandidate<C>(
        candidates: [C],
        matchingCandidates: [C],
        advertisedTrackIds: Set<String>,
        sdpTrackIds: Set<String>,
        trackId: (C) -> String
    ) -> C? {
        if matchingCandidates.count == 1 { return matchingCandidates.first }
        if candidates.count == 1 { return candidates.first }
        guard candidates.count > 1 else { return nil }
        if !advertisedTrackIds.isEmpty {
            let matching = candidates.filter { advertisedTrackIds.contains(trackId($0)) }
            if matching.count == 1 { return matching.first }
        }
        if !sdpTrackIds.isEmpty {
            let matching = candidates.filter { sdpTrackIds.contains(trackId($0)) }
            if matching.count == 1 { return matching.first }
        }
        return nil
    }

    /// Rebound wrappers plus participants whose in-flight track events were queued.
    /// Newly mapped late joiners are usually queued, not rebound — omitting the queue
    /// leaves them mapped with no tile after settlement.
    static func participantIdsNeedingPostRenegotiationTileRefresh(
        reboundParticipantIds: Set<String>,
        queuedRefreshParticipantIds: Set<String>,
        allMappedParticipantIds: [String]
    ) -> [String] {
        let targets = reboundParticipantIds.union(queuedRefreshParticipantIds)
        guard !targets.isEmpty else { return [] }
        return allMappedParticipantIds
            .filter { participantId in
                targets.contains {
                    $0 == participantId
                        || (!$0.isEmpty
                            && RTCSession.conferenceParticipantIdentityKey($0)
                                == RTCSession.conferenceParticipantIdentityKey(participantId))
                }
            }
            .sorted()
    }

    /// Channel roster can still list a departed member (`participants=3` after leave).
    /// Visible tiles follow live camera presence: session map or conference video=true.
    /// An explicit leave / pruned map must not keep a tile because `videoEnabled`
    /// or the roster still lists them (Device3 17:52: leave then 20s-late 1:1).
    static func shouldSurfaceParticipantCameraTile(
        hasMappedCamera: Bool,
        conferenceVideoEnabled: Bool,
        explicitlyDeparted: Bool = false
    ) -> Bool {
        if hasMappedCamera { return true }
        if explicitlyDeparted { return false }
        return conferenceVideoEnabled
    }

    /// Track-removed after the session map is pruned is a leave, not wrapper
    /// rotation. Conference `videoEnabled` must not retain that assignment.
    static func shouldForceReleaseAssignmentAfterTrackRemoved(hasMappedCamera: Bool) -> Bool {
        !hasMappedCamera
    }

    /// Transient `isActive: false` during wrapper rotation still has a mapped camera.
    /// Leave prunes the map first, then emits removal — release that tile so 2-up
    /// can return to 1:1. Episode/defer alone must not keep an unmapped leaver.
    static func shouldRetainParticipantTileAcrossTransientTrackRemoval(
        hasMappedOrAdvertisedCamera: Bool,
        episodeActive: Bool,
        deferAttach: Bool,
        hasActiveRemoteScreenShare: Bool
    ) -> Bool {
        guard hasMappedOrAdvertisedCamera else { return false }
        return episodeActive || deferAttach || hasActiveRemoteScreenShare
    }

    /// Free the assignment when live camera presence is gone, even if the
    /// channel roster still contains the secret name.
    static func shouldReleaseParticipantViewAssignment(
        hasMappedOrAdvertisedCamera: Bool,
        stillInRoster: Bool
    ) -> Bool {
        if !hasMappedOrAdvertisedCamera {
            return true
        }
        return !stillInRoster
    }

    /// A leave refresh is only the remaining remotes. Do not `formUnion` the
    /// previous episode set — that re-assigns the departed tile (Device3 nudge).
    static func episodeParticipantIdsAfterRefresh(
        previousIds: Set<String>,
        refreshIds: Set<String>,
        mappedCameraIds: Set<String>,
        identityKey: (String) -> String
    ) -> Set<String> {
        func key(_ participantId: String) -> String {
            let normalized = identityKey(participantId)
            return normalized.isEmpty ? participantId : normalized
        }
        let mappedKeys = Set(mappedCameraIds.map(key))
        let retainedPrevious = previousIds.filter { mappedKeys.contains(key($0)) }
        return retainedPrevious.union(refreshIds)
    }
}

/// Single owner for Android group-call tile binds after SFU renegotiation settles.
enum AndroidGroupPostRenegotiationAttachCoordinator {
    /// Attach reasons suppressed while a post-renegotiation episode is active.
    static func shouldSuppressParticipantVideoAttachReason(_ reason: String, episodeActive: Bool) -> Bool {
        guard episodeActive else { return false }
        switch reason {
        case "post-renegotiation-coordinator",
             "post-renegotiation-grid-layout",
             "post-renegotiation-first-frame-reconcile",
             "coordinator-settlement",
             "coordinator-settled-wrapper-sync",
             "coordinator-finalize-media-ready",
             "coordinator-finalize-pending-wrapper",
             "coordinator-finalize-post-wait-wrapper-sync",
             "late-participant-assignment",
             "screen-share-layout-reattach",
             "screen-share-stop-layout-reattach":
            return false
        default:
            return true
        }
    }

    /// Whether a participant-track event should only update assignment UI during an episode.
    static func shouldDeferParticipantTrackEventAttach(
        participantId: String,
        episodeParticipantIds: Set<String>
    ) -> Bool {
        guard !episodeParticipantIds.isEmpty else { return false }
        let eventKey = RTCSession.conferenceParticipantIdentityKey(participantId)
        return episodeParticipantIds.contains { candidate in
            candidate == participantId
                || (!eventKey.isEmpty
                    && RTCSession.conferenceParticipantIdentityKey(candidate) == eventKey)
        }
    }

    /// Finalize/stabilization must not treat a surfaced participant without an assigned view as media-ready.
    static func coordinatorMediaReadySweepMissingAssignedView(
        shouldSurfaceParticipant: Bool,
        hasAssignedView: Bool,
        participantRequiresVideoBinding: Bool
    ) -> Bool {
        shouldSurfaceParticipant && participantRequiresVideoBinding && !hasAssignedView
    }

    /// Post-coordinator recovery only rebinds tiles the coordinator episode settled; deferred
    /// participant-track-refresh attaches own their tiles after episode clear.
    static func postCoordinatorRecoveryTargetsParticipant(
        coordinatorSettledParticipant: Bool
    ) -> Bool {
        coordinatorSettledParticipant
    }

    /// Pending live-wrapper rebind is event-driven; post-coordinator recovery must not compete
    /// while the tile is still on a live wrapper. A dead attached wrapper must apply now
    /// (Device3 19:09–19:10: pending sat until frames stalled and 1:1 stayed frozen).
    static func postCoordinatorRecoveryShouldDeferToPendingLiveWrapperRebind(
        hasPendingLiveWrapperRebind: Bool,
        attachedTrackIsLive: Bool = true
    ) -> Bool {
        hasPendingLiveWrapperRebind && attachedTrackIsLive
    }

    /// Post-coordinator pending apply retries only after stale-wrapper tail frames stop.
    static func postCoordinatorPendingWrapperApplyShouldRetryWhenStaleTailStopped(
        staleWrapperStillDeliveringRecentFrames: Bool
    ) -> Bool {
        !staleWrapperStillDeliveringRecentFrames
    }

    /// Participant ids that need a coordinated bind, including every assigned tile when grid layout
    /// changed during the same settlement window.
    static func coordinatedAttachParticipantIds(
        episodeParticipantIds: [String],
        assignedParticipantIds: [String],
        includeAllAssignedForGridLayout: Bool
    ) -> [String] {
        var targets = Set(episodeParticipantIds)
        if includeAllAssignedForGridLayout {
            targets.formUnion(assignedParticipantIds)
        }
        return targets.sorted()
    }

    /// Grid relayout during an active episode should be folded into the coordinator pass.
    static func shouldDeferGridLayoutReattach(episodeActive: Bool) -> Bool {
        episodeActive
    }

    /// In-flight coordinator must not queue a rerun for remount / already-settled
    /// / stale-wrapper defer (Device3 17:48–17:51: three-minute begin/end loop).
    /// Only a grown participant set needs another pass.
    static func shouldQueueCoordinatorRerunWhileInFlight(
        participantSetGrew: Bool,
        episodeParticipantsAlreadySettled: Bool
    ) -> Bool {
        participantSetGrew && !episodeParticipantsAlreadySettled
    }

    /// Skip-already-settled must clear the episode. Leaving it active lets every
    /// grid remount schedule the coordinator again.
    static func shouldClearSettledPostRenegotiationEpisode(
        episodeParticipantsAlreadySettled: Bool
    ) -> Bool {
        episodeParticipantsAlreadySettled
    }

    /// A participant that already received a coordinator bind must not be re-attached during the
    /// same episode while the tile is on a live wrapper with the same mapped track id.
    /// A dead Java wrapper after SFU rotation must not skip — wrapper sync or full attach owns recovery.
    static func shouldSkipCoordinatorReattach(
        coordinatorBoundThisEpisode: Bool,
        coordinatorSettledPreviously: Bool,
        attachedTrackId: String?,
        mappedLiveTrackId: String?,
        attachedTrackIsLive: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool
    ) -> Bool {
        if coordinatorBoundThisEpisode {
            return attachedTrackIsLive && rendererHadConfirmedFirstFrameSinceSinkAttach
        }
        guard coordinatorSettledPreviously,
              let attachedTrackId, !attachedTrackId.isEmpty else {
            return false
        }
        guard attachedTrackIsLive else { return false }
        guard let mappedLiveTrackId, !mappedLiveTrackId.isEmpty else {
            // Map can lag behind wrapper sync; only skip while the renderer is still live.
            return true
        }
        return attachedTrackId == mappedLiveTrackId
    }

    /// Skip coordinator full attach only when the tile matches LiveKit-style media-ready state:
    /// live wrapper, active sink on the live target, and at least one confirmed frame.
    static func shouldSkipPostRenegotiationCoordinatorAttach(
        coordinatorBoundThisEpisode: Bool,
        coordinatorSettledPreviously: Bool,
        attachedTrackId: String?,
        mappedLiveTrackId: String?,
        attachedTrackIsLive: Bool,
        probe: ParticipantRendererAttachSnapshot,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        if participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: attachedTrackId,
            mappedLiveTrackId: mappedLiveTrackId,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            attachedTrackIsLive: attachedTrackIsLive
        ) {
            if mappedLiveTrackId == nil || mappedLiveTrackId?.isEmpty == true {
                return false
            }
            if AndroidGroupParticipantRendererAttachPolicy
                .participantRendererStillDeliveringRecentFramesOnStaleWrapper(
                    attachedTrackIsLive: attachedTrackIsLive,
                    hasActiveSink: probe.hasActiveSink,
                    rendererFramesStaleWhileBound: rendererFramesStaleWhileBound,
                    rendererEverConfirmedFirstFrameForAttachedTrack: rendererEverConfirmedFirstFrameForAttachedTrack
                ) {
                return true
            }
            return false
        }
        if shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: coordinatorBoundThisEpisode,
            coordinatorSettledPreviously: coordinatorSettledPreviously,
            attachedTrackId: attachedTrackId,
            mappedLiveTrackId: mappedLiveTrackId,
            attachedTrackIsLive: attachedTrackIsLive,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach
        ) {
            return true
        }
        return AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: probe.attachedTrackIsLive,
            hasActiveSink: probe.hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probe.boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        )
    }

    /// Same negotiated track id but the tile still references a disposed Java wrapper after SFU
    /// receiver rotation. Needs a sink rebind to the live receiver, not a coordinator re-attach.
    static func participantNeedsLiveWrapperSinkRebind(
        attachedTrackId: String?,
        mappedLiveTrackId: String?,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        attachedTrackIsLive: Bool
    ) -> Bool {
        if !attachedTrackIsLive {
            guard let attachedTrackId, !attachedTrackId.isEmpty else { return false }
            if let mappedLiveTrackId, !mappedLiveTrackId.isEmpty, attachedTrackId != mappedLiveTrackId {
                return false
            }
            // Recent frames on a disposed Java wrapper still require rebind to the live receiver
            // even when the probe target is the same stale map instance (sharesSink=true).
            return true
        }
        if hasActiveSink, boundTrackSharesRendererSinkWithTarget { return false }
        guard let attachedTrackId, !attachedTrackId.isEmpty else { return false }
        if let mappedLiveTrackId, !mappedLiveTrackId.isEmpty, attachedTrackId != mappedLiveTrackId {
            return false
        }
        return !hasActiveSink || !boundTrackSharesRendererSinkWithTarget
    }

    /// One pass-end sink rebind for coordinator-bound tiles that still need a live wrapper sink.
    /// Smoothly rendering tiles and same-pass full attaches that already confirmed a first frame on
    /// a live wrapper are left alone. Settled siblings bound to a dead Java wrapper after SFU sync
    /// are rebound once at pass end or during the settled skip path; if the stale wrapper is still
    /// delivering frames, native code queues the live wrapper until those frames stall.
    static func shouldRebindParticipantSinkAfterCoordinatorPass(
        fullAttachedThisCoordinatorPass: Bool,
        attachedTrackId: String?,
        mappedLiveTrackId: String?,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        attachedTrackIsLive: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool = false,
        rendererFramesStaleWhileBound: Bool,
        forceLiveWrapperRecovery: Bool = false
    ) -> Bool {
        if AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return false
        }
        if AndroidGroupParticipantRendererAttachPolicy
            .participantRendererStillDeliveringRecentFramesOnStaleWrapper(
                attachedTrackIsLive: attachedTrackIsLive,
                hasActiveSink: hasActiveSink,
                rendererFramesStaleWhileBound: rendererFramesStaleWhileBound,
                rendererEverConfirmedFirstFrameForAttachedTrack: rendererEverConfirmedFirstFrameForAttachedTrack
            ) {
            return false
        }
        if forceLiveWrapperRecovery,
           participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: attachedTrackId,
            mappedLiveTrackId: mappedLiveTrackId,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            attachedTrackIsLive: attachedTrackIsLive
           ) {
            return true
        }
        // The connection map can briefly hold a newer live platform track before persist catches
        // up after attach. Do not tear down a tile that is still rendering on its live wrapper.
        if attachedTrackIsLive,
           hasActiveSink,
           rendererHadConfirmedFirstFrameSinceSinkAttach,
           !rendererFramesStaleWhileBound,
           !boundTrackSharesRendererSinkWithTarget {
            return false
        }
        // A coordinator full attach in this pass is still warming up until the tile confirms
        // its first frame on a live wrapper that already matches the connection map.
        if fullAttachedThisCoordinatorPass,
           !rendererHadConfirmedFirstFrameSinceSinkAttach,
           hasActiveSink,
           attachedTrackIsLive,
           boundTrackSharesRendererSinkWithTarget {
            return false
        }
        if fullAttachedThisCoordinatorPass,
           rendererHadConfirmedFirstFrameSinceSinkAttach,
           hasActiveSink,
           attachedTrackIsLive,
           boundTrackSharesRendererSinkWithTarget {
            return false
        }
        // Coordinator full attach succeeded this pass; pass-end rebind is redundant even if the
        // active-sink probe is briefly false after the first frame lands.
        if fullAttachedThisCoordinatorPass,
           rendererHadConfirmedFirstFrameSinceSinkAttach,
           attachedTrackIsLive {
            return false
        }
        // Sink probe can look healthy after EGL reinit while the current binding never confirmed
        // a frame; rebind or full attach must still run.
        if attachedTrackIsLive,
           hasActiveSink,
           boundTrackSharesRendererSinkWithTarget,
           !rendererHadConfirmedFirstFrameSinceSinkAttach {
            return true
        }
        return participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: attachedTrackId,
            mappedLiveTrackId: mappedLiveTrackId,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            attachedTrackIsLive: attachedTrackIsLive
        ) || rendererLayoutNeedsSinkReconcile
    }

    /// Reconcile/full attach is unnecessary only while the tile is smoothly rendering.
    /// A previously confirmed first frame is not enough after SFU wrapper rotation because the
    /// attached Java wrapper can be dead while the negotiated track id is unchanged.
    static func shouldSkipPostRenegotiationCoordinatorReconcile(
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        attachedTrackIsLive: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        if rendererLayoutNeedsSinkReconcile {
            return false
        }
        return AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        )
    }

    /// Pass-end rebind for a sibling tile is redundant only while that tile is smoothly rendering.
    static func shouldSkipPassEndSinkRebindAfterSiblingRecovery(
        siblingPassEndRebindConfirmedFirstFrame: Bool,
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        siblingPassEndRebindConfirmedFirstFrame
            && AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
                attachedTrackIsLive: attachedTrackIsLive,
                hasActiveSink: hasActiveSink,
                boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
                rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
                rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
            )
    }

    /// A same-episode rebind is redundant only while the prior rebound is still on the live wrapper.
    static func shouldSuppressAlreadyReboundSinkRebind(
        allowWhenAlreadyReboundThisEpisode: Bool,
        alreadyReboundThisEpisode: Bool,
        hasActiveSink: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        rendererFramesStaleWhileBound: Bool,
        attachedTrackIsLive: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool
    ) -> Bool {
        !allowWhenAlreadyReboundThisEpisode
            && alreadyReboundThisEpisode
            && !rendererLayoutNeedsSinkReconcile
            && attachedTrackIsLive
            && boundTrackSharesRendererSinkWithTarget
            && hasActiveSink
            && !rendererFramesStaleWhileBound
    }

    /// Pass-end stale sweep runs on the first pass, or on the final pass when no rerun is queued.
    static func shouldRunCoordinatorPassStaleSweep(
        passIndex: Int,
        rerunQueued: Bool
    ) -> Bool {
        passIndex == 1 || !rerunQueued
    }

    /// Global connection-map refresh rotates every participant wrapper; during an active episode
    /// only pass 1 may run it. Per-participant fresh PC probes own dead-wrapper recovery afterward.
    static func coordinatorEpisodeUsesGlobalConnectionMapRefresh(passIndex: Int) -> Bool {
        passIndex == 1
    }
}

/// Android group-call attach policy helpers.
enum AndroidGroupParticipantRendererAttachPolicy {
    private static let storedMapAttachReasons: Set<String> = [
        "inbound-render-recovery",
        "post-renegotiation-coordinator",
        "post-renegotiation-first-frame-reconcile",
        "post-renegotiation-grid-layout",
        "participant-track-refresh",
        "coordinator-settlement",
        "grid-layout-reattach",
    ]

    /// Prefer the connection-map track for reasons that must not rotate peer-connection wrappers.
    /// PC refresh on one tile disposes sibling native receivers and causes alternating starvation.
    static func preferFreshPeerConnectionTrack(
        forAttachReason reason: String,
        coordinatorSettledParticipant: Bool = false,
        postRenegotiationEpisodeActive: Bool = false
    ) -> Bool {
        if postRenegotiationEpisodeActive { return false }
        if coordinatorSettledParticipant { return false }
        if storedMapAttachReasons.contains(reason) { return false }
        if reason.hasPrefix("coalesced-") {
            let baseReason = String(reason.dropFirst("coalesced-".count))
            return preferFreshPeerConnectionTrack(
                forAttachReason: baseReason,
                coordinatorSettledParticipant: false,
                postRenegotiationEpisodeActive: postRenegotiationEpisodeActive
            )
        }
        return true
    }

    /// During an active post-renegotiation episode, coordinator attach reasons must bind the
    /// session-stored live wrapper through Kotlin EGL attach — never sink-only PC refresh.
    static func coordinatorEpisodeRequiresSessionStoreEglBind(
        postRenegotiationEpisodeActive: Bool,
        attachReason: String
    ) -> Bool {
        guard postRenegotiationEpisodeActive else { return false }
        return isCoordinatorEpisodeSinkOnlyAttachReason(attachReason)
    }

    /// After SFU receiver rotation the connection map can lag while the tile still paints stale
    /// tail frames. Fresh PC probe is allowed only for EGL bind when the attached wrapper ENDed
    /// and the tile is no longer delivering recent frames on the stale wrapper.
    static func coordinatorEpisodeAllowsFreshPeerConnectionProbeForDeadAttachedWrapper(
        postRenegotiationEpisodeActive: Bool,
        sessionMapTrackIsLive: Bool,
        attachedTrackIsLive: Bool,
        rendererStillDeliveringRecentFramesOnStaleWrapper: Bool = false
    ) -> Bool {
        postRenegotiationEpisodeActive
            && !sessionMapTrackIsLive
            && !attachedTrackIsLive
            && !rendererStillDeliveringRecentFramesOnStaleWrapper
    }

    /// True when the sink is bound to the live wrapper and only needs the first-frame event.
    static func participantTileAwaitingSinkAttachFirstFrame(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool
    ) -> Bool {
        attachedTrackIsLive
            && hasActiveSink
            && boundTrackSharesRendererSinkWithTarget
            && !rendererHadConfirmedFirstFrameSinceSinkAttach
    }

    /// Finalize should not rebind/attach a tile that is already warming up on the live wrapper.
    static func shouldSkipFinalizeMediaReadyPromotion(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererHasDeliveredFramesSinceCurrentSinkAttach: Bool,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        if rendererLayoutNeedsSinkReconcile {
            return false
        }
        return participantTileAwaitingSinkAttachFirstFrameAfterPromotion(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: rendererHasDeliveredFramesSinceCurrentSinkAttach
        )
    }

    /// Finalize should route dead Java wrappers through sink-only live recovery, not destructive attach.
    static func shouldDeferFinalizeMediaReadyToWrapperSync(
        attachedTrackId: String?,
        mappedLiveTrackId: String?,
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool = false,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool = false,
        rendererFramesStaleWhileBound: Bool = false
    ) -> Bool {
        if rendererLayoutNeedsSinkReconcile {
            return false
        }
        if participantRendererStillDeliveringRecentFramesOnStaleWrapper(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound,
            rendererEverConfirmedFirstFrameForAttachedTrack: rendererEverConfirmedFirstFrameForAttachedTrack
                || rendererHadConfirmedFirstFrameSinceSinkAttach
        ) {
            return false
        }
        if isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return false
        }
        return AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: attachedTrackId,
            mappedLiveTrackId: mappedLiveTrackId,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            attachedTrackIsLive: attachedTrackIsLive
        )
    }

    /// Settlement should sink-rebind a dead Java wrapper instead of a full session attach.
    static func coordinatorSettlementPrefersSinkOnlyLiveWrapperRebind(
        attachedTrackId: String?,
        mappedLiveTrackId: String?,
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool
    ) -> Bool {
        AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: attachedTrackId,
            mappedLiveTrackId: mappedLiveTrackId,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            attachedTrackIsLive: attachedTrackIsLive
        )
    }

    static func isCoordinatorSettlementAttachReason(_ reason: String) -> Bool {
        if reason == "coordinator-settlement" { return true }
        if reason.hasPrefix("coalesced-coordinator-settlement") { return true }
        return false
    }

    /// Coordinator-episode attach reasons that should sink-rebind a dead Java wrapper instead of full session attach.
    static func isCoordinatorEpisodeSinkOnlyAttachReason(_ reason: String) -> Bool {
        if isCoordinatorSettlementAttachReason(reason) { return true }
        switch reason {
        case "post-renegotiation-coordinator",
             "post-renegotiation-grid-layout":
            return true
        default:
            break
        }
        if reason.hasPrefix("coalesced-post-renegotiation-coordinator") { return true }
        if reason.hasPrefix("coalesced-post-renegotiation-grid-layout") { return true }
        return false
    }

    /// Finalize must not wrapper-sync again after a successful pending apply in the same finalize
    /// pass already confirmed a first frame on the **current** sink generation. Historical
    /// ever-confirmed state from an earlier pass is not sufficient to clear the episode.
    static func shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
        pendingApplySucceededThisFinalize: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        guard pendingApplySucceededThisFinalize else { return false }
        if rendererLayoutNeedsSinkReconcile { return false }
        return rendererHadConfirmedFirstFrameSinceSinkAttach
    }

    /// Pending apply succeeded but the current sink has not delivered its first frame yet;
    /// finalize must await the EGL callback instead of wrapper-sync churn.
    static func shouldAwaitFinalizeFirstFrameAfterPendingApply(
        pendingApplySucceededThisFinalize: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        guard pendingApplySucceededThisFinalize else { return false }
        if rendererLayoutNeedsSinkReconcile { return false }
        return !rendererHadConfirmedFirstFrameSinceSinkAttach
    }

    /// Settlement attach is redundant when pass-end stale sweep already warmed the tile this episode.
    /// A wrapper that ENDs again before settlement must recover via pending live-wrapper rebind at
    /// finalize, not another fresh-PC sink-only pass that rotates platform identity again.
    /// Requires **current-sink** frame evidence; historical ever-confirmed is insufficient after rotation.
    static func shouldSkipCoordinatorSettlementAfterPassEndWarmth(
        passEndWarmedThisEpisode: Bool,
        attachedTrackIsLive: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        guard passEndWarmedThisEpisode else { return false }
        if rendererLayoutNeedsSinkReconcile { return false }
        if !attachedTrackIsLive { return false }
        return rendererHadConfirmedFirstFrameSinceSinkAttach
    }

    /// Final pass-end rebind is redundant when settlement follows and the tile already has frame evidence.
    static func shouldSkipPassEndSinkRebindBeforeEpisodeSettlement(
        episodeSettlementFollows: Bool,
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererHasDeliveredFramesSinceCurrentSinkAttach: Bool,
        rendererFramesStaleWhileBound: Bool,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        guard episodeSettlementFollows else { return false }
        if rendererLayoutNeedsSinkReconcile { return false }
        if isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return true
        }
        let hasFrameEvidence = rendererHadConfirmedFirstFrameSinceSinkAttach
            || rendererHasDeliveredFramesSinceCurrentSinkAttach
        return hasFrameEvidence && !rendererFramesStaleWhileBound
    }

    /// Finalize churn is redundant after coordinator-settlement sink-only already ran for this tile.
    static func shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
        settlementSinkOnlySucceededThisEpisode: Bool,
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererHasDeliveredFramesSinceCurrentSinkAttach: Bool,
        rendererFramesStaleWhileBound: Bool,
        rendererLayoutNeedsSinkReconcile: Bool
    ) -> Bool {
        guard settlementSinkOnlySucceededThisEpisode else { return false }
        if rendererLayoutNeedsSinkReconcile { return false }
        if rendererFramesStaleWhileBound { return false }
        if isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return true
        }
        if shouldSkipFinalizeMediaReadyPromotion(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: rendererHasDeliveredFramesSinceCurrentSinkAttach,
            rendererLayoutNeedsSinkReconcile: rendererLayoutNeedsSinkReconcile
        ) {
            return true
        }
        // Settlement warmed the tile on a live wrapper; only skip redundant finalize churn while that
        // binding is still intact. A dead wrapper after settlement must recover via finalize sync.
        if !attachedTrackIsLive || !hasActiveSink || !boundTrackSharesRendererSinkWithTarget {
            return false
        }
        return true
    }

    /// EGL is still painting recent frames while the Java wrapper probe reports ENDED.
    static func participantRendererStillDeliveringRecentFramesOnStaleWrapper(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        rendererFramesStaleWhileBound: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool
    ) -> Bool {
        !attachedTrackIsLive
            && hasActiveSink
            && !rendererFramesStaleWhileBound
            && rendererEverConfirmedFirstFrameForAttachedTrack
    }

    /// Defer live-wrapper promotion only while the renderer is still bound to the same live wrapper
    /// the session map expects. During a coordinator episode a rotated wrapper must be swapped
    /// immediately even if the old Java wrapper is still LIVE and painting tail frames.
    /// A dead Java wrapper after leave / SFU prune must not wait for tail frames.
    static func shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
        tileAttachedTrackIsLive: Bool,
        tileHasActiveSink: Bool,
        probeHasActiveSink: Bool,
        probeBoundTrackSharesRendererSinkWithTarget: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        guard tileAttachedTrackIsLive else { return false }
        guard probeBoundTrackSharesRendererSinkWithTarget else { return false }
        let hasSinkEvidence = tileHasActiveSink || probeHasActiveSink
        return hasSinkEvidence
            && rendererEverConfirmedFirstFrameForAttachedTrack
            && !rendererFramesStaleWhileBound
    }

    /// `shouldDefer…` on a shared live sink means leave the tile alone — not queue
    /// `requestPendingLiveWrapperRebind` for a later EGL tear (Device3 19:10:01
    /// pending on a live 1:1 tile, then `egl_reinit_with_track` at 19:10:39).
    static func shouldQueuePendingLiveWrapperRebindAfterSettledSkip(
        tileAttachedTrackIsLive: Bool,
        probeBoundTrackSharesRendererSinkWithTarget: Bool
    ) -> Bool {
        _ = tileAttachedTrackIsLive
        _ = probeBoundTrackSharesRendererSinkWithTarget
        return false
    }

    /// Pass-end stale sweep must not tear down a live tile that full-attached this episode while
    /// current first-frame callbacks are still settling. Dead wrappers are never skipped here.
    static func shouldSkipPassEndStaleWrapperRebindForEpisodeWarmedTile(
        fullAttachedThisCoordinatorPass: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererFramesStaleWhileBound: Bool,
        tileAttachedTrackIsLive: Bool
    ) -> Bool {
        guard tileAttachedTrackIsLive else { return false }
        guard fullAttachedThisCoordinatorPass || rendererEverConfirmedFirstFrameForAttachedTrack else {
            return false
        }
        if rendererHadConfirmedFirstFrameSinceSinkAttach && !rendererFramesStaleWhileBound {
            return true
        }
        return false
    }

    /// Skip settled-participant wrapper sync after SFU map refresh when the tile is still warm.
    static func shouldSkipSettledParticipantLiveWrapperSyncAfterMapRefresh(
        tileAttachedTrackIsLive: Bool,
        tileHasActiveSink: Bool,
        probeHasActiveSink: Bool,
        probeAttachedTrackIsLive: Bool,
        probeBoundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        if shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
            tileAttachedTrackIsLive: tileAttachedTrackIsLive,
            tileHasActiveSink: tileHasActiveSink,
            probeHasActiveSink: probeHasActiveSink,
            probeBoundTrackSharesRendererSinkWithTarget: probeBoundTrackSharesRendererSinkWithTarget,
            rendererEverConfirmedFirstFrameForAttachedTrack: rendererEverConfirmedFirstFrameForAttachedTrack,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return true
        }
        return isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: probeAttachedTrackIsLive,
            hasActiveSink: probeHasActiveSink,
            boundTrackSharesRendererSinkWithTarget: probeBoundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        )
    }

    /// LiveKit-style media-ready: smoothly rendering, or live attached binding with confirmed frames.
    static func participantTileIsMediaReady(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererHasDeliveredFramesSinceCurrentSinkAttach: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        if isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return true
        }
        if participantRendererStillDeliveringRecentFramesOnStaleWrapper(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound,
            rendererEverConfirmedFirstFrameForAttachedTrack: rendererEverConfirmedFirstFrameForAttachedTrack
        ) {
            return true
        }
        let hasSinkFrameEvidence = rendererHadConfirmedFirstFrameSinceSinkAttach
            || rendererHasDeliveredFramesSinceCurrentSinkAttach
        // The probe target can lag the attached live wrapper for a beat after promotion.
        if attachedTrackIsLive
            && hasActiveSink
            && hasSinkFrameEvidence
            && !rendererFramesStaleWhileBound {
            return true
        }
        _ = rendererEverConfirmedFirstFrameForAttachedTrack
        return false
    }

    /// Episode clear requires a live attached wrapper or smoothly rendering — stale-wrapper tail
    /// frames must not satisfy the final sweep while `attachedTrackIsLive` is false, unless a
    /// pending live-wrapper rebind is already queued for post-coordinator completion.
    static func participantTileIsMediaReadyForEpisodeClear(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererHasDeliveredFramesSinceCurrentSinkAttach: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool,
        hasPendingLiveWrapperRebind: Bool = false
    ) -> Bool {
        if hasPendingLiveWrapperRebind {
            return true
        }
        if isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach,
            rendererFramesStaleWhileBound: rendererFramesStaleWhileBound
        ) {
            return true
        }
        let hasSinkFrameEvidence = rendererHadConfirmedFirstFrameSinceSinkAttach
            || rendererHasDeliveredFramesSinceCurrentSinkAttach
        if attachedTrackIsLive
            && hasActiveSink
            && hasSinkFrameEvidence
            && !rendererFramesStaleWhileBound {
            return true
        }
        _ = rendererEverConfirmedFirstFrameForAttachedTrack
        return false
    }

    /// Finalize should not wait for an EGL callback when sink-only rebind is already painting frames.
    static func participantTileAwaitingSinkAttachFirstFrameAfterPromotion(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererHasDeliveredFramesSinceCurrentSinkAttach: Bool
    ) -> Bool {
        if rendererHasDeliveredFramesSinceCurrentSinkAttach {
            return false
        }
        return participantTileAwaitingSinkAttachFirstFrame(
            attachedTrackIsLive: attachedTrackIsLive,
            hasActiveSink: hasActiveSink,
            boundTrackSharesRendererSinkWithTarget: boundTrackSharesRendererSinkWithTarget,
            rendererHadConfirmedFirstFrameSinceSinkAttach: rendererHadConfirmedFirstFrameSinceSinkAttach
        )
    }

    /// A tile that confirmed a first frame on the **current** sink binding must not be re-attached.
    static func isParticipantRendererSmoothlyRendering(
        attachedTrackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrameSinceSinkAttach: Bool,
        rendererFramesStaleWhileBound: Bool
    ) -> Bool {
        attachedTrackIsLive
            && rendererHadConfirmedFirstFrameSinceSinkAttach
            && hasActiveSink
            && boundTrackSharesRendererSinkWithTarget
            && !rendererFramesStaleWhileBound
    }
}

/// Android group-call renderer recovery when inbound decode advances but tiles stop rendering.
enum AndroidGroupParticipantRendererRecoveryPolicy {
    static func shouldRequestSinkRefresh(
        inboundDeltaFramesDecoded: Int64,
        inboundDeltaPacketsReceived: Int64,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererHadConfirmedFirstFrame: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        rendererHasPendingTrackBind: Bool,
        recoveryAlreadyIssuedForStallEpisode: Bool,
        hasLiveTrack: Bool,
        attachedTrackIsLive: Bool = true,
        coordinatorSettledParticipant: Bool = false
    ) -> Bool {
        guard !recoveryAlreadyIssuedForStallEpisode else { return false }
        guard inboundDeltaFramesDecoded > 0 || inboundDeltaPacketsReceived > 0 else { return false }
        guard hasLiveTrack else { return false }

        if !rendererEverConfirmedFirstFrameForAttachedTrack {
            if rendererLayoutNeedsSinkReconcile || rendererHasPendingTrackBind {
                return false
            }
            return !hasActiveSink || !boundTrackSharesRendererSinkWithTarget
        }

        if coordinatorSettledParticipant {
            if rendererEverConfirmedFirstFrameForAttachedTrack {
                // Coordinator binds are owned by wrapper/layout/sibling refresh events. The aggregate
                // inbound sampler cannot identify which participant advanced.
                if !attachedTrackIsLive, !boundTrackSharesRendererSinkWithTarget {
                    return true
                }
                return rendererFramesStaleWhileBound
                    && !boundTrackSharesRendererSinkWithTarget
            }
            if !attachedTrackIsLive || !boundTrackSharesRendererSinkWithTarget {
                return true
            }
            if rendererLayoutNeedsSinkReconcile || rendererHasPendingTrackBind {
                return false
            }
            return !hasActiveSink || !boundTrackSharesRendererSinkWithTarget
        } else if rendererEverConfirmedFirstFrameForAttachedTrack, !rendererFramesStaleWhileBound {
            // A dead attached wrapper (`attached_track_not_live`) can stall before the 6s frame
            // stale threshold. `hasActiveSink` stays true while recent stale frames remain visible.
            if !attachedTrackIsLive, !boundTrackSharesRendererSinkWithTarget {
                return true
            }
            if hasActiveSink { return false }
        }

        // Compose grid relayout and surface lifecycle temporarily detach sinks; native reconcile owns recovery.
        if rendererLayoutNeedsSinkReconcile || rendererHasPendingTrackBind,
           !rendererFramesStaleWhileBound {
            return false
        }

        if rendererHadConfirmedFirstFrame {
            if !hasActiveSink { return true }
            return rendererFramesStaleWhileBound
        }
        return !hasActiveSink || !boundTrackSharesRendererSinkWithTarget
    }

    /// Per-tile recovery when aggregate inbound stats cannot identify which participant stalled.
    static func shouldRequestSinkRefreshForLocalTileState(
        attachedTrackIsLive: Bool,
        hasLiveTrack: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererEverConfirmedFirstFrameForAttachedTrack: Bool,
        rendererFramesStaleWhileBound: Bool,
        rendererLayoutNeedsSinkReconcile: Bool,
        rendererHasPendingTrackBind: Bool,
        recoveryAlreadyIssuedForStallEpisode: Bool
    ) -> Bool {
        guard !recoveryAlreadyIssuedForStallEpisode else { return false }
        guard hasLiveTrack else { return false }
        if rendererLayoutNeedsSinkReconcile || rendererHasPendingTrackBind {
            return false
        }
        if !attachedTrackIsLive {
            return true
        }
        if rendererEverConfirmedFirstFrameForAttachedTrack, rendererFramesStaleWhileBound {
            return true
        }
        if rendererEverConfirmedFirstFrameForAttachedTrack,
           attachedTrackIsLive,
           hasActiveSink,
           !boundTrackSharesRendererSinkWithTarget {
            return true
        }
        return false
    }
}

/// Apple group-call remote camera renderer attach dedupe policy.
enum AppleRemoteVideoTrackAttachPolicy {
    /// Identity for a live camera sink. Track-object identity is required so a rotated
    /// WebRTC wrapper with the same `trackId` + mid is not treated as already bound.
    static func participantRendererAttachmentValue(
        trackId: String,
        receivingMid: String,
        trackObjectIdentity: String,
        rendererObjectIdentity: String
    ) -> String {
        "\(trackId)|mid:\(receivingMid)|track:\(trackObjectIdentity)|\(rendererObjectIdentity)"
    }

    /// Skip redundant renderer binds when the cache matches the live peer-connection receiver.
    static func shouldSkipParticipantRendererAttach(
        cachedAttachmentValue: String?,
        liveAttachmentValue: String
    ) -> Bool {
        guard let cachedAttachmentValue else { return false }
        return cachedAttachmentValue == liveAttachmentValue
    }

    /// Silent connection-map refresh during SFU renegotiation; tile refresh only on real drift/removal.
    static func shouldNotifyParticipantTrackRefreshAfterRenegotiation(
        storedTrackId: String?,
        liveTrackId: String?,
        storedReceiverEnded: Bool
    ) -> Bool {
        if storedReceiverEnded { return true }
        guard let liveTrackId, !liveTrackId.isEmpty else { return true }
        guard let storedTrackId, !storedTrackId.isEmpty else { return true }
        return storedTrackId != liveTrackId
    }
}

/// Pure layout/reconcile policy for Android multiparty remote video grids.
enum AndroidMultipartyVideoLayout {
    /// How many remote renderer slots Compose should mount.
    ///
    /// Channel roster / pool size (`remoteSlotCount`) must not reserve empty tiles. iOS
    /// `updateLayoutForItemCount` follows live assigned remotes: 1 → fullscreen, 2+ → grid.
    static func visibleRemoteViewCount(
        remoteSlotCount: Int,
        assignedParticipantCount: Int,
        poolSize: Int
    ) -> Int {
        _ = remoteSlotCount
        return multipartyGridSlotCount(
            assignedParticipantCount: assignedParticipantCount,
            poolSize: poolSize
        )
    }

    /// Visible slot count after a roster/SFU refresh. A leave that leaves one assigned
    /// remote must return to 1-up; keeping the previous N-up count is what stuck Android
    /// on two 16:9 tiles with one live stream.
    static func stableVisibleRemoteViewCount(
        previousVisibleCount: Int,
        requestedVisibleCount: Int,
        assignedParticipantCount: Int,
        poolSize: Int
    ) -> Int {
        _ = previousVisibleCount
        _ = requestedVisibleCount
        return multipartyGridSlotCount(
            assignedParticipantCount: assignedParticipantCount,
            poolSize: poolSize
        )
    }

    /// How many Compose tiles to mount. Extra pool renderers stay allocated off-tree.
    static func multipartyGridSlotCount(
        assignedParticipantCount: Int,
        poolSize: Int
    ) -> Int {
        guard poolSize > 0 else { return 0 }
        return min(max(assignedParticipantCount, 1), poolSize)
    }

    /// Views Compose may mount. Assigned remotes only; if none yet, one waiting pool slot.
    /// Never returns leftover unassigned pool siblings — those become empty 16:9 tiles.
    static func mountedRemoteViews<View>(
        assignedViews: [View],
        poolViews: [View]
    ) -> [View] {
        if !assignedViews.isEmpty {
            return assignedViews
        }
        guard let first = poolViews.first else { return [] }
        return [first]
    }

    /// Whether assigned participant tiles should be re-rendered after a grid refresh.
    static func shouldReattachAssignedParticipantVideo(
        previousVisibleCount: Int,
        nextVisibleCount: Int,
        previousSignature: String,
        nextSignature: String
    ) -> Bool {
        if previousSignature != nextSignature {
            return true
        }
        if previousVisibleCount != nextVisibleCount {
            return true
        }
        return false
    }

    /// Native `attach()` can queue a track while the surface is still 0×0. Only count the bind
    /// as complete once the sink is live.
    static func participantRendererAttachSucceeded(
        attachAcknowledged: Bool,
        hasActiveSink: Bool
    ) -> Bool {
        attachAcknowledged && hasActiveSink
    }

    /// Queued attaches should not be treated as successful acknowledgements.
    static func participantRendererAttachAcknowledged(
        attachReturned: Bool,
        hasActiveSink: Bool
    ) -> Bool {
        guard attachReturned else { return false }
        return hasActiveSink
    }
}

/// Event-driven 1-up ↔ N-up Android grid settlement. Destination layouts stay
/// unchanged; only the handoff waits for Compose `AndroidView.update`.
struct GridSlotLayoutTransitionState: Equatable, Sendable {
    var generation: UInt64
    var expectedIdentities: Set<String>
    var reportedIdentities: Set<String>

    init(
        generation: UInt64 = 0,
        expectedIdentities: Set<String> = [],
        reportedIdentities: Set<String> = []
    ) {
        self.generation = generation
        self.expectedIdentities = expectedIdentities
        self.reportedIdentities = reportedIdentities
    }

    static let idle = GridSlotLayoutTransitionState()

    var isAwaiting: Bool {
        !expectedIdentities.isEmpty
    }
}

enum AndroidRemoteGridTransitionPolicy {
    /// Skip `AndroidView` identity for one SurfaceView. Solo and grid must differ
    /// so 2-up → 1:1 remounts the view under `fillMaxSize`. Keying only the
    /// renderer hash reused the 317×564 letterbox after `mounted count=1`
    /// (Device3 21:35:50–21:36:17).
    static func composeTileKey(rendererIdentity: Int, itemCount: Int) -> Int {
        if itemCount <= 1 {
            return rendererIdentity
        }
        return rendererIdentity &* 31 &+ 2
    }

    /// Wait only when the grid *grows*. Shrink (2-up → 1:1) keeps the remaining
    /// sink; waiting stomps `layoutGeneration` (Device3 19:09:40 gen 2/3/4 in
    /// one ms) and freezes the leftover remote until the coordinator attaches.
    static func shouldWaitForComposeLayoutBeforeReattach(
        previousVisibleCount: Int,
        nextVisibleCount: Int
    ) -> Bool {
        previousVisibleCount > 0 && nextVisibleCount > previousVisibleCount
    }

    /// Immediate reattach is only safe when the mounted slot count did not change.
    static func shouldReattachAssignedTilesImmediately(
        previousVisibleCount: Int,
        nextVisibleCount: Int,
        previousSignature: String,
        nextSignature: String
    ) -> Bool {
        if shouldWaitForComposeLayoutBeforeReattach(
            previousVisibleCount: previousVisibleCount,
            nextVisibleCount: nextVisibleCount
        ) {
            return false
        }
        return AndroidMultipartyVideoLayout.shouldReattachAssignedParticipantVideo(
            previousVisibleCount: previousVisibleCount,
            nextVisibleCount: nextVisibleCount,
            previousSignature: previousSignature,
            nextSignature: nextSignature
        )
    }

    /// Roster growth must reuse the same `AndroidVideoCallView` identity / renderer pool.
    static func shouldResetVideoCallViewIdentityOnRemoteCountChange() -> Bool {
        false
    }

    /// Hangup unmounts the call view after chrome already hid the local PiP
    /// (`showsLocalPreview=false`) while `callState` can still be `Connected`.
    /// Rotation remounts with `showsLocalPreview=true`. Minimize / in-app PiP
    /// keep the view mounted. Device3 2026-09-08: skip on `onDisappear
    /// state=Connected` left `LocalPreviewDuration` ticking after the call ended.
    static func shouldTeardownRenderersOnDisappear(
        didEnterLiveCall: Bool,
        showsLocalPreview: Bool,
        endedCall: Bool,
        isTerminalCallState: Bool,
        isIdleAfterLiveCall: Bool
    ) -> Bool {
        if endedCall || isTerminalCallState || isIdleAfterLiveCall {
            return true
        }
        return didEnterLiveCall && !showsLocalPreview
    }

    static func beginGridSlotTransition(
        state: GridSlotLayoutTransitionState,
        expectedIdentities: Set<String>
    ) -> GridSlotLayoutTransitionState {
        if state.isAwaiting, state.expectedIdentities == expectedIdentities {
            return state
        }
        return GridSlotLayoutTransitionState(
            generation: state.generation &+ 1,
            expectedIdentities: expectedIdentities,
            reportedIdentities: []
        )
    }

    static func shouldAcceptGridSlotSurfaceReport(
        capturedGeneration: UInt64,
        identity: String,
        state: GridSlotLayoutTransitionState
    ) -> Bool {
        guard state.isAwaiting else { return false }
        guard capturedGeneration == state.generation else { return false }
        return state.expectedIdentities.contains(identity)
    }

    static func applyingGridSlotSurfaceReport(
        capturedGeneration: UInt64,
        identity: String,
        state: GridSlotLayoutTransitionState
    ) -> GridSlotLayoutTransitionState {
        guard shouldAcceptGridSlotSurfaceReport(
            capturedGeneration: capturedGeneration,
            identity: identity,
            state: state
        ) else {
            return state
        }
        var next = state
        next.reportedIdentities.insert(identity)
        guard next.expectedIdentities.isSubset(of: next.reportedIdentities) else {
            return next
        }
        next.expectedIdentities.removeAll()
        next.reportedIdentities.removeAll()
        return next
    }
}

/// Swift-side mirror of `AndroidReceiverCryptorPolicy` in Skip/Kotlin (kept in sync for tests).
enum AndroidReceiverCryptorPolicy {
    static func shouldReuseReceiverCryptorBinding(
        existingTrackId: String?,
        newTrackId: String,
        existingReceiverKey: String?,
        newReceiverKey: String
    ) -> Bool {
        guard !newTrackId.isEmpty, !newReceiverKey.isEmpty else { return false }
        return existingTrackId == newTrackId && existingReceiverKey == newReceiverKey
    }

    /// Audio FrameCryptor is bound to the native receiver, not the Java wrapper identity.
    /// Requiring `receiverKey` equality mute-disposes on every SFU offer and chirps playout.
    static func shouldReuseAudioReceiverCryptorBinding(
        existingTrackId: String?,
        newTrackId: String
    ) -> Bool {
        guard !newTrackId.isEmpty else { return false }
        return existingTrackId == newTrackId
    }

    /// Audio FrameCryptor attach after an SFU offer. Same advertised track id means the live
    /// cryptor is already bound; calling attach again mutes playout for a Java wrapper refresh.
    static func shouldAttachAndroidSfuAudioReceiverCryptorAfterSdp(
        existingTrackId: String?,
        advertisedTrackId: String
    ) -> Bool {
        guard !advertisedTrackId.isEmpty else { return false }
        guard let existingTrackId, !existingTrackId.isEmpty else { return true }
        return existingTrackId != advertisedTrackId
    }
}

/// Track attach policy for Android remote participant renderers.
enum AndroidRemoteVideoTrackAttachPolicy {
    static func tracksShareEffectiveNativeSource(
        lhsTrackId: String?,
        rhsTrackId: String?,
        lhsIsLive: Bool,
        rhsIsLive: Bool,
        platformTracksIdentical: Bool
    ) -> Bool {
        if platformTracksIdentical { return true }
        guard lhsIsLive, rhsIsLive else { return false }
        guard let lhsTrackId, let rhsTrackId,
              !lhsTrackId.isEmpty, !rhsTrackId.isEmpty else { return false }
        return lhsTrackId == rhsTrackId
    }

    static func shouldPreferLiveRemoteVideoTrack(
        hasMappedTrack: Bool,
        mappedTrackId: String?,
        mappedIsLive: Bool,
        liveTrackId: String?
    ) -> Bool {
        guard hasMappedTrack else { return true }
        guard mappedIsLive else { return true }
        guard let liveTrackId, !liveTrackId.isEmpty else { return false }
        guard let mappedTrackId, !mappedTrackId.isEmpty else { return true }
        return mappedTrackId != liveTrackId
    }

    static func receiverTrackDriftedAfterRenegotiation(
        storedTrackId: String?,
        liveTrackId: String?,
        storedIsLive: Bool
    ) -> Bool {
        if !storedIsLive { return true }
        guard let liveTrackId, !liveTrackId.isEmpty else { return false }
        guard let storedTrackId, !storedTrackId.isEmpty else { return true }
        return storedTrackId != liveTrackId
    }

    /// Connection map should track the live peer-connection receiver even when the negotiated id is stable.
    static func needsAndroidRemoteCameraConnectionMapRefresh(
        storedTrackId: String?,
        liveTrackId: String?,
        storedIsLive: Bool,
        platformTracksIdentical: Bool
    ) -> Bool {
        if receiverTrackDriftedAfterRenegotiation(
            storedTrackId: storedTrackId,
            liveTrackId: liveTrackId,
            storedIsLive: storedIsLive
        ) {
            return true
        }
        return !platformTracksIdentical
    }

    /// Renderer sinks bind to a concrete native `VideoTrack` instance, not just the negotiated id.
    static func tracksShareRendererSinkSource(platformTracksIdentical: Bool) -> Bool {
        platformTracksIdentical
    }

    /// Prefer the live peer-connection receiver over a cached map wrapper after SFU renegotiation.
    static func shouldPreferPeerConnectionAttachTrack(
        mappedTrackPlatformIdenticalToLive: Bool
    ) -> Bool {
        !mappedTrackPlatformIdenticalToLive
    }

    /// SFU wrapper rotation must reinitialize EGL; sink-only swaps freeze after the next rotation.
    static func requiresRendererEglReinitForWrapperRefresh(reason: String) -> Bool {
        reason == "SFU track wrapper refresh" ||
            reason == "stale wrapper surface reconcile" ||
            reason == "pending live wrapper reconcile"
    }

    /// Skip redundant renderer binds only when the tile sink is on the same native receiver
    /// instance and has rendered at least one frame.
    static func shouldInvokeParticipantRendererAttach(
        trackIsLive: Bool,
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererLayoutNeedsSinkReconcile: Bool = false,
        rendererHasPendingTrackBind: Bool = false,
        rendererHadConfirmedFirstFrame: Bool = false
    ) -> Bool {
        if rendererLayoutNeedsSinkReconcile || rendererHasPendingTrackBind { return true }
        if hasActiveSink, !trackIsLive { return false }
        if trackIsLive,
           hasActiveSink,
           boundTrackSharesRendererSinkWithTarget,
           rendererHadConfirmedFirstFrame {
            return false
        }
        return trackIsLive
    }

    /// A stale Java wrapper must not tear down an already-live sink for the same track id.
    /// Preserve only when the tile sink is on the same native receiver instance as the live stream.
    static func shouldPreserveActiveSinkWhenStaleWrapperArrives(
        hasActiveSink: Bool,
        attachedTrackId: String?,
        staleTrackId: String,
        boundTrackSharesRendererSinkWithTarget: Bool = false
    ) -> Bool {
        guard hasActiveSink, boundTrackSharesRendererSinkWithTarget else { return false }
        guard let attachedTrackId, !attachedTrackId.isEmpty else { return true }
        return attachedTrackId == staleTrackId
    }

    /// Tile refresh events are emitted once after renegotiation completes. Mid-renegotiation map
    /// refresh is silent so each remote sink is not torn down repeatedly.
    static func shouldNotifyParticipantTrackRefreshAfterRenegotiation(
        storedTrackId: String?,
        liveTrackId: String?,
        storedIsLive: Bool
    ) -> Bool {
        receiverTrackDriftedAfterRenegotiation(
            storedTrackId: storedTrackId,
            liveTrackId: liveTrackId,
            storedIsLive: storedIsLive
        )
    }
}

/// Remote renderer orientation policy for Android participant tiles.
enum AndroidRemoteVideoRenderPolicy {
    /// Cross-platform remote streams (e.g. iPad landscape) carry rotation metadata that must be
    /// normalized to upright pixels before aspect-fit scaling. Local preview uses a separate path.
    static func normalizesIncomingFramesToUpright(forRemoteParticipantTile: Bool) -> Bool {
        forRemoteParticipantTile
    }
}

/// Native renderer layout reconcile policy for Android sample capture views.
enum AndroidRendererLayoutPolicy {
    static func shouldReconcileAfterLayoutChange(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
        hasPendingTrack: Bool,
        rendererHasSink: Bool,
        hasAttachedTrack: Bool
    ) -> Bool {
        guard newWidth > 0, newHeight > 0 else { return false }
        let dimensionsChanged = previousWidth != newWidth || previousHeight != newHeight
        if dimensionsChanged { return true }
        if !hasPendingTrack && rendererHasSink { return false }
        if !hasPendingTrack && !hasAttachedTrack { return false }
        if hasPendingTrack || !rendererHasSink {
            return true
        }
        return false
    }

    /// Whether EGL was last initialized at a different holder size than the current surface.
    static func rendererEglInitStaleForSurface(
        eglInitWidth: Int,
        eglInitHeight: Int,
        surfaceWidth: Int,
        surfaceHeight: Int
    ) -> Bool {
        guard eglInitWidth > 0, eglInitHeight > 0, surfaceWidth > 0, surfaceHeight > 0 else {
            return false
        }
        return eglInitWidth != surfaceWidth || eglInitHeight != surfaceHeight
    }

    /// Measured tile size diverged from the last reported SurfaceHolder dimensions.
    static func rendererSurfaceLayoutIsDrifted(
        viewWidth: Int,
        viewHeight: Int,
        surfaceWidth: Int,
        surfaceHeight: Int
    ) -> Bool {
        guard viewWidth > 0, viewHeight > 0, surfaceWidth > 0, surfaceHeight > 0 else {
            return false
        }
        return viewWidth != surfaceWidth || viewHeight != surfaceHeight
    }

    /// Device rotation changes both axes at once. Holder/OnLayout callbacks fire for
    /// intermediate sizes; EGL reinit there starves the shared local-preview context.
    static func isLikelyTransientRotationSurfaceMeasure(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int
    ) -> Bool {
        previousWidth > 0
            && previousHeight > 0
            && newWidth > 0
            && newHeight > 0
            && previousWidth != newWidth
            && previousHeight != newHeight
    }

    /// 1-up leftover: Compose still measures the remote at the window before the
    /// 16:9 conference tile lands. Wrapping there letterboxes the fullscreen pane.
    static func isLikelyFullscreenHost(
        hostWidth: Int,
        hostHeight: Int,
        windowWidth: Int,
        windowHeight: Int
    ) -> Bool {
        guard hostWidth > 0, hostHeight > 0, windowWidth > 0, windowHeight > 0 else {
            return false
        }
        return hostWidth * 10 >= windowWidth * 9 && hostHeight * 10 >= windowHeight * 9
    }

    /// Rotation fragments (Device3: 155×275, 488×275) are far smaller than a 2-up tile.
    static func isLikelyUnsettledFragmentHost(
        hostWidth: Int,
        hostHeight: Int,
        windowWidth: Int,
        windowHeight: Int
    ) -> Bool {
        guard hostWidth > 0, hostHeight > 0, windowWidth > 0, windowHeight > 0 else {
            return true
        }
        return hostWidth * hostHeight * 8 < windowWidth * windowHeight
    }

    /// Keep MATCH_PARENT during rotation fragments and 1-up leftover fullscreen.
    /// A settled 16:9 conference tile (Device3 1002×564) must letterbox in that
    /// same apply — dual-axis from 1080×2520 used to defer, then hop 1002 fill → 317.
    static func shouldDeferAspectFitWrapContent(
        preferFit: Bool,
        windowOrientationMatchesConfiguration: Bool,
        hostWidth: Int,
        hostHeight: Int,
        windowWidth: Int,
        windowHeight: Int,
        previousHostWidth: Int,
        previousHostHeight: Int
    ) -> Bool {
        _ = previousHostWidth
        _ = previousHostHeight
        if !preferFit { return false }
        if !windowOrientationMatchesConfiguration { return true }
        if hostWidth <= 0 || hostHeight <= 0 { return true }
        if isLikelyFullscreenHost(
            hostWidth: hostWidth,
            hostHeight: hostHeight,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        ) {
            return true
        }
        if isLikelyUnsettledFragmentHost(
            hostWidth: hostWidth,
            hostHeight: hostHeight,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        ) {
            return true
        }
        return false
    }

    /// Fitted letterbox size so the SurfaceView can use EXACT pixels instead of
    /// WRAP_CONTENT (VideoLayoutMeasure remasures on every frame-resolution callback).
    static func letterboxExactSize(
        frameWidth: Int,
        frameHeight: Int,
        frameRotation: Int,
        hostWidth: Int,
        hostHeight: Int
    ) -> (width: Int, height: Int) {
        guard frameWidth > 0, frameHeight > 0, hostWidth > 0, hostHeight > 0 else {
            return (0, 0)
        }
        var rotation = frameRotation % 360
        if rotation < 0 { rotation += 360 }
        let uprightWidth = (rotation == 90 || rotation == 270) ? frameHeight : frameWidth
        let uprightHeight = (rotation == 90 || rotation == 270) ? frameWidth : frameHeight
        if uprightWidth * hostHeight > uprightHeight * hostWidth {
            let fittedHeight = max(1, hostWidth * uprightHeight / uprightWidth)
            return (hostWidth, min(hostHeight, fittedHeight))
        }
        let fittedWidth = max(1, hostHeight * uprightWidth / uprightHeight)
        return (min(hostWidth, fittedWidth), hostHeight)
    }

    /// Wrap-content letterbox inside a 16:9 Compose tile (Device3: host 1002×564,
    /// SurfaceView 317×564 = 9:16 of the tile height). That is not a new EGL surface.
    static func isLikelyAspectFitWrapSurfaceMeasure(
        surfaceWidth: Int,
        surfaceHeight: Int,
        tileWidth: Int,
        tileHeight: Int
    ) -> Bool {
        guard surfaceWidth > 0, surfaceHeight > 0, tileWidth > 0, tileHeight > 0 else {
            return false
        }
        if surfaceWidth == tileWidth && surfaceHeight == tileHeight {
            return false
        }
        if surfaceWidth > tileWidth || surfaceHeight > tileHeight {
            return false
        }
        return (surfaceWidth == tileWidth && surfaceHeight < tileHeight)
            || (surfaceHeight == tileHeight && surfaceWidth < tileWidth)
    }

    /// Holder-callback reinit. Dual-axis measures are rotation or 1-up ↔ N-up
    /// intermediates — never tear the sink here. Wrap-content letterbox inside the
    /// host tile is also not a new surface. One-axis tile splits may reinit only
    /// when the holder already matches the Compose host.
    static func shouldReinitRendererEglForImmediateHolderResize(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
        windowOrientationMatchesConfiguration: Bool = false,
        tileWidth: Int = 0,
        tileHeight: Int = 0
    ) -> Bool {
        _ = windowOrientationMatchesConfiguration
        guard newWidth > 0, newHeight > 0 else { return false }
        guard previousWidth > 0, previousHeight > 0 else { return false }
        if previousWidth == newWidth && previousHeight == newHeight { return false }
        if isLikelyTransientRotationSurfaceMeasure(
            previousWidth: previousWidth,
            previousHeight: previousHeight,
            newWidth: newWidth,
            newHeight: newHeight
        ) {
            return false
        }
        if isLikelyAspectFitWrapSurfaceMeasure(
            surfaceWidth: newWidth,
            surfaceHeight: newHeight,
            tileWidth: tileWidth,
            tileHeight: tileHeight
        ) {
            return false
        }
        if tileWidth > 0, tileHeight > 0,
           newWidth != tileWidth || newHeight != tileHeight {
            return false
        }
        return true
    }

    /// Local PiP must not be a `VideoTrack` sink. Device3: camera 15 fps,
    /// LocalPreview received 7 fps with 0 drops — the encoder VideoSource
    /// adapter was starving the preview. Fan out from the capturer instead.
    static var bindsLocalPreviewToVideoTrackSink: Bool { false }

    static var fansOutLocalPreviewFromCapturerObserver: Bool { true }

    /// Apple local preview is `AVCaptureVideoPreviewLayer` (hardware). Android
    /// must not treat I420→TextureView EGL as that path: Device3 07:45 locked
    /// Camera/LocalPreview at 30 fps / 0 drops and still looked skippy.
    /// Requesting 15 locks Camera2 to `[15.0:15.0]` (Device3 06:11:09). 30
    /// selects `[15.0:30.0]`; WebRTC prefers a low min (06:51: 17–26 fps).
    /// First frame rewrites AE to `[30:30]`. Device3 09:49 proved a second
    /// Camera2 output on the TextureView: 90°, undersized, still skippy.
    /// Camera TextureBuffer fanout + shared-EGL is the local PiP path.
    /// I420+EGL still skipped at 30/0/30 (Device3 13:16). Send encodings still
    /// follow ``RTCVideoQualityProfile``.
    static var androidLocalCameraCaptureFps: Int { 30 }

    /// Local overlay fans TextureBuffer when softening is off. When Settings
    /// softening is on, the worker delivers I420Softened to preview and send.
    static var androidLocalPreviewFansOutBeforeAppearanceSoftening: Bool { true }

    /// Device3 09:49: Camera2 → TextureView attached and looked worse.
    static var androidLocalPreviewUsesCamera2OutputSurface: Bool { false }

    /// WebRTC's closest-range picker will not choose `[30:30]` when `[15:30]`
    /// exists. Lock AE after the Camera2 session is running.
    static var androidLocksCamera2FixedCaptureFps: Bool { true }

    /// Local PiP is a SurfaceView media overlay (Device3 16:20: TextureView
    /// over the remote hole-punch still skipped at 30/0/30).
    static var androidLocalPreviewTextureViewIsOpaque: Bool { true }

    static var androidLocalPreviewUsesSurfaceViewOverlay: Bool { true }

    /// Local PiP overlay. Ignore GeometryReader blips during rotation; apply on
    /// orientation-class change or a real size jump.
    static func shouldReplaceLocalPreviewOverlaySize(
        currentWidth: Double,
        currentHeight: Double,
        proposedWidth: Double,
        proposedHeight: Double,
        minimumDelta: Double = 12
    ) -> Bool {
        if currentWidth <= 1 || currentHeight <= 1 { return proposedWidth > 1 && proposedHeight > 1 }
        if proposedWidth <= 1 || proposedHeight <= 1 { return false }
        let currentLandscape = currentWidth > currentHeight
        let proposedLandscape = proposedWidth > proposedHeight
        if currentLandscape != proposedLandscape { return true }
        // Both overlay axes moving is a rotation intermediate (140×249 → 180×220).
        // Apply only the orientation-class flip, not every GeometryReader blip.
        if abs(currentWidth - proposedWidth) >= 0.5
            && abs(currentHeight - proposedHeight) >= 0.5 {
            return false
        }
        return abs(currentWidth - proposedWidth) >= minimumDelta
            || abs(currentHeight - proposedHeight) >= minimumDelta
    }

    /// Attach / sink-reconcile must not tear EGL on the same dual-axis hop that
    /// `surface_holder_rotation_skip` already declined. Device3 17:49: skip
    /// 317→488 then `egl_reinit_with_track` in the same millisecond.
    static func shouldAllowAttachDrivenEglReinit(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
        eglNeedsResync: Bool,
        windowOrientationMatchesConfiguration: Bool,
        tileWidth: Int,
        tileHeight: Int,
        lastRendererWidth: Int,
        lastRendererHeight: Int
    ) -> Bool {
        guard eglNeedsResync else { return false }
        if isLikelyTransientRotationSurfaceMeasure(
            previousWidth: previousWidth,
            previousHeight: previousHeight,
            newWidth: newWidth,
            newHeight: newHeight
        ) {
            return false
        }
        if isLikelyAspectFitWrapSurfaceMeasure(
            surfaceWidth: newWidth,
            surfaceHeight: newHeight,
            tileWidth: tileWidth,
            tileHeight: tileHeight
        ) {
            return false
        }
        if tileWidth > 0, tileHeight > 0,
           newWidth != tileWidth || newHeight != tileHeight {
            return false
        }
        return shouldReinitRendererEglAfterComposeLayoutSettled(
            viewWidth: newWidth,
            viewHeight: newHeight,
            lastRendererWidth: lastRendererWidth,
            lastRendererHeight: lastRendererHeight,
            eglNeedsResync: true,
            windowOrientationMatchesConfiguration: windowOrientationMatchesConfiguration
        )
    }

    /// Compose-posted reinit after rotation. Holder/OnLayout must not reinit on
    /// dual-axis transients; this runs once the window matches configuration and
    /// OnLayout has already recorded the current tile size.
    static func shouldReinitRendererEglAfterComposeLayoutSettled(
        viewWidth: Int,
        viewHeight: Int,
        lastRendererWidth: Int,
        lastRendererHeight: Int,
        eglNeedsResync: Bool,
        windowOrientationMatchesConfiguration: Bool
    ) -> Bool {
        guard eglNeedsResync else { return false }
        guard viewWidth > 0, viewHeight > 0 else { return false }
        guard windowOrientationMatchesConfiguration else { return false }
        return viewWidth == lastRendererWidth && viewHeight == lastRendererHeight
    }

    /// Compose may briefly measure a pooled SurfaceView at fullscreen before tile constraints apply.
    static func isLikelyTransientFullscreenSurfaceMeasure(
        surfaceWidth: Int,
        surfaceHeight: Int,
        viewWidth: Int,
        viewHeight: Int
    ) -> Bool {
        guard surfaceWidth > 0, surfaceHeight > 0, viewWidth > 0, viewHeight > 0 else {
            return false
        }
        let viewArea = viewWidth * viewHeight
        let surfaceArea = surfaceWidth * surfaceHeight
        return surfaceArea * 2 > viewArea * 3
    }

    /// Whether a stable grid relayout requires tearing down and rebinding EGL at the new holder size.
    static func layoutResizeRequiresRendererEglReinit(
        previousSurfaceWidth: Int,
        previousSurfaceHeight: Int,
        newSurfaceWidth: Int,
        newSurfaceHeight: Int,
        eglInitWidth: Int,
        eglInitHeight: Int,
        viewWidth: Int,
        viewHeight: Int
    ) -> Bool {
        guard newSurfaceWidth > 0, newSurfaceHeight > 0 else { return false }
        if isLikelyTransientFullscreenSurfaceMeasure(
            surfaceWidth: newSurfaceWidth,
            surfaceHeight: newSurfaceHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight
        ) {
            return false
        }
        if eglInitWidth <= 0 || eglInitHeight <= 0 {
            if previousSurfaceWidth > 0,
               previousSurfaceHeight > 0,
               previousSurfaceWidth != newSurfaceWidth || previousSurfaceHeight != newSurfaceHeight {
                return true
            }
            return false
        }
        guard rendererEglInitStaleForSurface(
            eglInitWidth: eglInitWidth,
            eglInitHeight: eglInitHeight,
            surfaceWidth: newSurfaceWidth,
            surfaceHeight: newSurfaceHeight
        ) else {
            return false
        }
        if previousSurfaceWidth > 0,
           previousSurfaceHeight > 0,
           (previousSurfaceWidth != newSurfaceWidth || previousSurfaceHeight != newSurfaceHeight) {
            return true
        }
        return rendererSurfaceLayoutIsDrifted(
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            surfaceWidth: newSurfaceWidth,
            surfaceHeight: newSurfaceHeight
        )
    }

    /// Grid splits resize SurfaceView holders often; stale EGL at the new holder size requires reinit.
    static func layoutResizeRequiresRendererEglReinit(
        eglInitStaleForSurface: Bool,
        surfaceLayoutDrifted: Bool
    ) -> Bool {
        eglInitStaleForSurface || surfaceLayoutDrifted
    }

    /// Waiting for the first rendered frame after a successful sink bind is normal.
    static func rendererPreFirstFrameNeedsLayoutReconcile(
        rendererHasSink: Bool,
        eglInitStaleForSurface: Bool,
        hasPendingTrack: Bool
    ) -> Bool {
        guard rendererHasSink else { return false }
        return eglInitStaleForSurface || hasPendingTrack
    }
}
