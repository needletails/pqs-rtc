import Foundation
import Testing
import BinaryCodable
import DoubleRatchetKit
import Crypto
import Dispatch
#if canImport(WebRTC) && !os(Android)
import WebRTC

@testable import PQSRTC

/// An inbound `screenSharePreempt` stops the local share, which sends an SFU renegotiation
/// offer and waits for it on the wire. That offer is a sibling TaskProcessor job, so the
/// wait must not run inside the inbound job or the signalling lane wedges.
@Suite(.serialized)
struct InboundScreenSharePreemptSignallingLaneTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [(call: Call, sfuRecipientId: String)] = []
        private(set) var sfuFlags: [PacketFlag] = []
        private(set) var sfuPackets: [RatchetMessagePacket] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
            sfuFlags.append(packet.flag)
            sfuPackets.append(packet)
        }
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {
            negotiated.append((call: call, sfuRecipientId: sfuRecipientId))
        }
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
    func inboundPreemptWhileSharing_sendsRenegotiationOfferAndDrainsLane() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let localDeviceId = try #require(UUID(uuidString: "2D4087FD-0E8A-4D96-B558-33142F345AD2"))
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: localDeviceId.uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.negotiated.isEmpty == false }
        try #require(negotiated)
        let negotiatedCall = await transport.negotiated.last!.call
        let clientProps = try #require(negotiatedCall.signalingIdentityProps)

        let sfuKeyStore = KeyManager()
        let sfuLocalIdentity = try await sfuKeyStore.generateSenderIdentity(
            connectionId: sfuRecipientId,
            secretName: sfuRecipientId
        )
        let sfuProps = try #require(await sfuLocalIdentity.sessionIdentity.props(symmetricKey: sfuLocalIdentity.symmetricKey))
        let serverClientIdentity = try await sfuKeyStore.createSFUSignalingRecipientIdentity(
            roomId: negotiatedCall.sharedCommunicationId,
            deviceId: localDeviceId,
            sessionContext: negotiatedCall.id.uuidString,
            props: clientProps,
            aliases: [sfuRecipientId]
        )
        let sfuRatchet = MessageRatchet(executor: RatchetExecutor(queue: DispatchQueue(label: "tests.sfu.preempt")))

        var call = negotiatedCall
        call.signalingIdentityProps = sfuProps
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)
        try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId: sfuRecipientId, updatedCall: call)
        let gotOffer = await waitUntil(timeoutSeconds: 5.0) { await transport.offerCount() == 1 }
        try #require(gotOffer)

        // SFU side: accept the client's offer, then open its send chain to the client.
        let offerPacket = try #require(await transport.sfuPackets.last(where: { $0.flag == .offer }))
        try await sfuRatchet.respondToSession(
            sessionIdentity: serverClientIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            header: offerPacket.header,
            localKeys: sfuLocalIdentity.localKeys
        )
        _ = try await sfuRatchet.decrypt(offerPacket.ratchetMessage, sessionId: serverClientIdentity.sessionIdentity.id)
        try await sfuRatchet.initiateSession(
            sessionIdentity: serverClientIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: try X25519PublicKey(clientProps.longTermPublicKey),
                oneTime: clientProps.oneTimePublicKey,
                mlKEM: clientProps.mlKEMPublicKey
            ),
            localKeys: sfuLocalIdentity.localKeys
        )

        // The local participant is sharing its screen.
        var connection = try #require(await session.connectionManager.findConnection(with: sfuRecipientId))
        connection.localScreenTrack = RTCSession.factory.videoTrack(
            with: RTCSession.factory.videoSource(),
            trackId: "screen_alice"
        )
        await session.connectionManager.updateConnection(id: connection.id, with: connection)

        // Another participant takes over: the SFU forwards a preempt naming alice.
        var preemptCall = call
        preemptCall.metadata = try BinaryEncoder().encode(
            ScreenSharePreemptCommand(targetParticipantSecretName: "alice")
        )
        let preemptMessage = try await sfuRatchet.encrypt(
            plainText: try BinaryEncoder().encode(preemptCall),
            sessionId: serverClientIdentity.sessionIdentity.id
        )
        try await session.taskProcessor.feedTask(
            task: EncryptableTask(
                task: .streamMessage(
                    StreamTask(
                        senderSecretName: sfuRecipientId,
                        senderDeviceId: nil,
                        packet: RatchetMessagePacket(
                            sfuIdentity: sfuRecipientId,
                            header: preemptMessage.header,
                            ratchetMessage: preemptMessage,
                            flag: .screenSharePreempt
                        ),
                        call: call
                    )
                )
            )
        )

        let renegotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.offerCount() == 2 }
        #expect(renegotiated, "Stop-share renegotiation offer never reached the wire: inbound preempt job waits on its own sibling write")
        let laneDrained = await waitUntil(timeoutSeconds: 5.0) { await session.taskProcessor.jobs.isEmpty }
        #expect(laneDrained, "Signalling lane wedged behind the inbound screenSharePreempt job")
        let stopped = await session.connectionManager.findConnection(with: sfuRecipientId)
        #expect(stopped?.localScreenTrack == nil)

        await session.shutdown(with: nil)
        try? await sfuRatchet.flushAndClose()
    }
}
#endif
