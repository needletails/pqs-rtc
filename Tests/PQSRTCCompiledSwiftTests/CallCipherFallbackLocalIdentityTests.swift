import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// A receiver that holds no local frame bundle when `call_cipher` arrives must create its fallback
/// identity under its own name.
///
/// `receiveCiphertext` hands the local props to the sender-key path. If they carry the remote
/// peer's name, that path takes them for the peer's identity: the receiver initiates its sender
/// media ratchet against its own public keys, and the peer can never derive the receiver's key.
@Suite(.serialized)
struct CallCipherFallbackLocalIdentityTests {
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

    private let connectionId = "4f1d2c3b-5a69-4e7d-9c8b-7a6f5e4d3c2b"

    private func makeSession(local: Call.Participant, transport: CipherTransport) async -> RTCSession {
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "u",
            password: "p",
            delegate: transport)
        await session.setSessionParticipant(local)
        return session
    }

    /// Delivers the `call_cipher` the way `finishCryptoSessionCreation` hands it to `receiveCiphertext`.
    private func deliver(_ cipher: SentCallCipher, to session: RTCSession, remote: Call.Participant) async throws {
        let resolved = try await session.resolveProperRecipient(call: cipher.call)
        try await session.receiveCiphertext(
            recipient: remote.secretName,
            ciphertext: cipher.ciphertext,
            call: resolved)
    }

    @Test("A receiver without a local bundle answers call_cipher with a sender key the peer can derive")
    func receiverWithoutLocalBundleKeepsSenderKeyDerivable() async throws {
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")

        // Alice: an ordinary caller with her local bundle and PeerConnection.
        let aliceTransport = CipherTransport()
        let aliceSession = await makeSession(local: alice, transport: aliceTransport)
        let aliceFrameIdentity = try await aliceSession.keyManager.generateSenderIdentity(
            connectionId: connectionId,
            secretName: alice.secretName)
        _ = try await aliceSession.pcKeyManager.generateSenderIdentity(
            connectionId: connectionId,
            secretName: alice.secretName)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let alicePeerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        await aliceSession.connectionManager.addConnection(RTCConnection(
            id: connectionId,
            peerConnection: alicePeerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[CallCipherFallbackLocalIdentityTests]"),
                continuation: continuation),
            sender: alice.secretName,
            recipient: bob.secretName,
            localKeys: aliceFrameIdentity.localKeys,
            symmetricKey: aliceFrameIdentity.symmetricKey,
            sessionIdentity: aliceFrameIdentity.sessionIdentity,
            call: try Call(sharedCommunicationId: connectionId, sender: alice, recipients: [bob])))

        // Alice derives A1 against the frame identity Bob advertised before his bundle was lost.
        let lostBobBundle = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: bob.secretName)
        var aliceCall = try Call(sharedCommunicationId: connectionId, sender: alice, recipients: [bob])
        aliceCall.frameIdentityProps = try #require(await lostBobBundle.sessionIdentity.props(symmetricKey: lostBobBundle.symmetricKey))
        let aliceConnection = try #require(await aliceSession.connectionManager.findConnection(with: connectionId))
        try await aliceSession.setMessageKey(connection: aliceConnection, call: aliceCall)
        guard let a1 = await aliceTransport.sent.last else { throw TestError.missingCallCipher("A1") }

        // Bob answered on this device but holds no local frame bundle and no PeerConnection when
        // A1 arrives, so receiveCiphertext creates both.
        let bobTransport = CipherTransport()
        let bobSession = await makeSession(local: bob, transport: bobTransport)
        await bobSession.setCanAnswer(true)
        try await deliver(a1, to: bobSession, remote: alice)
        guard let b1 = await bobTransport.sent.last else { throw TestError.missingCallCipher("B1") }

        #expect(b1.call.frameIdentityProps?.secretName == bob.secretName,
                "Bob's fallback frame identity was created under the remote peer's name")

        try await deliver(b1, to: aliceSession, remote: bob)

        let bobSenderKey = await bobSession.exportFrameEncryptionKey(
            index: 0,
            for: RTCSession.senderFrameKeyParticipantIdForSetMessageKey(connectionLocalParticipantId: bob.secretName))
        let aliceReceiveKeyForBob = await aliceSession.exportFrameEncryptionKey(index: 0, for: bob.secretName)
        #expect(!bobSenderKey.isEmpty)
        #expect(aliceReceiveKeyForBob == bobSenderKey,
                "Bob initiated his sender media ratchet against his own identity, so Alice cannot decrypt him")

        await aliceSession.shutdown(with: nil)
        await bobSession.shutdown(with: nil)
        alicePeerConnection.close()
    }
}
#endif
