import Foundation
import Testing

@testable import PQSRTC

/// Contract conformance tests for SFU group-call screen share SDP.
///
/// Each test maps to a row in `ScreenShareGroupCallContract.SignalingLeg`.
/// Failures mean the client policy diverged from the spec — not that logs looked wrong.
@Suite(.serialized)
struct ScreenShareGroupCallSDPScenarioTests {
    private let roomId = ScreenShareSDPFixtures.defaultRoomId
    private let alice = "alice"
    private let bob = "bob"

    private func makeSession() async -> RTCSession {
        await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
    }

    private func assertContract(
        processedSdp: String,
        leg: ScreenShareGroupCallContract.SignalingLeg,
        viewerParticipantId: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let issues = ScreenShareGroupCallContract.validate(
            processedSdp: processedSdp,
            leg: leg,
            viewerParticipantId: viewerParticipantId,
            resolveParticipantId: ScreenShareSDPAssertions.resolveParticipantId(from:)
        )
        if !issues.isEmpty {
            Issue.record(
                "Contract violation for \(leg): \(issues.map(\.message).joined(separator: "; "))",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Sharer → SFU

    @Test("contract: sharer start-share offer")
    func sharerStartShareOfferMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let raw = ScreenShareSDPFixtures.sharerRawStartShareOffer(sharer: alice, roomId: roomId)
        let processed = await ScreenShareGroupCallSDPPolicy.preprocessOutboundGroupCallOffer(
            session: session,
            rawOfferSdp: raw,
            supportsVideo: true,
            isGroupCall: true
        )
        assertContract(
            processedSdp: processed,
            leg: .sharerStartShare(participantId: alice, roomId: roomId)
        )
    }

    @Test("contract: sharer stop-share offer")
    func sharerStopShareOfferMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let raw = ScreenShareSDPFixtures.sharerRawStopShareOffer(sharer: alice, roomId: roomId)
        let processed = await ScreenShareGroupCallSDPPolicy.preprocessOutboundGroupCallOffer(
            session: session,
            rawOfferSdp: raw,
            supportsVideo: true,
            isGroupCall: true
        )
        assertContract(
            processedSdp: processed,
            leg: .sharerStopShare(participantId: alice, roomId: roomId)
        )
    }

    @Test("contract: sharer stop-share offer with detached UUID msid keeps mid=2 inactive")
    func sharerStopShareOfferWithDetachedUuidMsidStaysInactive() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        // Production shape: libwebrtc advertises the sender UUID (no screen_ prefix) with
        // `a=msid:- …` and leftover ssrc attributes after the screen track is removed. The
        // camera `hasVideo` upgrade must not flip this slot back to sendrecv — the SFU would
        // read it as an active share and re-forward the stopped screen to every viewer.
        let raw = ScreenShareSDPFixtures.sharerRawStopShareOfferWithDetachedUuidMsid(
            sharer: alice,
            roomId: roomId
        )
        let processed = await ScreenShareGroupCallSDPPolicy.preprocessOutboundGroupCallOffer(
            session: session,
            rawOfferSdp: raw,
            supportsVideo: true,
            isGroupCall: true
        )
        assertContract(
            processedSdp: processed,
            leg: .sharerStopShare(participantId: alice, roomId: roomId)
        )
    }

    // MARK: - SFU → viewer

    @Test("contract: SFU forward share to viewer")
    func sfuForwardShareMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let raw = ScreenShareSDPFixtures.sfuInboundStartShareOffer(
            sharer: alice,
            viewer: bob,
            roomId: roomId
        )
        let processed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: raw,
            supportsVideo: true
        )
        assertContract(
            processedSdp: processed,
            leg: .sfuForwardShareToViewer(sharerId: alice, viewerId: bob, roomId: roomId),
            viewerParticipantId: bob
        )
    }

    @Test("contract: SFU forward stop to viewer")
    func sfuForwardStopMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let raw = ScreenShareSDPFixtures.sfuInboundStopShareOffer(sharer: alice, roomId: roomId)
        let processed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: raw,
            supportsVideo: true
        )
        assertContract(
            processedSdp: processed,
            leg: .sfuForwardStopToViewer(formerSharerId: alice, viewerId: bob, roomId: roomId),
            viewerParticipantId: bob
        )
    }

    // MARK: - Viewer answer

    @Test("contract: viewer answer while receiving (not sharing)")
    func viewerAnswerWhileReceivingMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let inbound = ScreenShareSDPFixtures.sfuInboundStartShareOffer(
            sharer: alice,
            viewer: bob,
            roomId: roomId
        )
        let processedOffer = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: inbound,
            supportsVideo: true
        )
        let processedAnswer = await ScreenShareGroupCallSDPPolicy.applyAnswerModificationPlan(
            session: session,
            rawAnswerSdp: ScreenShareSDPFixtures.rawWebRTCAnswerAllSendRecv(),
            remoteOfferSdp: processedOffer,
            localIsSharingScreen: false,
            supportsVideo: true,
            isGroupCall: true
        )
        assertContract(
            processedSdp: processedAnswer,
            leg: .viewerAnswerWhileReceiving(sharerId: alice, viewerIsSharing: false)
        )
    }

    @Test("contract: viewer answer while also sharing does not force recvonly on screen mid")
    func viewerAnswerWhileSharingMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let inbound = ScreenShareSDPFixtures.sfuInboundStartShareOffer(
            sharer: alice,
            viewer: bob,
            roomId: roomId
        )
        let processedOffer = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: inbound,
            supportsVideo: true
        )
        let processedAnswer = await ScreenShareGroupCallSDPPolicy.applyAnswerModificationPlan(
            session: session,
            rawAnswerSdp: ScreenShareSDPFixtures.rawWebRTCAnswerAllSendRecv(),
            remoteOfferSdp: processedOffer,
            localIsSharingScreen: true,
            supportsVideo: true,
            isGroupCall: true
        )
        assertContract(
            processedSdp: processedAnswer,
            leg: .viewerAnswerWhileReceiving(sharerId: alice, viewerIsSharing: true)
        )
    }

    // MARK: - Sharer accepts SFU answer after stop

    @Test("contract: sharer normalizes stale SFU stop answer")
    func sharerAcceptStopAnswerMeetsContract() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let localStop = ScreenShareSDPFixtures.sharerRawStopShareOffer(sharer: alice, roomId: roomId)
        let processedLocalOffer = await ScreenShareGroupCallSDPPolicy.preprocessOutboundGroupCallOffer(
            session: session,
            rawOfferSdp: localStop,
            supportsVideo: true,
            isGroupCall: true
        )
        let staleAnswer = ScreenShareSDPFixtures.sfuAnswerToStopOfferWithStaleScreenMid(
            sharer: alice,
            roomId: roomId
        )
        let processedAnswer = await ScreenShareGroupCallSDPPolicy.preprocessInboundAnswerForLocalOffer(
            answerSdp: staleAnswer,
            localOfferSdp: processedLocalOffer,
            session: session,
            supportsVideo: true,
            isGroupCall: true
        )
        assertContract(
            processedSdp: processedAnswer,
            leg: .sharerAcceptStopAnswer(participantId: alice, roomId: roomId)
        )
    }

    // MARK: - Full lifecycle (contract simulator)

    @Test("contract lifecycle: same participant share → stop → share")
    func lifecycleShareStopShareSameParticipant() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        var scenario = ScreenShareGroupCallScenarioSimulator(roomId: roomId)

        scenario.startShare(participantId: alice)
        let shareOffer = scenario.sfuOfferToViewer(viewerId: bob)!
        let shareProcessed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: shareOffer,
            supportsVideo: true
        )
        assertContract(
            processedSdp: shareProcessed,
            leg: .sfuForwardShareToViewer(sharerId: alice, viewerId: bob, roomId: roomId),
            viewerParticipantId: bob
        )

        scenario.stopShare()
        let stopOffer = scenario.sfuStopOfferToViewer(viewerId: bob, formerSharer: alice)
        let stopProcessed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: stopOffer,
            supportsVideo: true
        )
        assertContract(
            processedSdp: stopProcessed,
            leg: .sfuForwardStopToViewer(formerSharerId: alice, viewerId: bob, roomId: roomId),
            viewerParticipantId: bob
        )

        scenario.startShare(participantId: alice)
        let restartOffer = scenario.sfuOfferToViewer(viewerId: bob)!
        let restartProcessed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: restartOffer,
            supportsVideo: true
        )
        assertContract(
            processedSdp: restartProcessed,
            leg: .sfuForwardShareToViewer(sharerId: alice, viewerId: bob, roomId: roomId),
            viewerParticipantId: bob
        )
    }

    @Test("contract lifecycle: exclusive handoff alice → bob")
    func lifecycleHandoffBetweenParticipants() async {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        var scenario = ScreenShareGroupCallScenarioSimulator(roomId: roomId)

        scenario.startShare(participantId: alice)
        let aliceShare = scenario.sfuOfferToViewer(viewerId: bob)!
        let aliceProcessed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: aliceShare,
            supportsVideo: true
        )
        assertContract(
            processedSdp: aliceProcessed,
            leg: .sfuForwardShareToViewer(sharerId: alice, viewerId: bob, roomId: roomId),
            viewerParticipantId: bob
        )

        scenario.handoff(to: bob)
        let bobShare = scenario.sfuOfferToViewer(viewerId: alice)!
        let bobProcessed = await ScreenShareGroupCallSDPPolicy.preprocessInboundRenegotiationOffer(
            session: session,
            remoteOfferSdp: bobShare,
            supportsVideo: true
        )
        assertContract(
            processedSdp: bobProcessed,
            leg: .sfuForwardShareToViewer(sharerId: bob, viewerId: alice, roomId: roomId),
            viewerParticipantId: alice
        )
    }

    // MARK: - Answer modification plan (pure policy)

    @Test("answer plan matches contract for viewer receiving share")
    func answerPlanMatchesContractWhenViewerReceiving() {
        let offer = ScreenShareSDPFixtures.sfuInboundStartShareOffer(
            sharer: alice,
            viewer: bob,
            roomId: roomId
        )
        let plan = ScreenShareGroupCallSDPPolicy.answerModificationPlan(
            remoteOfferSdp: offer,
            localIsSharingScreen: false
        )
        let expected = ScreenShareGroupCallContract.expectation(
            for: .viewerAnswerWhileReceiving(sharerId: alice, viewerIsSharing: false)
        )
        #expect(expected.midDirections[.screen] == "recvonly")
        #expect(plan.forceReceiveOnlyVideoMids == [ScreenShareGroupCallContract.MediaMid.screen.rawValue])
        #expect(plan.preserveVideoDirectionsForMids.contains(ScreenShareGroupCallContract.MediaMid.screen.rawValue))
    }

    @Test("answer plan skips force recvonly when viewer is sharing")
    func answerPlanSkipsForceRecvonlyWhenViewerSharing() {
        let offer = ScreenShareSDPFixtures.sfuInboundStartShareOffer(
            sharer: alice,
            viewer: bob,
            roomId: roomId
        )
        let plan = ScreenShareGroupCallSDPPolicy.answerModificationPlan(
            remoteOfferSdp: offer,
            localIsSharingScreen: true
        )
        #expect(plan.forceReceiveOnlyVideoMids.isEmpty)
    }

    @Test("preempt wait requires explicit inactive SDP, not missing msid")
    func preemptWaitRequiresExplicitInactiveSdp() {
        #expect(ScreenShareGroupCallContract.preemptWaitRequiresExplicitStopInSDP)

        #expect(
            ScreenShareGroupCallSDPPolicy.shouldTreatRemoteSharerAsStoppedAfterPreempt(
                participantId: bob,
                stopWasRequested: true,
                explicitInactiveParticipantIds: []
            ) == false
        )

        #expect(
            ScreenShareGroupCallSDPPolicy.shouldTreatRemoteSharerAsStoppedAfterPreempt(
                participantId: bob,
                stopWasRequested: true,
                explicitInactiveParticipantIds: [bob]
            )
        )

        #expect(
            ScreenShareGroupCallSDPPolicy.shouldTreatRemoteSharerAsStoppedAfterPreempt(
                participantId: bob,
                stopWasRequested: false,
                explicitInactiveParticipantIds: [bob]
            ) == false
        )

        #expect(
            ScreenShareGroupCallSDPPolicy.shouldTreatRemoteSharerAsStoppedAfterPreempt(
                participantId: bob,
                stopWasRequested: true,
                explicitInactiveParticipantIds: [],
                screenIngressCeased: true
            )
        )
    }

    @Test("placeholder SFU relay offers duplicate camera SSRC on screen mid")
    func placeholderRelayOfferDuplicatesCameraSsrc() {
        let placeholder = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        a=ssrc:100 cname:c0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=ssrc:200 cname:c1
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:2
        a=sendrecv
        a=ssrc:200 cname:c1
        """

        let distinct = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=ssrc:200 cname:c1
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:2
        a=sendrecv
        a=ssrc:300 cname:c2
        a=msid:screen_\(alice) screen_\(alice)_\(roomId)
        """

        #expect(
            ScreenShareGroupCallSDPPolicy.sfuRelayScreenOfferUsesPlaceholderDuplicateSsrc(
                remoteOfferSdp: placeholder
            )
        )
        #expect(
            ScreenShareGroupCallSDPPolicy.sfuRelayScreenOfferUsesPlaceholderDuplicateSsrc(
                remoteOfferSdp: distinct
            ) == false
        )
        #expect(ScreenShareGroupCallSDPPolicy.firstRtpSsrc(forMid: "2", in: distinct) == 300)
    }

    @Test("placeholder SFU relay offers duplicate camera SSRC on mid=3 after share cycles")
    func placeholderRelayOfferDuplicatesCameraSsrcOnHigherMid() {
        let cycleThreePlaceholder = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        a=ssrc:100 cname:c0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=ssrc:200 cname:c1
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:2
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:3
        a=sendrecv
        a=ssrc:200 cname:c1
        """

        #expect(
            ScreenShareGroupCallSDPPolicy.sfuRelayScreenOfferUsesPlaceholderDuplicateSsrc(
                remoteOfferSdp: cycleThreePlaceholder
            )
        )
        let sanitized = ScreenShareGroupCallSDPPolicy.sanitizedInboundSfuOfferRemovingRelayPlaceholderDuplicateSsrc(
            remoteOfferSdp: cycleThreePlaceholder
        )
        #expect(
            ScreenShareGroupCallSDPPolicy.sfuRelayScreenOfferUsesPlaceholderDuplicateSsrc(
                remoteOfferSdp: sanitized
            ) == false
        )
        #expect(ScreenShareGroupCallSDPPolicy.firstRtpSsrc(forMid: "3", in: sanitized) == nil)
    }

    @Test("sharer restores outbound screen after SFU answer contract flag")
    func sharerRestoresOutboundScreenAfterSfuAnswerFlag() {
        #expect(ScreenShareGroupCallContract.sharerRestoresOutboundScreenAfterSfuAnswer)
    }

    @Test("serialize concurrent SFU renegotiation offers contract flag")
    func serializeConcurrentSfuRenegotiationOffersFlag() {
        #expect(ScreenShareGroupCallContract.serializeConcurrentSfuRenegotiationOffers)
    }

    @Test("global contract flags are enabled for conference SFU rooms")
    func globalContractFlags() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "alice", deviceId: "d1")
        let recipient = try Call.Participant(secretName: "bob", nickname: "bob", deviceId: "d2")
        var conference = try Call(
            sharedCommunicationId: "#\(roomId)",
            channelWireId: "#\(roomId)",
            sender: sender,
            recipients: [recipient]
        )
        conference.conferencePassword = "secret"
        #expect(ScreenShareGroupCallContract.exclusiveSharePerRoom)
        #expect(RTCSession.shouldEnforceExclusiveRoomScreenShare(call: conference))
    }
}
