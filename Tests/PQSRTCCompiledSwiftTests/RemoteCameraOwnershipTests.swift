import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

@Suite(.serialized)
struct RemoteCameraOwnershipTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
        case negotiationFailed(String)
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return pc
    }

    private func makeConnection(id: String = "#camera-ownership") async throws -> RTCConnection {
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(
            connectionId: id,
            secretName: "echo"
        )
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: id,
            logger: NeedleTailLogger("[RemoteCameraOwnershipTests]"),
            continuation: continuation
        )
        let sender = try Call.Participant(secretName: "echo", nickname: "echo", deviceId: "echo-device")
        var call = try Call(
            sharedCommunicationId: id,
            channelWireId: id,
            sender: sender,
            recipients: []
        )
        call.supportsVideo = true
        return RTCConnection(
            id: id,
            peerConnection: try makePeerConnection(),
            delegateWrapper: delegateWrapper,
            sender: "echo",
            recipient: "sfu",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
    }

    private func makeCameraTrack(trackId: String = "f408cb20-8392-4dcc-bcc8-a5d94add83d6") -> RTCVideoTrack {
        let source = RTCSession.factory.videoSource()
        return RTCSession.factory.videoTrack(with: source, trackId: trackId)
    }

    private func negotiateCameraOntoReceiver(
        receiver: RTCPeerConnection,
        participantId: String,
        trackId: String
    ) async throws -> String {
        let sender = try makePeerConnection()
        let cameraTrack = makeCameraTrack(trackId: trackId)
        guard sender.add(cameraTrack, streamIds: ["video_\(participantId)"]) != nil else {
            throw TestError.negotiationFailed("Failed to add camera sender track")
        }

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )
        let offer = try await sender.offer(for: offerConstraints)
        try await sender.setLocalDescription(offer)
        try await receiver.setRemoteDescription(offer)

        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        let answer = try await receiver.answer(for: answerConstraints)
        try await receiver.setLocalDescription(answer)
        try await sender.setRemoteDescription(answer)

        return offer.sdp
    }

    @Test("stable camera track ownership rejects duplicate participant claim")
    func stableCameraTrackOwnershipRejectsDuplicateParticipantClaim() async throws {
        var connection = try await makeConnection()
        let track = makeCameraTrack()

        #expect(RTCSession.claimRemoteCameraTrack(track, participantId: "frank", in: &connection))
        #expect(!RTCSession.claimRemoteCameraTrack(track, participantId: "nudge", in: &connection))

        #expect(connection.remoteVideoTracksByParticipantId["frank"] === track)
        #expect(connection.remoteVideoTracksByParticipantId["nudge"] == nil)
    }

    @Test("stable camera claim can replace the same participant's previous track")
    func stableCameraClaimCanReplaceSameParticipantTrack() async throws {
        var connection = try await makeConnection()
        let staleTrack = makeCameraTrack(trackId: "old-camera-track")
        let freshTrack = makeCameraTrack(trackId: "new-camera-track")

        #expect(RTCSession.claimRemoteCameraTrack(staleTrack, participantId: "frank", in: &connection))
        #expect(RTCSession.claimRemoteCameraTrack(freshTrack, participantId: "frank", in: &connection))

        #expect(connection.remoteVideoTracksByParticipantId["frank"] === freshTrack)
    }

    @Test("stable camera claim removes UUID placeholder aliases for the same track")
    func stableCameraClaimRemovesUUIDPlaceholderAliasesForSameTrack() async throws {
        var connection = try await makeConnection()
        let placeholder = UUID().uuidString
        let track = makeCameraTrack()
        connection.remoteVideoTracksByParticipantId[placeholder] = track

        #expect(RTCSession.claimRemoteCameraTrack(track, participantId: "frank", in: &connection))

        #expect(connection.remoteVideoTracksByParticipantId[placeholder] == nil)
        #expect(connection.remoteVideoTracksByParticipantId["frank"] === track)
    }

    @Test("stable camera claim can transfer ownership only with SDP evidence")
    func stableCameraClaimCanTransferOwnershipOnlyWithSdpEvidence() async throws {
        var connection = try await makeConnection()
        let track = makeCameraTrack()

        #expect(RTCSession.claimRemoteCameraTrack(track, participantId: "frank", in: &connection))
        #expect(!RTCSession.claimRemoteCameraTrack(track, participantId: "nudge", in: &connection))
        #expect(RTCSession.claimRemoteCameraTrack(
            track,
            participantId: "nudge",
            in: &connection,
            allowReplacingExistingStableOwner: true
        ))

        #expect(connection.remoteVideoTracksByParticipantId["frank"] == nil)
        #expect(connection.remoteVideoTracksByParticipantId["nudge"] === track)
    }

    @Test("group camera resolver does not fall back to unrelated live receiver")
    func groupCameraResolverDoesNotFallbackToUnrelatedLiveReceiver() async throws {
        let receiver = try makePeerConnection()
        _ = try await negotiateCameraOntoReceiver(
            receiver: receiver,
            participantId: "frank",
            trackId: "video_frank_live"
        )

        let resolvedWithoutEvidence = RTCSession.resolveLiveGroupParticipantCameraTrack(
            storedTrackId: "missing_nudge_track",
            in: receiver
        )
        #expect(resolvedWithoutEvidence == nil)
    }

    @Test("group camera resolver accepts explicitly advertised owner track")
    func groupCameraResolverAcceptsExplicitlyAdvertisedOwnerTrack() async throws {
        let receiver = try makePeerConnection()
        let offerSdp = try await negotiateCameraOntoReceiver(
            receiver: receiver,
            participantId: "frank",
            trackId: "video_frank_live"
        )
        let owners = RTCSession.advertisedRemoteCameraOwnersByTrackId(in: offerSdp)
        #expect(owners["video_frank_live"] == "frank")

        let resolvedWithEvidence = RTCSession.resolveLiveGroupParticipantCameraTrack(
            storedTrackId: "missing_frank_track",
            advertisedTrackIds: Set(owners.filter { $0.value == "frank" }.map(\.key)),
            in: receiver
        )
        #expect(resolvedWithEvidence?.trackId == "video_frank_live")
    }

    @Test("camera owner parser normalizes SFU media-id stream labels")
    func cameraOwnerParserNormalizesSfuMediaIdStreamLabels() {
        let roomId = "493b6051-39f0-493d-aace-7683f2bfa9e2"
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        a=msid:video_echo_\(roomId) video_echo_\(roomId)
        """

        let owners = RTCSession.advertisedRemoteCameraOwnersByTrackId(in: sdp)
        #expect(owners["video_echo_\(roomId)"] == "echo")
    }

    @Test("camera owner parser maps publisher nick stream labels for UUID relay tracks")
    func cameraOwnerParserMapsPublisherNickStreamLabelsForUuidRelayTracks() {
        let uuidTrackId = "1136667b-26d1-4f77-8ba3-c800f3c449fb"
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        a=msid:frank \(uuidTrackId)
        """

        let owners = RTCSession.advertisedRemoteCameraOwnersByTrackId(in: sdp)
        #expect(owners[uuidTrackId] == "frank")
    }

    @Test("camera owner parser falls back to SFU media-id track labels")
    func cameraOwnerParserFallsBackToSfuMediaIdTrackLabels() {
        let roomId = "493b6051-39f0-493d-aace-7683f2bfa9e2"
        let transientStreamId = "d22a90ea-dbb7-4372-a22a-6801b30d2708"
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        a=msid:\(transientStreamId) video_frank_\(roomId)
        """

        let owners = RTCSession.advertisedRemoteCameraOwnersByTrackId(in: sdp)
        #expect(owners["video_frank_\(roomId)"] == "frank")
    }

    @Test("camera owner parser reads split-line msid track labels")
    func cameraOwnerParserReadsSplitLineMsidTrackLabels() {
        let roomId = "1a83d603-770e-49f6-9d7a-74a5767deee0"
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:4
        a=sendrecv
        a=msid:echo
        video_echo__\(roomId)
        a=ssrc:1890300104 msid:echo
        video_echo__\(roomId)
        """

        let owners = RTCSession.advertisedRemoteCameraOwnersByTrackId(in: sdp)
        #expect(owners["video_echo__\(roomId)"] == "echo")
    }

    @Test("sfu msid parser reads split-line track labels for advertised remote media ids")
    func sfuMsidParserReadsSplitLineTrackLabels() {
        let section = [
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:4",
            "a=sendrecv",
            "a=msid:echo",
            "video_echo__1a83d603-770e-49f6-9d7a-74a5767deee0",
        ]
        let entries = RTCSession.sfuSdpMsidEntries(inSectionLines: section)
        #expect(entries.count == 1)
        #expect(entries[0].streamLabel == "echo")
        #expect(entries[0].trackId == "video_echo__1a83d603-770e-49f6-9d7a-74a5767deee0")
    }
}
#endif
