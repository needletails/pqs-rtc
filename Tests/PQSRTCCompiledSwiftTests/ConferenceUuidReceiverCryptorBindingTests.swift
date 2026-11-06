import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
@preconcurrency import WebRTC

/// A UUID-labelled conference receiver must not take over a mapped participant's FrameCryptor.
///
/// In a multi-party room a UUID stream id says nothing about who owns the track, so the receiver
/// waits for a stable owner (see GroupSfuFrameE2EE). If the resolver guesses the only mapped
/// remote camera owner instead, the receiver slot for that owner is rebound to the new track and
/// the owner's real camera cryptor is disabled.
@Suite(.serialized)
struct ConferenceUuidReceiverCryptorBindingTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
        case negotiationFailed(String)
    }

    private let connectionId = "conf-5b1f3c2e-7d4a-4c8e-9f60-2a7b8c9d0e1f"
    private let localSecretName = "echo"

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return pc
    }

    private func makeConnection(peerConnection: RTCPeerConnection) async throws -> RTCConnection {
        let sender = try Call.Participant(secretName: localSecretName, nickname: localSecretName, deviceId: "echo-device")
        var call = try Call(sharedCommunicationId: connectionId, sender: sender, recipients: [])
        call.supportsVideo = true
        let localIdentity = try await KeyManager().generateSenderIdentity(
            connectionId: connectionId,
            secretName: localSecretName)
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        return RTCConnection(
            id: connectionId,
            peerConnection: peerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[ConferenceUuidReceiverCryptorBindingTests]"),
                continuation: continuation),
            sender: localSecretName,
            recipient: connectionId,
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call)
    }

    /// Negotiates `tracks` (track id, stream id) from a stand-in SFU onto `receiver`.
    private func negotiate(
        _ tracks: [(trackId: String, streamId: String)],
        onto receiver: RTCPeerConnection
    ) async throws -> RTCPeerConnection {
        let sfu = try makePeerConnection()
        for track in tracks {
            let video = RTCSession.factory.videoTrack(with: RTCSession.factory.videoSource(), trackId: track.trackId)
            guard sfu.add(video, streamIds: [track.streamId]) != nil else {
                throw TestError.negotiationFailed("could not add \(track.trackId)")
            }
        }
        let noReceive = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil)
        let offer = try await sfu.offer(for: noReceive)
        try await sfu.setLocalDescription(offer)
        try await receiver.setRemoteDescription(offer)
        let receiveVideo = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "true"],
            optionalConstraints: nil)
        let answer = try await receiver.answer(for: receiveVideo)
        try await receiver.setLocalDescription(answer)
        try await sfu.setRemoteDescription(answer)
        return sfu
    }

    @Test("A UUID-labelled conference receiver leaves the mapped owner's camera cryptor bound")
    func uuidLabelledConferenceReceiverLeavesMappedOwnerCryptorBound() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        await session.testing_configureGroupSessionForTests(activeConnectionId: connectionId)

        // alice and bob have both sent their group frame keys.
        await session.setFrameEncryptionKey(Data(repeating: 0xA1, count: 32), index: 0, for: "alice")
        await session.setFrameEncryptionKey(Data(repeating: 0xB0, count: 32), index: 0, for: "bob")

        // alice's camera is mapped and decrypting; a second camera arrives under a UUID placeholder.
        let aliceTrackId = "video_alice_\(connectionId)"
        let placeholderTrackId = UUID().uuidString
        let placeholderStreamId = UUID().uuidString
        let peerConnection = try makePeerConnection()
        let sfu = try await negotiate(
            [(aliceTrackId, "alice"), (placeholderTrackId, placeholderStreamId)],
            onto: peerConnection)
        let aliceReceiver = try #require(peerConnection.receivers.first { $0.track?.trackId == aliceTrackId })
        let aliceTrack = try #require(aliceReceiver.track as? RTCVideoTrack)
        #expect(peerConnection.receivers.contains { $0.track?.trackId == placeholderTrackId })

        var connection = try await makeConnection(peerConnection: peerConnection)
        connection.remoteVideoTracksByParticipantId["alice"] = aliceTrack
        await session.connectionManager.addConnection(connection)
        try await session.createEncryptedFrame(
            connection: connection,
            kind: .videoReceiver(aliceReceiver),
            participantIdOverride: "alice")
        let aliceCryptor = try #require(
            await session.connectionManager.findConnection(with: connectionId)?.videoReceiverCryptorsByParticipantId["alice"])

        // Deliver the placeholder receiver through the real notification handler, then let it drain.
        let continuation = await session.peerConnectionNotificationsContinuation
        continuation.yield(.didAddReceiver(connectionId, "video", [placeholderStreamId], placeholderTrackId))
        continuation.finish()
        await session.handlePeerConnectionNotifications(generation: await session.notificationsTaskGeneration)

        let updated = try #require(await session.connectionManager.findConnection(with: connectionId))
        #expect(updated.videoReceiverCryptorBindingsByParticipantId["alice"]?.trackId == aliceTrackId,
                "alice's receiver slot was rebound to the UUID placeholder track")
        #expect(updated.videoReceiverCryptorsByParticipantId["alice"] === aliceCryptor)
        #expect(aliceCryptor.enabled, "alice's camera cryptor was disabled")

        await session.connectionManager.removeConnection(with: connectionId)
        peerConnection.close()
        sfu.close()
    }
}
#endif
