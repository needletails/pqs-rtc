import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct GroupCallVideoRegressionTests {
    private let roomUUID = GroupCallVideoRegressionFixtures.roomUUID

    // MARK: - Group answer policy gate (Android 10:07:32 root cause)

    @Test("bare UUID SFU rooms are group calls for answer SDP policy")
    func bareUuidRoomUsesGroupAnswerPolicy() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        #expect(roomUUID.isGroupCall == false)
        let beforeConfigure = await session.testing_usesGroupCallAnswerSdpPolicy(for: roomUUID)
        #expect(beforeConfigure == false)

        await session.testing_configureGroupSessionForTests(activeConnectionId: roomUUID)
        let afterBare = await session.testing_usesGroupCallAnswerSdpPolicy(for: roomUUID)
        let afterPrefixed = await session.testing_usesGroupCallAnswerSdpPolicy(for: "#\(roomUUID)")
        #expect(afterBare)
        #expect(afterPrefixed)
    }

    // MARK: - Inactive relay mid preservation

    @Test("modifySDP auto-preserves inactive video placeholder mids without local media")
    func modifySDP_preservesInactiveVideoMidWithoutLocalMedia() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        let input = GroupCallVideoRegressionFixtures.firstParticipantJoinRawAnswer()
        #expect(RTCSession.inactiveVideoMidsWithoutLocalMedia(in: input) == ["2"])

        let output = await session.modifySDP(sdp: input, hasVideo: true, vp8OnlyVideo: true)
        #expect(SDPTestHelpers.videoDirection(forMid: "2", in: output) == "inactive")
        #expect(output.contains("a=sendrecv") == false || output.contains("a=mid:2\na=inactive"))
    }

    @Test("answer plan includes inactive relay placeholder mids from remote offer")
    func answerPlan_includesInactivePlaceholderMidsFromRemoteOffer() {
        let offer = GroupCallVideoRegressionFixtures.secondParticipantJoinRemoteOffer()
        let inactiveOnlyOffer = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:2
        a=inactive
        """
        let planFromInactive = ScreenShareGroupCallSDPPolicy.answerModificationPlan(
            remoteOfferSdp: inactiveOnlyOffer,
            localIsSharingScreen: false
        )
        #expect(planFromInactive.preserveVideoDirectionsForMids.contains("2"))

        let plan = ScreenShareGroupCallSDPPolicy.answerModificationPlan(
            remoteOfferSdp: offer,
            localIsSharingScreen: false
        )
        #expect(plan.preserveVideoDirectionsForMids.contains("2"))
        #expect(plan.preserveVideoDirectionsForMids.contains("4"))
    }

    @Test("first Android SFU renegotiation answer keeps inactive relay mid 2")
    func applyAnswerModificationPlan_firstAndroidRelayRenegotiation() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        let remoteOffer = GroupCallVideoRegressionFixtures.firstParticipantJoinRemoteOffer()
        let rawAnswer = GroupCallVideoRegressionFixtures.firstParticipantJoinRawAnswer()

        let processed = await ScreenShareGroupCallSDPPolicy.applyAnswerModificationPlan(
            session: session,
            rawAnswerSdp: rawAnswer,
            remoteOfferSdp: remoteOffer,
            localIsSharingScreen: false,
            supportsVideo: true,
            isGroupCall: true
        )

        #expect(SDPTestHelpers.videoDirection(forMid: "2", in: processed) == "inactive")
        #expect(SDPTestHelpers.videoDirection(forMid: "1", in: processed) == "sendrecv")
    }

    @Test("second Android SFU renegotiation answer keeps inactive and recvonly relay mids")
    func applyAnswerModificationPlan_secondAndroidRelayRenegotiation() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        let remoteOffer = GroupCallVideoRegressionFixtures.secondParticipantJoinRemoteOffer()
        let rawAnswer = GroupCallVideoRegressionFixtures.secondParticipantJoinRawAnswer()

        let processed = await ScreenShareGroupCallSDPPolicy.applyAnswerModificationPlan(
            session: session,
            rawAnswerSdp: rawAnswer,
            remoteOfferSdp: remoteOffer,
            localIsSharingScreen: false,
            supportsVideo: true,
            isGroupCall: true
        )

        #expect(SDPTestHelpers.videoDirection(forMid: "2", in: processed) == "inactive")
        // mid=3 is the SFU audio placeholder in this fixture; only mids 2/4 are video relays.
        #expect(SDPTestHelpers.videoDirection(forMid: "3", in: processed) == nil)
        #expect(SDPTestHelpers.videoDirection(forMid: "4", in: processed) == "recvonly")
    }

    @Test("plain modifySDP preserves inactive relay mid via auto-detect when group policy is bypassed")
    func plainModifySDP_preservesInactiveRelayMidViaAutoDetect() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        let rawAnswer = GroupCallVideoRegressionFixtures.firstParticipantJoinRawAnswer()
        let processed = await session.modifySDP(
            sdp: rawAnswer,
            hasVideo: true,
            stripSsrcLines: false,
            vp8OnlyVideo: true
        )

        #expect(SDPTestHelpers.videoDirection(forMid: "2", in: processed) == "inactive")
    }

    // MARK: - Unresolved SFU receiver fallback

    @Test("single unmapped SFU video candidate claims provisioned participant when msid evidence is missing")
    func unresolvedSfuVideoCandidateClaimsSingleUnmappedReceiver() {
        struct Candidate {
            let trackId: String
        }
        let frankTrack = Candidate(trackId: "1136667b-26d1-4f77-8ba3-c800f3c449fb")
        let resolved = GroupSfuVideoAttachPolicy.resolvedUnresolvedSfuReceiverCandidate(
            candidates: [frankTrack],
            matchingCandidates: [],
            advertisedTrackIds: [],
            sdpTrackIds: [],
            trackId: \.trackId
        )
        #expect(resolved?.trackId == frankTrack.trackId)
    }

    @Test("unresolved SFU receiver fallback does not claim when multiple unmapped candidates exist")
    func unresolvedSfuReceiverFallbackRequiresUniqueCandidate() {
        struct Candidate {
            let trackId: String
        }
        let candidates = [
            Candidate(trackId: "1136667b-26d1-4f77-8ba3-c800f3c449fb"),
            Candidate(trackId: "video_echo_493b6051-39f0-493d-aace-7683f2bfa9e2")
        ]
        let resolved = GroupSfuVideoAttachPolicy.resolvedUnresolvedSfuReceiverCandidate(
            candidates: candidates,
            matchingCandidates: [],
            advertisedTrackIds: [],
            sdpTrackIds: [],
            trackId: \.trackId
        )
        #expect(resolved == nil)
    }

    @Test("unresolved SFU receiver fallback still prefers explicit msid or advertised track evidence")
    func unresolvedSfuReceiverFallbackPrefersExplicitEvidence() {
        struct Candidate {
            let trackId: String
        }
        let echoTrack = Candidate(trackId: "video_echo_493b6051-39f0-493d-aace-7683f2bfa9e2")
        let frankTrack = Candidate(trackId: "1136667b-26d1-4f77-8ba3-c800f3c449fb")
        let candidates = [echoTrack, frankTrack]
        let resolved = GroupSfuVideoAttachPolicy.resolvedUnresolvedSfuReceiverCandidate(
            candidates: candidates,
            matchingCandidates: [echoTrack],
            advertisedTrackIds: [],
            sdpTrackIds: [],
            trackId: \.trackId
        )
        #expect(resolved?.trackId == echoTrack.trackId)
    }

    // MARK: - Cross-platform SFU attach defer + Apple dedupe

    @Test("SFU group attach defers while renegotiation is in flight or signaling is unstable")
    func shouldDeferParticipantVideoAttachDuringSfuRenegotiation() {
        #expect(GroupSfuVideoAttachPolicy.shouldDeferParticipantVideoAttach(
            renegotiationInFlight: true,
            signalingIsStable: true))
        #expect(GroupSfuVideoAttachPolicy.shouldDeferParticipantVideoAttach(
            renegotiationInFlight: false,
            signalingIsStable: false))
        #expect(GroupSfuVideoAttachPolicy.shouldDeferParticipantVideoAttach(
            renegotiationInFlight: false,
            signalingIsStable: true) == false)
        #expect(GroupSfuVideoAttachPolicy.shouldDeferParticipantVideoAttach(
            renegotiationInFlight: true,
            signalingIsStable: false))
    }

    @Test("Apple renderer attach skips when cache matches live receiver identity")
    func appleShouldSkipParticipantRendererAttachWhenLiveReceiverBound() {
        let attachment = "track-a|mid:1|ObjectIdentifier(0x2)"
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: attachment,
            liveAttachmentValue: attachment))
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: "track-a|mid:1|ObjectIdentifier(0x2)",
            liveAttachmentValue: "track-a|mid:4|ObjectIdentifier(0x2)") == false)
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: nil,
            liveAttachmentValue: attachment) == false)
    }

    @Test("Apple silent map refresh skips wrapper-only tile notify during SFU renegotiation")
    func appleShouldNotNotifyParticipantTrackRefreshForWrapperOnlyRebind() {
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedReceiverEnded: false) == false)
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-b",
            storedReceiverEnded: false))
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedReceiverEnded: true))
    }

    // MARK: - Android attach churn dedupe

    @Test("participant track refresh skips reattach when sink already bound to live track")
    func shouldSkipParticipantTrackReattachWhenAlreadyAttached() {
        #expect(RTCSession.shouldSkipParticipantTrackReattach(
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true))
        #expect(RTCSession.shouldSkipParticipantTrackReattach(
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false) == false)
        #expect(RTCSession.shouldSkipParticipantTrackReattach(
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            targetTrackIsLive: false))
        #expect(RTCSession.shouldSkipParticipantTrackReattach(
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: true) == false)
        #expect(RTCSession.shouldSkipParticipantTrackReattach(
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererLayoutNeedsSinkReconcile: true) == false)
    }

    @Test("renderer attach skip requires confirmed first frame on current EGL handler")
    func shouldInvokeParticipantRendererAttachWhenSinkNotConfirmed() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: true))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHasPendingTrackBind: true))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: false))
    }

    @Test("post-renegotiation coordinator suppresses competing attach reasons")
    func postRenegotiationCoordinatorSuppressesCompetingAttachReasons() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "participant-track-refresh",
            episodeActive: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "grid-layout-reattach",
            episodeActive: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "screen-share-layout-reattach",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "screen-share-stop-layout-reattach",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "post-renegotiation-coordinator",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "post-renegotiation-first-frame-reconcile",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "coordinator-settlement",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "coordinator-settled-wrapper-sync",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "coordinator-finalize-media-ready",
            episodeActive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressParticipantVideoAttachReason(
            "participant-track-refresh",
            episodeActive: false) == false)
    }

    @Test("post-renegotiation coordinator batches rebound and grid-layout participants")
    func postRenegotiationCoordinatorCoordinatedAttachParticipantIds() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatedAttachParticipantIds(
            episodeParticipantIds: ["nudge"],
            assignedParticipantIds: ["echo", "nudge"],
            includeAllAssignedForGridLayout: false) == ["nudge"])
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatedAttachParticipantIds(
            episodeParticipantIds: ["nudge"],
            assignedParticipantIds: ["echo", "nudge"],
            includeAllAssignedForGridLayout: true) == ["echo", "nudge"])
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldDeferParticipantTrackEventAttach(
            participantId: "echo",
            episodeParticipantIds: ["echo"]))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldDeferGridLayoutReattach(
            episodeActive: true))
    }

    @Test("coordinator media-ready sweep requires assigned view when participant needs binding")
    func coordinatorMediaReadySweepMissingAssignedView() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatorMediaReadySweepMissingAssignedView(
            shouldSurfaceParticipant: true,
            hasAssignedView: false,
            participantRequiresVideoBinding: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatorMediaReadySweepMissingAssignedView(
            shouldSurfaceParticipant: true,
            hasAssignedView: true,
            participantRequiresVideoBinding: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatorMediaReadySweepMissingAssignedView(
            shouldSurfaceParticipant: false,
            hasAssignedView: false,
            participantRequiresVideoBinding: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatorMediaReadySweepMissingAssignedView(
            shouldSurfaceParticipant: true,
            hasAssignedView: false,
            participantRequiresVideoBinding: false) == false)
    }

    @Test("post-coordinator recovery only targets coordinator-settled participants")
    func postCoordinatorRecoveryTargetsCoordinatorSettledOnly() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.postCoordinatorRecoveryTargetsParticipant(
            coordinatorSettledParticipant: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.postCoordinatorRecoveryTargetsParticipant(
            coordinatorSettledParticipant: false) == false)
    }

    @Test("post-coordinator recovery defers to pending live-wrapper rebind")
    func postCoordinatorRecoveryDefersToPendingRebind() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator
            .postCoordinatorRecoveryShouldDeferToPendingLiveWrapperRebind(
                hasPendingLiveWrapperRebind: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator
            .postCoordinatorRecoveryShouldDeferToPendingLiveWrapperRebind(
                hasPendingLiveWrapperRebind: false) == false)
    }

    @Test("post-coordinator pending apply retries after stale tail stops")
    func postCoordinatorPendingApplyRetriesAfterStaleTailStops() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator
            .postCoordinatorPendingWrapperApplyShouldRetryWhenStaleTailStopped(
                staleWrapperStillDeliveringRecentFrames: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator
            .postCoordinatorPendingWrapperApplyShouldRetryWhenStaleTailStopped(
                staleWrapperStillDeliveringRecentFrames: true) == false)
    }

    @Test("coordinator episode global map refresh is pass 1 only")
    func coordinatorEpisodeGlobalMapRefreshPassOneOnly() {
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatorEpisodeUsesGlobalConnectionMapRefresh(
            passIndex: 1))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.coordinatorEpisodeUsesGlobalConnectionMapRefresh(
            passIndex: 2) == false)
    }

    @Test("native attach probe flags decode into snapshot fields")
    func participantRendererAttachSnapshotDecodesNativeProbeFlags() {
        let snapshot = ParticipantRendererAttachSnapshot(nativeProbeFlags: 0b1111)
        #expect(snapshot.hasActiveSink)
        #expect(snapshot.boundTrackSharesRendererSinkWithTarget)
        #expect(snapshot.rendererLayoutNeedsSinkReconcile)
        #expect(snapshot.attachedTrackIsLive)
        let empty = ParticipantRendererAttachSnapshot(nativeProbeFlags: 0)
        #expect(empty.hasActiveSink == false)
        #expect(empty.boundTrackSharesRendererSinkWithTarget == false)
        #expect(empty.rendererLayoutNeedsSinkReconcile == false)
        #expect(empty.attachedTrackIsLive == false)
    }

    // MARK: - Android multiparty visible grid (nudge 0×0 surface root cause)

    @Test("multiparty grid reserves stable 2-up slots before second assignment")
    func multipartyGridSlotCountReservesTwoUpLayoutForExpectedRoster() {
        #expect(AndroidMultipartyVideoLayout.multipartyGridSlotCount(
            assignedParticipantCount: 2,
            rosterRemoteSlotCount: 3,
            poolSize: 3) == 2)
        #expect(AndroidMultipartyVideoLayout.multipartyGridSlotCount(
            assignedParticipantCount: 1,
            rosterRemoteSlotCount: 2,
            poolSize: 3) == 2)
        // True 2-person call (one remote in roster): single fullscreen slot, not a reserved 2-up.
        #expect(AndroidMultipartyVideoLayout.multipartyGridSlotCount(
            assignedParticipantCount: 1,
            rosterRemoteSlotCount: 1,
            poolSize: 3) == 1)
        #expect(AndroidMultipartyVideoLayout.multipartyGridSlotCount(
            assignedParticipantCount: 0,
            rosterRemoteSlotCount: 2,
            poolSize: 3) == 2)
    }

    @Test("multiparty grid mounts enough slots for assigned participants")
    func multipartyVisibleRemoteViewCountIncludesAssignedParticipants() {
        #expect(AndroidMultipartyVideoLayout.visibleRemoteViewCount(
            remoteSlotCount: 1,
            assignedParticipantCount: 2,
            poolSize: 3) == 2)
        #expect(AndroidMultipartyVideoLayout.visibleRemoteViewCount(
            remoteSlotCount: 3,
            assignedParticipantCount: 1,
            poolSize: 3) == 3)
        #expect(AndroidMultipartyVideoLayout.visibleRemoteViewCount(
            remoteSlotCount: 5,
            assignedParticipantCount: 2,
            poolSize: 3) == 3)
        #expect(AndroidMultipartyVideoLayout.visibleRemoteViewCount(
            remoteSlotCount: 0,
            assignedParticipantCount: 0,
            poolSize: 0) == 0)
        #expect(AndroidMultipartyVideoLayout.stableVisibleRemoteViewCount(
            previousVisibleCount: 3,
            requestedVisibleCount: 1,
            assignedParticipantCount: 1,
            poolSize: 3) == 3)
        #expect(AndroidMultipartyVideoLayout.stableVisibleRemoteViewCount(
            previousVisibleCount: 0,
            requestedVisibleCount: 1,
            assignedParticipantCount: 1,
            poolSize: 3) == 1)
        #expect(AndroidMultipartyVideoLayout.stableVisibleRemoteViewCount(
            previousVisibleCount: 3,
            requestedVisibleCount: 1,
            assignedParticipantCount: 0,
            poolSize: 3) == 1)
    }

    @Test("grid refresh reattaches when assignment signature or visible slot count changes")
    func shouldNotReattachWhenOnlyPendingSinkWithoutGridChange() {
        #expect(AndroidMultipartyVideoLayout.shouldReattachAssignedParticipantVideo(
            previousVisibleCount: 2,
            nextVisibleCount: 2,
            previousSignature: "0:echo|1:nudge|2:-",
            nextSignature: "0:echo|1:nudge|2:-") == false)
        #expect(AndroidMultipartyVideoLayout.shouldReattachAssignedParticipantVideo(
            previousVisibleCount: 1,
            nextVisibleCount: 2,
            previousSignature: "0:echo|1:-|2:-",
            nextSignature: "0:echo|1:-|2:-"))
        #expect(AndroidMultipartyVideoLayout.shouldReattachAssignedParticipantVideo(
            previousVisibleCount: 1,
            nextVisibleCount: 2,
            previousSignature: "0:echo|1:-|2:-",
            nextSignature: "0:echo|1:nudge|2:-"))
    }

    @Test("stable track id ignores Java wrapper drift for connection map identity only")
    func remoteVideoTracksShareEffectiveSourceForStableTrackId() {
        let trackId = "video_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2"
        #expect(AndroidRemoteVideoTrackAttachPolicy.tracksShareEffectiveNativeSource(
            lhsTrackId: trackId,
            rhsTrackId: trackId,
            lhsIsLive: true,
            rhsIsLive: true,
            platformTracksIdentical: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(
            platformTracksIdentical: true))
        #expect(AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(
            platformTracksIdentical: false) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.tracksShareEffectiveNativeSource(
            lhsTrackId: trackId,
            rhsTrackId: trackId,
            lhsIsLive: false,
            rhsIsLive: true,
            platformTracksIdentical: false) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.tracksShareEffectiveNativeSource(
            lhsTrackId: "track-a",
            rhsTrackId: "track-b",
            lhsIsLive: true,
            rhsIsLive: true,
            platformTracksIdentical: false) == false)
    }

    @Test("live remote track refresh skips wrapper-only drift")
    func shouldPreferLiveRemoteVideoTrackIgnoresWrapperDrift() {
        let trackId = "video_echo_493b6051-39f0-493d-aace-7683f2bfa9e2"
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreferLiveRemoteVideoTrack(
            hasMappedTrack: true,
            mappedTrackId: trackId,
            mappedIsLive: true,
            liveTrackId: trackId) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreferLiveRemoteVideoTrack(
            hasMappedTrack: true,
            mappedTrackId: trackId,
            mappedIsLive: false,
            liveTrackId: trackId))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreferLiveRemoteVideoTrack(
            hasMappedTrack: true,
            mappedTrackId: "track-a",
            mappedIsLive: true,
            liveTrackId: "track-b"))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreferLiveRemoteVideoTrack(
            hasMappedTrack: false,
            mappedTrackId: nil,
            mappedIsLive: false,
            liveTrackId: trackId))
    }

    @Test("SFU renegotiation receiver drift ignores wrapper-only changes")
    func receiverTrackDriftRequiresTrackIdOrLivenessChange() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.receiverTrackDriftedAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: true) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.receiverTrackDriftedAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-b",
            storedIsLive: true))
        #expect(AndroidRemoteVideoTrackAttachPolicy.receiverTrackDriftedAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: false))
    }

    @Test("connection map refresh includes native wrapper swaps without tile notify")
    func needsConnectionMapRefreshForPlatformWrapperSwap() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.needsAndroidRemoteCameraConnectionMapRefresh(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: true,
            platformTracksIdentical: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.needsAndroidRemoteCameraConnectionMapRefresh(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: true,
            platformTracksIdentical: true) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: true) == false)
    }

    @Test("SFU wrapper refresh always requires EGL reinit")
    func sfuWrapperRefreshRequiresRendererEglReinit() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.requiresRendererEglReinitForWrapperRefresh(
            reason: "SFU track wrapper refresh"))
        #expect(AndroidRemoteVideoTrackAttachPolicy.requiresRendererEglReinitForWrapperRefresh(
            reason: "stale wrapper surface reconcile"))
        #expect(AndroidRemoteVideoTrackAttachPolicy.requiresRendererEglReinitForWrapperRefresh(
            reason: "Attached track immediately - surface ready") == false)
    }

    @Test("participant attach prefers live peer-connection receiver over cached wrapper")
    func shouldPreferPeerConnectionAttachTrackWhenWrapperDrifted() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreferPeerConnectionAttachTrack(
            mappedTrackPlatformIdenticalToLive: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreferPeerConnectionAttachTrack(
            mappedTrackPlatformIdenticalToLive: true) == false)
    }

    @Test("renderer sink skip requires native receiver identity and rendered first frame")
    func shouldSkipParticipantRendererAttachWhenSinkAlreadyLive() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: true) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererLayoutNeedsSinkReconcile: true))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldInvokeParticipantRendererAttach(
            trackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreserveActiveSinkWhenStaleWrapperArrives(
            hasActiveSink: true,
            attachedTrackId: "track-a",
            staleTrackId: "track-a",
            boundTrackSharesRendererSinkWithTarget: true))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreserveActiveSinkWhenStaleWrapperArrives(
            hasActiveSink: true,
            attachedTrackId: "track-a",
            staleTrackId: "track-a",
            boundTrackSharesRendererSinkWithTarget: false) == false)
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldPreserveActiveSinkWhenStaleWrapperArrives(
            hasActiveSink: false,
            attachedTrackId: "track-a",
            staleTrackId: "track-a") == false)
    }

    @Test("SFU post-renegotiation refresh emits only rebound participants")
    func postRenegotiationTileRefreshTargetsReboundParticipantsOnly() {
        #expect(GroupSfuVideoAttachPolicy.participantIdsNeedingPostRenegotiationTileRefresh(
            reboundParticipantIds: ["nudge"],
            queuedRefreshParticipantIds: [],
            allMappedParticipantIds: ["echo", "nudge"]
        ) == ["nudge"])
        #expect(GroupSfuVideoAttachPolicy.participantIdsNeedingPostRenegotiationTileRefresh(
            reboundParticipantIds: [],
            queuedRefreshParticipantIds: [],
            allMappedParticipantIds: ["echo", "nudge"]
        ).isEmpty)
        #expect(GroupSfuVideoAttachPolicy.participantIdsNeedingPostRenegotiationTileRefresh(
            reboundParticipantIds: ["echo"],
            queuedRefreshParticipantIds: ["nudge"],
            allMappedParticipantIds: ["echo", "nudge"]
        ) == ["echo", "nudge"])
    }

    @Test("renderer recovery requests sink refresh when inbound decode advances but tile stalls")
    func shouldRequestRendererRecoveryWhenInboundAdvancesButTileStalls() {
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 4,
            inboundDeltaPacketsReceived: 0,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 2,
            inboundDeltaPacketsReceived: 0,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 12,
            inboundDeltaPacketsReceived: 40,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 0,
            inboundDeltaPacketsReceived: 0,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 3,
            inboundDeltaPacketsReceived: 0,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: true,
            hasLiveTrack: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: true,
            coordinatorSettledPreviously: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: true,
            coordinatorSettledPreviously: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: true,
            coordinatorSettledPreviously: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
            tileAttachedTrackIsLive: false,
            tileHasActiveSink: true,
            probeHasActiveSink: false,
            probeBoundTrackSharesRendererSinkWithTarget: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
            tileAttachedTrackIsLive: true,
            tileHasActiveSink: false,
            probeHasActiveSink: false,
            probeBoundTrackSharesRendererSinkWithTarget: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
            tileAttachedTrackIsLive: true,
            tileHasActiveSink: true,
            probeHasActiveSink: true,
            probeBoundTrackSharesRendererSinkWithTarget: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames(
            tileAttachedTrackIsLive: true,
            tileHasActiveSink: true,
            probeHasActiveSink: true,
            probeBoundTrackSharesRendererSinkWithTarget: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipSettledParticipantLiveWrapperSyncAfterMapRefresh(
            tileAttachedTrackIsLive: false,
            tileHasActiveSink: true,
            probeHasActiveSink: false,
            probeAttachedTrackIsLive: false,
            probeBoundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-b",
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: nil,
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: nil,
            attachedTrackIsLive: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipCoordinatorReattach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorAttach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: true,
            probe: ParticipantRendererAttachSnapshot(
                hasActiveSink: true,
                boundTrackSharesRendererSinkWithTarget: true,
                rendererLayoutNeedsSinkReconcile: false,
                attachedTrackIsLive: true
            ),
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorAttach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            probe: ParticipantRendererAttachSnapshot(
                hasActiveSink: true,
                boundTrackSharesRendererSinkWithTarget: true,
                rendererLayoutNeedsSinkReconcile: false,
                attachedTrackIsLive: false
            ),
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorAttach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            probe: ParticipantRendererAttachSnapshot(
                hasActiveSink: false,
                boundTrackSharesRendererSinkWithTarget: false,
                rendererLayoutNeedsSinkReconcile: false,
                attachedTrackIsLive: false
            ),
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorAttach(
            coordinatorBoundThisEpisode: true,
            coordinatorSettledPreviously: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            probe: ParticipantRendererAttachSnapshot(
                hasActiveSink: true,
                boundTrackSharesRendererSinkWithTarget: true,
                rendererLayoutNeedsSinkReconcile: false,
                attachedTrackIsLive: true
            ),
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: nil,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-b",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.participantNeedsLiveWrapperSinkRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPassEndSinkRebindAfterSiblingRecovery(
            siblingPassEndRebindConfirmedFirstFrame: true,
            attachedTrackIsLive: false,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPassEndSinkRebindAfterSiblingRecovery(
            siblingPassEndRebindConfirmedFirstFrame: true,
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false,
            forceLiveWrapperRecovery: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorReconcile(
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRebindParticipantSinkAfterCoordinatorPass(
            fullAttachedThisCoordinatorPass: false,
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            attachedTrackIsLive: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressAlreadyReboundSinkRebind(
            allowWhenAlreadyReboundThisEpisode: false,
            alreadyReboundThisEpisode: true,
            hasActiveSink: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false,
            attachedTrackIsLive: true,
            boundTrackSharesRendererSinkWithTarget: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressAlreadyReboundSinkRebind(
            allowWhenAlreadyReboundThisEpisode: false,
            alreadyReboundThisEpisode: true,
            hasActiveSink: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false,
            attachedTrackIsLive: false,
            boundTrackSharesRendererSinkWithTarget: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressAlreadyReboundSinkRebind(
            allowWhenAlreadyReboundThisEpisode: false,
            alreadyReboundThisEpisode: true,
            hasActiveSink: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: false,
            attachedTrackIsLive: true,
            boundTrackSharesRendererSinkWithTarget: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressAlreadyReboundSinkRebind(
            allowWhenAlreadyReboundThisEpisode: false,
            alreadyReboundThisEpisode: true,
            hasActiveSink: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererFramesStaleWhileBound: true,
            attachedTrackIsLive: true,
            boundTrackSharesRendererSinkWithTarget: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSuppressAlreadyReboundSinkRebind(
            allowWhenAlreadyReboundThisEpisode: false,
            alreadyReboundThisEpisode: true,
            hasActiveSink: true,
            rendererLayoutNeedsSinkReconcile: true,
            rendererFramesStaleWhileBound: false,
            attachedTrackIsLive: true,
            boundTrackSharesRendererSinkWithTarget: true) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRunCoordinatorPassStaleSweep(
            passIndex: 1,
            rerunQueued: true))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRunCoordinatorPassStaleSweep(
            passIndex: 2,
            rerunQueued: false))
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldRunCoordinatorPassStaleSweep(
            passIndex: 2,
            rerunQueued: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            attachedTrackIsLive: false,
            coordinatorSettledParticipant: true))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            attachedTrackIsLive: false))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 31,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: true,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 6,
            inboundDeltaPacketsReceived: 13,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: true,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: true,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            coordinatorSettledParticipant: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "inbound-render-recovery") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "post-renegotiation-coordinator") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "post-renegotiation-first-frame-reconcile") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "coordinator-settlement") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "participant-track-added"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "post-renegotiation-coordinator",
            coordinatorSettledParticipant: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.preferFreshPeerConnectionTrack(
            forAttachReason: "participant-track-added",
            postRenegotiationEpisodeActive: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.coordinatorEpisodeRequiresSessionStoreEglBind(
            postRenegotiationEpisodeActive: true,
            attachReason: "post-renegotiation-coordinator"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.coordinatorEpisodeRequiresSessionStoreEglBind(
            postRenegotiationEpisodeActive: true,
            attachReason: "coordinator-settlement"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.coordinatorEpisodeRequiresSessionStoreEglBind(
            postRenegotiationEpisodeActive: false,
            attachReason: "post-renegotiation-coordinator") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy
            .coordinatorEpisodeAllowsFreshPeerConnectionProbeForDeadAttachedWrapper(
                postRenegotiationEpisodeActive: true,
                sessionMapTrackIsLive: false,
                attachedTrackIsLive: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy
            .coordinatorEpisodeAllowsFreshPeerConnectionProbeForDeadAttachedWrapper(
                postRenegotiationEpisodeActive: true,
                sessionMapTrackIsLive: false,
                attachedTrackIsLive: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy
            .coordinatorEpisodeAllowsFreshPeerConnectionProbeForDeadAttachedWrapper(
                postRenegotiationEpisodeActive: true,
                sessionMapTrackIsLive: false,
                attachedTrackIsLive: false,
                rendererStillDeliveringRecentFramesOnStaleWrapper: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferFinalizeMediaReadyToWrapperSync(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupPostRenegotiationAttachCoordinator.shouldSkipPostRenegotiationCoordinatorAttach(
            coordinatorBoundThisEpisode: false,
            coordinatorSettledPreviously: true,
            attachedTrackId: "track-a",
            mappedLiveTrackId: nil,
            attachedTrackIsLive: false,
            probe: ParticipantRendererAttachSnapshot(
                hasActiveSink: true,
                boundTrackSharesRendererSinkWithTarget: true,
                rendererLayoutNeedsSinkReconcile: false,
                attachedTrackIsLive: false
            ),
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.coordinatorEpisodeRequiresSessionStoreEglBind(
            postRenegotiationEpisodeActive: true,
            attachReason: "participant-track-added") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.isParticipantRendererSmoothlyRendering(
            attachedTrackIsLive: true,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileAwaitingSinkAttachFirstFrame(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileAwaitingSinkAttachFirstFrame(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeMediaReadyPromotion(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererLayoutNeedsSinkReconcile: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeMediaReadyPromotion(
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeMediaReadyPromotion(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeMediaReadyPromotion(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererLayoutNeedsSinkReconcile: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferFinalizeMediaReadyToWrapperSync(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererLayoutNeedsSinkReconcile: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldDeferFinalizeMediaReadyToWrapperSync(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.coordinatorSettlementPrefersSinkOnlyLiveWrapperRebind(
            attachedTrackId: "track-a",
            mappedLiveTrackId: "track-a",
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorSettlementAttachReason("coordinator-settlement"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorSettlementAttachReason("coalesced-coordinator-settlement"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorSettlementAttachReason("inbound-render-recovery") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason("post-renegotiation-coordinator"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason("post-renegotiation-grid-layout"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason("coalesced-post-renegotiation-coordinator"))
        #expect(AndroidGroupParticipantRendererAttachPolicy.isCoordinatorEpisodeSinkOnlyAttachReason("participant-track-refresh") == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndSinkRebindBeforeEpisodeSettlement(
            episodeSettlementFollows: true,
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndSinkRebindBeforeEpisodeSettlement(
            episodeSettlementFollows: false,
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
            passEndWarmedThisEpisode: true,
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
            passEndWarmedThisEpisode: true,
            attachedTrackIsLive: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
            passEndWarmedThisEpisode: true,
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
            passEndWarmedThisEpisode: true,
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: true) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorSettlementAfterPassEndWarmth(
            passEndWarmedThisEpisode: false,
            attachedTrackIsLive: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
            pendingApplySucceededThisFinalize: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipFinalizeRecoveryAfterPassEndPendingApply(
            pendingApplySucceededThisFinalize: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldAwaitFinalizeFirstFrameAfterPendingApply(
            pendingApplySucceededThisFinalize: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererLayoutNeedsSinkReconcile: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldAwaitFinalizeFirstFrameAfterPendingApply(
            pendingApplySucceededThisFinalize: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
            settlementSinkOnlySucceededThisEpisode: true,
            attachedTrackIsLive: false,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
            settlementSinkOnlySucceededThisEpisode: true,
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndStaleWrapperRebindForEpisodeWarmedTile(
            fullAttachedThisCoordinatorPass: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            tileAttachedTrackIsLive: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndStaleWrapperRebindForEpisodeWarmedTile(
            fullAttachedThisCoordinatorPass: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererFramesStaleWhileBound: false,
            tileAttachedTrackIsLive: true))
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipPassEndStaleWrapperRebindForEpisodeWarmedTile(
            fullAttachedThisCoordinatorPass: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            tileAttachedTrackIsLive: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.shouldSkipCoordinatorChurnRebindAfterSettlementSinkOnly(
            settlementSinkOnlySucceededThisEpisode: false,
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefreshForLocalTileState(
            attachedTrackIsLive: false,
            hasLiveTrack: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefreshForLocalTileState(
            attachedTrackIsLive: true,
            hasLiveTrack: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefreshForLocalTileState(
            attachedTrackIsLive: true,
            hasLiveTrack: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReady(
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReadyForEpisodeClear(
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false) == false)
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReadyForEpisodeClear(
            attachedTrackIsLive: false,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            hasPendingLiveWrapperRebind: true))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileIsMediaReadyForEpisodeClear(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: true,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: false,
            rendererEverConfirmedFirstFrameForAttachedTrack: false,
            rendererFramesStaleWhileBound: false))
        #expect(AndroidGroupParticipantRendererAttachPolicy.participantTileAwaitingSinkAttachFirstFrameAfterPromotion(
            attachedTrackIsLive: true,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrameSinceSinkAttach: false,
            rendererHasDeliveredFramesSinceCurrentSinkAttach: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: false,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            coordinatorSettledParticipant: true))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            coordinatorSettledParticipant: true) == false)
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: false,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: true,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            coordinatorSettledParticipant: true))
        #expect(AndroidGroupParticipantRendererRecoveryPolicy.shouldRequestSinkRefresh(
            inboundDeltaFramesDecoded: 50,
            inboundDeltaPacketsReceived: 790,
            hasActiveSink: true,
            boundTrackSharesRendererSinkWithTarget: true,
            rendererHadConfirmedFirstFrame: true,
            rendererEverConfirmedFirstFrameForAttachedTrack: true,
            rendererFramesStaleWhileBound: false,
            rendererLayoutNeedsSinkReconcile: false,
            rendererHasPendingTrackBind: false,
            recoveryAlreadyIssuedForStallEpisode: false,
            hasLiveTrack: true,
            coordinatorSettledParticipant: true) == false)
    }

    @Test("Apple participant attach dedupe can be bypassed for decode-stall recovery")
    func appleParticipantAttachDedupeBypassForDecodeRecovery() {
        let attachment = "track-a|mid:m0|ObjectIdentifier(0)"
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: attachment,
            liveAttachmentValue: attachment))
        #expect(AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
            cachedAttachmentValue: nil,
            liveAttachmentValue: attachment) == false)
    }

    @Test("dead stored wrapper after renegotiation still needs tile refresh")
    func shouldNotifyParticipantTrackRefreshForDeadWrapperSameTrackId() {
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-b",
            storedIsLive: false))
        #expect(AndroidRemoteVideoTrackAttachPolicy.shouldNotifyParticipantTrackRefreshAfterRenegotiation(
            storedTrackId: "track-a",
            liveTrackId: "track-a",
            storedIsLive: true) == false)
    }

    @Test("remote participant renderers normalize orientation; local preview does not")
    func remoteSampleRendererNormalizesOrientation() {
        #expect(AndroidRemoteVideoRenderPolicy.normalizesIncomingFramesToUpright(
            forRemoteParticipantTile: true))
        #expect(AndroidRemoteVideoRenderPolicy.normalizesIncomingFramesToUpright(
            forRemoteParticipantTile: false) == false)
    }

    @Test("layout reconcile reattaches sinks after resize and skips unchanged healthy sinks")
    func shouldReconcileRendererLayoutOnlyForPendingOrInactiveSink() {
        #expect(AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
            previousWidth: 1002,
            previousHeight: 1213,
            newWidth: 1002,
            newHeight: 1213,
            hasPendingTrack: false,
            rendererHasSink: true,
            hasAttachedTrack: true) == false)
        #expect(AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
            previousWidth: 493,
            previousHeight: 1213,
            newWidth: 1002,
            newHeight: 1213,
            hasPendingTrack: false,
            rendererHasSink: true,
            hasAttachedTrack: true))
        #expect(AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
            previousWidth: 1002,
            previousHeight: 1213,
            newWidth: 800,
            newHeight: 900,
            hasPendingTrack: false,
            rendererHasSink: true,
            hasAttachedTrack: true))
        #expect(AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
            previousWidth: 1002,
            previousHeight: 1213,
            newWidth: 1002,
            newHeight: 1213,
            hasPendingTrack: true,
            rendererHasSink: false,
            hasAttachedTrack: true))
        #expect(AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
            previousWidth: 1002,
            previousHeight: 1213,
            newWidth: 800,
            newHeight: 900,
            hasPendingTrack: false,
            rendererHasSink: false,
            hasAttachedTrack: true))
    }

    @Test("Android renderer EGL reinit is required when holder size or measured layout drift")
    func androidRendererEglReinitDetectsSurfaceDriftAndStaleInit() {
        #expect(AndroidRendererLayoutPolicy.rendererSurfaceLayoutIsDrifted(
            viewWidth: 1002,
            viewHeight: 1213,
            surfaceWidth: 1080,
            surfaceHeight: 2520))
        #expect(AndroidRendererLayoutPolicy.rendererEglInitStaleForSurface(
            eglInitWidth: 493,
            eglInitHeight: 1213,
            surfaceWidth: 1080,
            surfaceHeight: 2520))
        #expect(AndroidRendererLayoutPolicy.layoutResizeRequiresRendererEglReinit(
            eglInitStaleForSurface: false,
            surfaceLayoutDrifted: false) == false)
        #expect(AndroidRendererLayoutPolicy.layoutResizeRequiresRendererEglReinit(
            eglInitStaleForSurface: true,
            surfaceLayoutDrifted: false))
        #expect(AndroidRendererLayoutPolicy.isLikelyTransientFullscreenSurfaceMeasure(
            surfaceWidth: 1080,
            surfaceHeight: 2520,
            viewWidth: 493,
            viewHeight: 1213))
        #expect(AndroidRendererLayoutPolicy.isLikelyTransientFullscreenSurfaceMeasure(
            surfaceWidth: 1002,
            surfaceHeight: 1213,
            viewWidth: 1002,
            viewHeight: 1213) == false)
        #expect(AndroidRendererLayoutPolicy.layoutResizeRequiresRendererEglReinit(
            previousSurfaceWidth: 493,
            previousSurfaceHeight: 1213,
            newSurfaceWidth: 1002,
            newSurfaceHeight: 1213,
            eglInitWidth: 493,
            eglInitHeight: 1213,
            viewWidth: 1002,
            viewHeight: 1213))
        #expect(AndroidRendererLayoutPolicy.layoutResizeRequiresRendererEglReinit(
            previousSurfaceWidth: 1080,
            previousSurfaceHeight: 2520,
            newSurfaceWidth: 493,
            newSurfaceHeight: 1213,
            eglInitWidth: 0,
            eglInitHeight: 0,
            viewWidth: 493,
            viewHeight: 1213))
        #expect(AndroidRendererLayoutPolicy.rendererPreFirstFrameNeedsLayoutReconcile(
            rendererHasSink: true,
            eglInitStaleForSurface: false,
            hasPendingTrack: false) == false)
        #expect(AndroidRendererLayoutPolicy.rendererPreFirstFrameNeedsLayoutReconcile(
            rendererHasSink: true,
            eglInitStaleForSurface: true,
            hasPendingTrack: false))
    }

    @Test("queued Android renderer attach is not treated as complete")
    func participantRendererAttachRequiresActiveSink() {
        #expect(AndroidMultipartyVideoLayout.participantRendererAttachSucceeded(
            attachAcknowledged: true,
            hasActiveSink: false) == false)
        #expect(AndroidMultipartyVideoLayout.participantRendererAttachSucceeded(
            attachAcknowledged: true,
            hasActiveSink: true))
        #expect(AndroidMultipartyVideoLayout.participantRendererAttachAcknowledged(
            attachReturned: true,
            hasActiveSink: false) == false)
        #expect(AndroidMultipartyVideoLayout.participantRendererAttachAcknowledged(
            attachReturned: true,
            hasActiveSink: true))
    }

    @Test("Android receiver cryptor reuse requires stable track and receiver identity")
    func androidReceiverCryptorReuseRequiresStableTrackAndReceiverIdentity() {
        #expect(AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
            existingTrackId: "video_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2",
            newTrackId: "video_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2",
            existingReceiverKey: "187315778",
            newReceiverKey: "187315778"))
        #expect(AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
            existingTrackId: "video_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2",
            newTrackId: "video_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2",
            existingReceiverKey: "187315778",
            newReceiverKey: "76325832") == false)
        #expect(AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
            existingTrackId: "2632e478-9d22-4755-8fb9-ab3fc09d1490",
            newTrackId: "video_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2",
            existingReceiverKey: "187315778",
            newReceiverKey: "76325832") == false)
        #expect(AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
            existingTrackId: nil,
            newTrackId: "",
            existingReceiverKey: nil,
            newReceiverKey: "") == false)
    }
}
