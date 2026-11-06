import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

extension RTCSession {
    /// State `renegotiateScreenShareIfNeeded` leaves once the local screen-share offer is sent.
    fileprivate func markScreenShareOfferAwaitingAnswer(connectionId: String) {
        setScreenShareRenegotiationActive(true, connectionId: connectionId)
        screenShareRenegotiationAwaitingAnswerConnectionIds.insert(connectionId.normalizedConnectionId)
    }

    fileprivate func hasDeferredSfuRenegotiationOffer(connectionId: String) -> Bool {
        pendingDeferredSfuRenegotiationOffers[teardownConnectionIdKey(connectionId)] != nil
    }
}

/// Glare: the SFU sends a renegotiation offer while our screen-share offer awaits its answer, so
/// the SFU offer is stashed. Applying the answer must replay it; a stash left behind is never
/// replayed, and the SFU's new media (for example a new member) never arrives.
@Suite(.serialized)
struct DeferredSfuOfferReplayAfterAnswerTests {
    actor TestTransportEvents: RTCTransportEvents {
        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
    }

    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return peerConnection
    }

    @Test("an SFU offer deferred while the local offer awaits its answer is replayed when the answer lands")
    func deferredSfuOfferIsReplayedWhenAnswerLands() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: events)
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let sfu = try Call.Participant(secretName: "sfu", nickname: "SFU", deviceId: "sfu-device")
        let connectionId = "conf-\(UUID().uuidString.lowercased())"
        let call = try Call(sharedCommunicationId: connectionId, sender: alice, recipients: [sfu], supportsVideo: false)
        await session.setSessionParticipant(alice)
        await session.testing_configureGroupSessionForTests(activeConnectionId: connectionId)

        // Local peer connection with its screen-share renegotiation offer sent: have-local-offer.
        let local = try makePeerConnection()
        _ = local.addTransceiver(of: .audio)
        let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let localOffer = try await local.offer(for: noConstraints)
        try await local.setLocalDescription(localOffer)
        await session.markScreenShareOfferAwaitingAnswer(connectionId: connectionId)

        // Local frame and signalling identities; the answer to the SFU offer carries their props.
        _ = try await session.keyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let identity = try await session.pcKeyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        await session.connectionManager.addConnection(RTCConnection(
            id: connectionId,
            peerConnection: local,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[DeferredSfuOfferReplayAfterAnswerTests]"),
                continuation: continuation
            ),
            sender: "alice",
            recipient: "sfu",
            localKeys: identity.localKeys,
            symmetricKey: identity.symmetricKey,
            sessionIdentity: identity.sessionIdentity,
            call: call
        ))

        // The SFU answers our offer, then offers a new relay m-line (a member joined).
        let sfuPeer = try makePeerConnection()
        try await sfuPeer.setRemoteDescription(localOffer)
        let answer = try await sfuPeer.answer(for: noConstraints)
        try await sfuPeer.setLocalDescription(answer)
        _ = sfuPeer.addTransceiver(of: .audio)
        let sfuOffer = try await sfuPeer.offer(for: noConstraints)
        try await sfuPeer.setLocalDescription(sfuOffer)

        // Glare: the SFU offer arrives first and is stashed.
        await #expect(throws: RTCErrors.self) {
            try await session.completeSfuRenegotiationOfferHandling(
                sdp: try SessionDescription(fromRTC: sfuOffer),
                call: call
            )
        }
        #expect(await session.hasDeferredSfuRenegotiationOffer(connectionId: connectionId))

        try await session.handleAnswer(call: call, sdp: try SessionDescription(fromRTC: answer))

        #expect(await !session.hasDeferredSfuRenegotiationOffer(connectionId: connectionId),
                "the deferred SFU offer was stashed again and nothing will replay it")
        #expect(local.remoteDescription?.type == .offer, "the SFU offer was not applied")
        #expect(local.localDescription?.type == .answer, "the SFU offer was not answered")
        #expect(local.signalingState == .stable)

        await session.shutdown(with: nil)
    }
}
#endif
