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

    /// Pending live-wrapper rebind is event-driven; post-coordinator recovery must not compete.
    static func postCoordinatorRecoveryShouldDeferToPendingLiveWrapperRebind(
        hasPendingLiveWrapperRebind: Bool
    ) -> Bool {
        hasPendingLiveWrapperRebind
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
    /// How many remote renderer slots must stay mounted in Compose so assigned participants
    /// always have a laid-out `SurfaceViewRenderer`.
    static func visibleRemoteViewCount(
        remoteSlotCount: Int,
        assignedParticipantCount: Int,
        poolSize: Int
    ) -> Int {
        guard poolSize > 0 else { return 0 }
        let requested = max(remoteSlotCount, assignedParticipantCount, 1)
        return min(requested, poolSize)
    }

    /// SurfaceView-backed grids must not shrink active renderer slots during roster/SFU churn.
    /// Remounting a tile through a transient one-up layout can leave Android's buffer queue sized
    /// for the wrong surface even though WebRTC still renders tile-sized buffers.
    static func stableVisibleRemoteViewCount(
        previousVisibleCount: Int,
        requestedVisibleCount: Int,
        assignedParticipantCount: Int,
        poolSize: Int
    ) -> Int {
        guard poolSize > 0 else { return 0 }
        let requested = min(max(requestedVisibleCount, assignedParticipantCount, 1), poolSize)
        guard previousVisibleCount > 0, assignedParticipantCount > 0 else {
            return requested
        }
        return min(max(previousVisibleCount, requested), poolSize)
    }

    /// How many stable pool slots Compose should mount for multiparty grids.
    ///
    /// Uses the renderer pool prefix (not assigned-only filtering) so tile surfaces stay mounted while
    /// participants assign. When two remotes are expected, reserve a 2-up layout before the second
    /// assignment lands so the first tile does not flash fullscreen (`1080×2520`) and back.
    /// A true 2-person call (only one remote in the roster) mounts a single fullscreen slot so
    /// remote video can aspect-fill the device orientation.
    static func multipartyGridSlotCount(
        assignedParticipantCount: Int,
        rosterRemoteSlotCount: Int,
        poolSize: Int
    ) -> Int {
        guard poolSize > 0 else { return 0 }
        if assignedParticipantCount >= 2 {
            return min(assignedParticipantCount, poolSize)
        }
        if assignedParticipantCount > 0, rosterRemoteSlotCount >= 2, poolSize >= 2 {
            return 2
        }
        if rosterRemoteSlotCount >= 2 {
            return min(2, poolSize)
        }
        return min(max(assignedParticipantCount, 1), poolSize)
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
