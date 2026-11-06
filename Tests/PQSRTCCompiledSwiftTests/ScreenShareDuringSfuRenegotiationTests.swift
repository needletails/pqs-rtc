import Foundation
import Testing
import DoubleRatchetKit
#if canImport(WebRTC) && !os(Android)
import WebRTC

@testable import PQSRTC

/// Stopping (or starting) a share while an SFU renegotiation offer is applied on the same peer
/// connection must wait for that offer's answer. A local offer in `have-remote-offer` is
/// rejected by WebRTC, and the offer failure path ends the call.
@Suite(.serialized)
struct ScreenShareDuringSfuRenegotiationTests {
    actor Transport: RTCTransportEvents {
        private(set) var sfuFlags: [PacketFlag] = []
        private(set) var negotiated: [Call] = []
        private(set) var endedCount = 0

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
            sfuFlags.append(packet.flag)
        }
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws { endedCount += 1 }
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws { negotiated.append(call) }
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}

        func offerCount() -> Int { sfuFlags.filter { $0 == .offer }.count }
    }

    private func waitUntil(
        timeoutSeconds: Double,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    @Test
    func stopShareWhileSfuOfferIsApplied_waitsForAnswerInsteadOfEndingCall() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.negotiated.isEmpty == false }
        try #require(negotiated)
        var call = try #require(await transport.negotiated.last)

        let sfuKeyStore = KeyManager()
        let sfuIdentity = try await sfuKeyStore.generateSenderIdentity(connectionId: sfuRecipientId, secretName: sfuRecipientId)
        call.signalingIdentityProps = try #require(await sfuIdentity.sessionIdentity.props(symmetricKey: sfuIdentity.symmetricKey))
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)
        try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId: sfuRecipientId, updatedCall: call)
        let joinOfferSent = await waitUntil(timeoutSeconds: 5.0) { await transport.offerCount() == 1 }
        try #require(joinOfferSent)

        var connection = try #require(await session.connectionManager.findConnection(with: sfuRecipientId))
        let clientPC = connection.peerConnection
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let sfuPC = try #require(RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil))
        defer { sfuPC.close() }

        // SFU answers the join offer: the room is stable.
        try await sfuPC.setRemoteDescription(try #require(clientPC.localDescription))
        let joinAnswer = try await sfuPC.answer(for: constraints)
        try await sfuPC.setLocalDescription(joinAnswer)
        try await clientPC.setRemoteDescription(joinAnswer)
        #expect(clientPC.signalingState == .stable)

        // The local participant is sharing its screen.
        connection.localScreenTrack = RTCSession.factory.videoTrack(
            with: RTCSession.factory.videoSource(),
            trackId: "screen_alice"
        )
        await session.connectionManager.updateConnection(id: connection.id, with: connection)

        // A new participant publishes; the SFU sends a renegotiation offer. handleRenegotiationOffer
        // has applied it (setRemote) and is suspended before createAnswer.
        let initBob = RTCRtpTransceiverInit()
        initBob.direction = .sendOnly
        initBob.streamIds = ["bob"]
        _ = sfuPC.addTransceiver(of: .audio, init: initBob)
        let sfuOffer = try await sfuPC.offer(for: constraints)
        try await sfuPC.setLocalDescription(sfuOffer)
        let sfuOfferSdp = sfuOffer.sdp
        _ = try await session.setRemote(
            sdp: WebRTC.RTCSessionDescription(type: .offer, sdp: sfuOfferSdp),
            call: connection.call
        )
        #expect(clientPC.signalingState == .haveRemoteOffer)

        // The user stops sharing in that window.
        await session.removeScreenTrackFromStream(connectionId: connection.id)

        let survived = await session.connectionManager.findConnection(with: connection.id) != nil
        #expect(survived, "Stopping the share while an SFU offer was applied ended the call")
        #expect(await transport.endedCount == 0)
        if case .failed = await session.callState.currentState {
            Issue.record("Call failed: stop-share offer was created in have-remote-offer")
        }
        #expect(await transport.offerCount() == 1, "Stop-share offer must wait for the SFU offer's answer")
        try #require(survived)

        // handleRenegotiationOffer resumes and answers; the deferred stop-share offer then goes out.
        _ = try await session.createAnswer(call: connection.call)
        let stopOfferSent = await waitUntil(timeoutSeconds: 5.0) { await transport.offerCount() == 2 }
        #expect(stopOfferSent, "Deferred stop-share renegotiation offer never sent after the SFU answer")

        await session.shutdown(with: nil)
    }

    /// Android has no synchronous signaling state; the share gate reads the cached one.
    @Test
    func androidShareGateReadsCachedHaveRemoteOffer() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+ScreenShare.swift"),
            encoding: .utf8
        )
        let body = try SourceContract.sourceBody(of: "renegotiateScreenShareIfNeeded", in: source)
        #expect(body.contains("signalingStateByConnectionId[connection.id.normalizedConnectionId]?.state == .haveRemoteOffer"))
        #expect(body.contains("remoteOfferPending: remoteOfferPending"))
    }
}
#endif
