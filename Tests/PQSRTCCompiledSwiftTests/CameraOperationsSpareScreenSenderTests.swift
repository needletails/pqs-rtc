import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// Camera-only operations (camera off, camera sender rebuild, adaptive camera targets) must not
/// touch the local screen-share sender that sits next to the camera sender on the same peer connection.
@Suite(.serialized)
struct CameraOperationsSpareScreenSenderTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
        case senderCreationFailed
    }

    private let connectionId = "camera-screen-sender-split"

    private struct Fixture {
        let session: RTCSession
        let cameraTrack: RTCVideoTrack
        let screenTrack: RTCVideoTrack
        let cameraSender: RTCRtpSender
        let screenSender: RTCRtpSender
    }

    /// A video call that is sharing its screen: a camera sender and a screen sender on one peer connection,
    /// added the way `createLocalVideoTrack` and `addAppleScreenSender` add them.
    private func makeSharingCall() async throws -> Fixture {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }

        let participant = "nudge"
        let cameraTrack = RTCSession.factory.videoTrack(
            with: RTCSession.factory.videoSource(),
            trackId: "video_\(participant)_\(connectionId)"
        )
        let screenTrack = RTCSession.factory.videoTrack(
            with: RTCSession.factory.videoSource(),
            trackId: "\(RTCSession.screenTrackPrefix)\(participant)_\(connectionId)"
        )
        guard let cameraSender = peerConnection.add(cameraTrack, streamIds: ["streamId_\(connectionId)"]),
              let screenSender = peerConnection.add(screenTrack, streamIds: ["\(RTCSession.screenStreamPrefix)\(participant)"]) else {
            throw TestError.senderCreationFailed
        }

        let sender = try Call.Participant(secretName: participant, nickname: participant, deviceId: "nudge-device")
        var call = try Call(
            sharedCommunicationId: connectionId,
            channelWireId: connectionId,
            sender: sender,
            recipients: []
        )
        call.supportsVideo = true

        let localIdentity = try await KeyManager().generateSenderIdentity(
            connectionId: connectionId,
            secretName: participant
        )
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        var connection = RTCConnection(
            id: connectionId,
            peerConnection: peerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[CameraOperationsSpareScreenSenderTests]"),
                continuation: continuation
            ),
            sender: participant,
            recipient: "peer",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
        connection.localVideoTrack = cameraTrack
        connection.localScreenTrack = screenTrack

        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        await session.connectionManager.addConnection(connection)
        return Fixture(
            session: session,
            cameraTrack: cameraTrack,
            screenTrack: screenTrack,
            cameraSender: cameraSender,
            screenSender: screenSender
        )
    }

    @Test("Turning the camera off leaves the screen-share track enabled")
    func cameraOffLeavesScreenShareTrackEnabled() async throws {
        let fixture = try await makeSharingCall()
        let session = fixture.session
        defer { Task { await session.shutdown(with: nil) } }

        await fixture.session.setVideoTrack(isEnabled: false, connectionId: connectionId)

        #expect(fixture.cameraTrack.isEnabled == false)
        #expect(fixture.screenTrack.isEnabled == true)
    }

    @Test("Rebuilding the camera sender pipeline leaves the screen track on the screen sender")
    func cameraPipelineRebuildLeavesScreenSenderTrack() async throws {
        let fixture = try await makeSharingCall()
        let session = fixture.session
        defer { Task { await session.shutdown(with: nil) } }

        let rebuilt = await fixture.session.restartLocalVideoSenderPipeline(connectionId: connectionId)

        #expect(rebuilt)
        #expect(fixture.screenSender.track?.trackId == fixture.screenTrack.trackId)
        #expect(fixture.cameraSender.track?.trackId != fixture.cameraTrack.trackId)
    }

    @Test("Adaptive camera targets are not applied to the screen-share sender")
    func adaptiveCameraTargetsSpareScreenSender() async throws {
        let fixture = try await makeSharingCall()
        let session = fixture.session
        defer { Task { await session.shutdown(with: nil) } }
        let screenEncodingsBefore = fixture.screenSender.parameters.encodings.map {
            [$0.maxBitrateBps, $0.maxFramerate, $0.scaleResolutionDownBy]
        }

        guard let connection = await fixture.session.connectionManager.findConnection(with: connectionId) else {
            Issue.record("connection missing")
            return
        }
        let targets = AdaptiveVideoTargets(
            maxBitrateBps: RTCAdaptiveVideoTargets.survivalBitrateBps,
            maxFramerate: RTCAdaptiveVideoTargets.survivalFramerate,
            scaleResolutionDownBy: RTCAdaptiveVideoTargets.survivalScaleResolutionDownBy
        )
        await fixture.session.applyVideoSenderTargets(targets, connection: connection)

        let cameraEncoding = try #require(fixture.cameraSender.parameters.encodings.first)
        #expect(cameraEncoding.maxFramerate?.intValue == targets.maxFramerate)
        #expect(cameraEncoding.scaleResolutionDownBy?.doubleValue == targets.scaleResolutionDownBy)
        let screenEncodingsAfter = fixture.screenSender.parameters.encodings.map {
            [$0.maxBitrateBps, $0.maxFramerate, $0.scaleResolutionDownBy]
        }
        #expect(screenEncodingsAfter == screenEncodingsBefore)
    }
}
#endif
