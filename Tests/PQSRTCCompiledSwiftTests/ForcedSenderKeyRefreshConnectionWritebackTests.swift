import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// A forced sender-key refresh must not write back a connection snapshot taken before it sent the
/// refreshed `call_cipher`.
///
/// The send awaits the host transport, so the session actor can be re-entered meanwhile (for
/// example a receiver track arriving). `RTCConnection` is a struct: writing the pre-send copy back
/// reverts whatever was stored on the connection during the send.
@Suite(.serialized)
struct ForcedSenderKeyRefreshConnectionWritebackTests {
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
        private var duringSend: (@Sendable (Int) async -> Void)?

        func setDuringSend(_ hook: @escaping @Sendable (Int) async -> Void) {
            duringSend = hook
        }

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {
            sent.append(SentCallCipher(ciphertext: ciphertext, call: call))
            await duringSend?(sent.count)
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

    private let connectionId = "4f1e2d3c-5b6a-4987-8a1b-2c3d4e5f6a7b"

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
                logger: NeedleTailLogger("[ForcedSenderKeyRefreshConnectionWritebackTests]"),
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

    @Test("A forced sender-key refresh keeps connection changes made while the refreshed call_cipher was sending")
    func forcedRefreshKeepsConnectionChangesMadeDuringSend() async throws {
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        let aliceSide = try await makeSide(local: alice, remote: bob)
        let bobSide = try await makeSide(local: bob, remote: alice)

        // Alice's first sender derivation uses a stale frame identity for Bob, so Bob's real
        // identity in B1 makes her refresh her sender key with `force: true`.
        let stale = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: bob.secretName)
        let staleBobProps = try #require(await stale.sessionIdentity.props(symmetricKey: stale.symmetricKey))
        var aliceCall = try Call(sharedCommunicationId: connectionId, sender: alice, recipients: [bob])
        aliceCall.frameIdentityProps = staleBobProps
        let aliceConnection = try #require(await aliceSide.session.connectionManager.findConnection(with: connectionId))
        try await aliceSide.session.setMessageKey(connection: aliceConnection, call: aliceCall)
        let a1 = try await lastCipher(from: aliceSide, "A1")
        try await deliver(a1, to: bobSide)
        let b1 = try await lastCipher(from: bobSide, "B1")
        #expect(await aliceSide.session.connectionManager.findConnection(with: connectionId)?.cipherNegotiationState == .setSenderKey)

        // While Alice's refreshed call_cipher (her second send) is in flight, Bob's video
        // receiver track lands on her connection.
        nonisolated(unsafe) let bobVideoTrack = RTCSession.factory.videoTrack(
            with: RTCSession.factory.videoSource(),
            trackId: "bob-video")
        let aliceManager = await aliceSide.session.connectionManager
        let connectionId = connectionId
        await aliceSide.transport.setDuringSend { sendCount in
            guard sendCount == 2,
                  var connection = await aliceManager.findConnection(with: connectionId)
            else { return }
            connection.remoteVideoTracksByParticipantId[bob.secretName] = bobVideoTrack
            await aliceManager.updateConnection(id: connectionId, with: connection)
        }

        try await deliver(b1, to: aliceSide)
        #expect(await aliceSide.transport.sent.count == 2, "Alice should send one refreshed call_cipher")

        let after = try #require(await aliceSide.session.connectionManager.findConnection(with: connectionId))
        #expect(after.cipherNegotiationState == .complete)
        #expect(
            after.remoteVideoTracksByParticipantId[bob.secretName]?.trackId == "bob-video",
            "The forced refresh wrote back its pre-send connection snapshot and dropped Bob's receiver track")

        for side in [aliceSide, bobSide] {
            await side.session.shutdown(with: nil)
            side.peerConnection.close()
        }
    }
}
#endif
