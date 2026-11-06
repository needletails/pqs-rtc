import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// A refreshed `call_cipher` must replace the receive key even when the receiver is already
/// `.complete`.
///
/// Alice first derives her sender key against a stale frame identity for Bob. Bob's `call_cipher`
/// carries his real identity, so Alice refreshes her sender key and sends a second `call_cipher`.
/// Bob's view of Alice has not changed, but Alice's sender key has, so Bob must derive his receive
/// key for Alice from the refreshed ciphertext or he cannot decrypt her media for the rest of the call.
@Suite(.serialized)
struct RefreshedCallCipherReceiveKeyTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
        case missingCallCipher(String)
    }

    struct SentCallCipher: Sendable {
        let ciphertext: Data
        let call: Call
    }

    actor CipherTransport: RTCTransportEvents {
        private(set) var sent: [SentCallCipher] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {
            sent.append(SentCallCipher(ciphertext: ciphertext, call: call))
        }
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
    }

    struct Side {
        let session: RTCSession
        let transport: CipherTransport
        let peerConnection: RTCPeerConnection
        let local: Call.Participant
        let remote: Call.Participant
    }

    private let connectionId = "9b0c3f5e-2a47-4c1d-8e6f-1d2a3b4c5d6e"

    private func makeSide(local: Call.Participant, remote: Call.Participant) async throws -> Side {
        let transport = CipherTransport()
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "u",
            password: "p",
            delegate: transport)
        await session.setSessionParticipant(local)
        let frameIdentity = try await session.keyManager.generateSenderIdentity(
            connectionId: connectionId,
            secretName: local.secretName)
        _ = try await session.pcKeyManager.generateSenderIdentity(
            connectionId: connectionId,
            secretName: local.secretName)

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        let call = try Call(sharedCommunicationId: connectionId, sender: local, recipients: [remote])
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        await session.connectionManager.addConnection(RTCConnection(
            id: connectionId,
            peerConnection: peerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[RefreshedCallCipherReceiveKeyTests]"),
                continuation: continuation),
            sender: local.secretName,
            recipient: remote.secretName,
            localKeys: frameIdentity.localKeys,
            symmetricKey: frameIdentity.symmetricKey,
            sessionIdentity: frameIdentity.sessionIdentity,
            call: call))
        return Side(session: session, transport: transport, peerConnection: peerConnection, local: local, remote: remote)
    }

    /// Delivers the `call_cipher` the way `finishCryptoSessionCreation` hands it to `receiveCiphertext`.
    private func deliver(_ cipher: SentCallCipher, to side: Side) async throws {
        let resolved = try await side.session.resolveProperRecipient(call: cipher.call)
        try await side.session.receiveCiphertext(
            recipient: side.remote.secretName,
            ciphertext: cipher.ciphertext,
            call: resolved)
    }

    private func lastCipher(from side: Side, _ label: String) async throws -> SentCallCipher {
        guard let cipher = await side.transport.sent.last else { throw TestError.missingCallCipher(label) }
        return cipher
    }

    @Test("A complete receiver adopts the refreshed call_cipher after the sender re-derives")
    func completeReceiverAdoptsRefreshedCallCipher() async throws {
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        let aliceSide = try await makeSide(local: alice, remote: bob)
        let bobSide = try await makeSide(local: bob, remote: alice)

        // Alice's first sender derivation uses a stale frame identity for Bob.
        let stale = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: bob.secretName)
        let staleBobProps = try #require(await stale.sessionIdentity.props(symmetricKey: stale.symmetricKey))
        var aliceCall = try Call(sharedCommunicationId: connectionId, sender: alice, recipients: [bob])
        aliceCall.frameIdentityProps = staleBobProps
        let aliceConnection = try #require(await aliceSide.session.connectionManager.findConnection(with: connectionId))
        try await aliceSide.session.setMessageKey(connection: aliceConnection, call: aliceCall)
        let a1 = try await lastCipher(from: aliceSide, "A1")

        // Bob answers with his real identity and completes.
        try await deliver(a1, to: bobSide)
        let b1 = try await lastCipher(from: bobSide, "B1")
        #expect(await bobSide.session.connectionManager.findConnection(with: connectionId)?.cipherNegotiationState == .complete)

        // Alice sees Bob's real identity, refreshes her sender key and sends A2.
        try await deliver(b1, to: aliceSide)
        let a2 = try await lastCipher(from: aliceSide, "A2")
        #expect(await aliceSide.transport.sent.count == 2, "Alice should send one refreshed call_cipher")
        #expect(a2.ciphertext != a1.ciphertext)

        try await deliver(a2, to: bobSide)
        #expect(await bobSide.transport.sent.count == 1, "Bob must not answer a refresh with another call_cipher")

        let aliceSenderKey = await aliceSide.session.exportFrameEncryptionKey(
            index: 0,
            for: RTCSession.senderFrameKeyParticipantIdForSetMessageKey(connectionLocalParticipantId: alice.secretName))
        let bobReceiveKeyForAlice = await bobSide.session.exportFrameEncryptionKey(index: 0, for: alice.secretName)
        #expect(!aliceSenderKey.isEmpty)
        #expect(bobReceiveKeyForAlice == aliceSenderKey, "Bob kept the receive key from Alice's stale call_cipher")

        // Bob -> Alice was never stale and must keep working.
        let bobSenderKey = await bobSide.session.exportFrameEncryptionKey(
            index: 0,
            for: RTCSession.senderFrameKeyParticipantIdForSetMessageKey(connectionLocalParticipantId: bob.secretName))
        #expect(await aliceSide.session.exportFrameEncryptionKey(index: 0, for: bob.secretName) == bobSenderKey)

        for side in [aliceSide, bobSide] {
            await side.session.shutdown(with: nil)
            side.peerConnection.close()
        }
    }
}
#endif
