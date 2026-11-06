import Foundation
import Testing
import BinaryCodable
import DoubleRatchetKit
import Crypto
import Dispatch
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// SwiftSFU relays a member's post-cipher `.handshakeComplete` `Call` to every other member of
/// the room. That `Call` is the sender's own (its id, sender, recipients and SDP). Merging it
/// must keep the local group `Call`, or `leave(sfuRecipientId:call:)` sees a foreign owner id,
/// skips teardown, and the host never shuts the peer connection, mic and camera down.
@Suite(.serialized)
struct RelayedHandshakeCompleteMergeTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [(call: Call, sfuRecipientId: String)] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {
            negotiated.append((call: call, sfuRecipientId: sfuRecipientId))
        }
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
    }

    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private func waitUntil(
        timeoutSeconds: Double = 5.0,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    private func makeConnection(call: Call) async throws -> RTCConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        let localIdentity = try await KeyManager().generateSenderIdentity(
            connectionId: call.sharedCommunicationId,
            secretName: "alice"
        )
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: call.sharedCommunicationId,
            logger: NeedleTailLogger("[RelayedHandshakeCompleteMergeTests]"),
            continuation: continuation
        )
        return RTCConnection(
            id: call.sharedCommunicationId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "alice",
            recipient: "sfu",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
    }

    @Test("relayed handshakeComplete from another member keeps the local group call, so leave tears down")
    func relayedHandshakeCompleteKeepsLocalGroupCallSoLeaveTearsDown() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sharedCommunicationId = UUID().uuidString
        let channelWireId = "#travel_\(UUID().uuidString.lowercased())"
        let localDeviceId = UUID()
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: localDeviceId.uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)
        let carol = try Call.Participant(secretName: "carol", nickname: "Carol", deviceId: UUID().uuidString)
        let joinCall = try Call(
            sharedCommunicationId: sharedCommunicationId,
            channelWireId: channelWireId,
            sender: alice,
            recipients: [bob, carol],
            supportsVideo: false
        )

        await session.setSessionParticipant(alice)
        try await session.groupCallNegotiation(call: joinCall, sfuRecipientId: channelWireId)
        #expect(await waitUntil { await transport.negotiated.isEmpty == false })
        let negotiatedCall = try #require(await transport.negotiated.last?.call)
        let clientProps = try #require(negotiatedCall.signalingIdentityProps)

        // SFU registration reply, as in EndToEndGroupCallFlowTests.
        let sfuKeyStore = KeyManager()
        let sfuLocalIdentity = try await sfuKeyStore.generateSenderIdentity(
            connectionId: sharedCommunicationId,
            secretName: "sfu-\(sharedCommunicationId)"
        )
        let sfuProps = try #require(await sfuLocalIdentity.sessionIdentity.props(symmetricKey: sfuLocalIdentity.symmetricKey))
        let serverClientIdentity = try await sfuKeyStore.createSFUSignalingRecipientIdentity(
            roomId: sharedCommunicationId,
            deviceId: localDeviceId,
            sessionContext: negotiatedCall.id.uuidString,
            props: clientProps,
            aliases: [channelWireId]
        )
        var registrationReply = negotiatedCall
        registrationReply.signalingIdentityProps = sfuProps
        try await session.createSFUIdentity(sfuRecipientId: channelWireId, call: registrationReply)

        let group = try #require(await session.groupCallForRoom(channelWireId))
        let localCall = await group.currentCall
        await session.connectionManager.addConnection(try await makeConnection(call: localCall))

        // Bob's own post-cipher Call (his id, his SDP, his props), shaped like the handleAnswer
        // fanout, which SwiftSFU re-encrypts to alice unchanged.
        let bobIdentity = try await KeyManager().generateSenderIdentity(connectionId: sharedCommunicationId, secretName: "bob")
        let bobProps = try #require(await bobIdentity.sessionIdentity.props(symmetricKey: bobIdentity.symmetricKey))
        let bobKey = bobProps.longTermPublicKey
        var bobCall = try Call(
            sharedCommunicationId: sharedCommunicationId,
            channelWireId: channelWireId,
            sender: bob,
            recipients: [alice],
            supportsVideo: false,
            isActive: true
        )
        bobCall.signalingIdentityProps = bobProps
        bobCall.frameIdentityProps = bobProps
        bobCall.metadata = try BinaryEncoder().encode(
            SessionDescription(fromRTC: WebRTC.RTCSessionDescription(type: .offer, sdp: "v=0\r\ns=bob\r\nt=0 0\r\n")))
        #expect(bobCall.id != localCall.id)

        let sfuRatchet = MessageRatchet(executor: RatchetExecutor(queue: DispatchQueue(label: "tests.sfu.relayed-handshake")))
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
        let relayed = try await sfuRatchet.encrypt(
            plainText: try BinaryEncoder().encode(bobCall),
            sessionId: serverClientIdentity.sessionIdentity.id
        )
        try await session.handleSfuEncryptedPacket(RatchetMessagePacket(
            sfuIdentity: channelWireId,
            header: relayed.header,
            ratchetMessage: relayed,
            flag: .handshakeComplete
        ))
        let merged = await waitUntil { await group.currentCall.signalingIdentityProps?.longTermPublicKey == bobKey }
        #expect(merged, "relayed handshakeComplete was not merged")

        let groupCallAfter = await group.currentCall
        #expect(groupCallAfter.id == localCall.id, "group call id was replaced by bob's")
        #expect(groupCallAfter.sender == localCall.sender)
        #expect(groupCallAfter.recipients == localCall.recipients)
        #expect(groupCallAfter.metadata == localCall.metadata, "bob's SDP replaced the local group call metadata")
        #expect(groupCallAfter.frameIdentityProps?.longTermPublicKey == bobKey)
        let connectionCall = try #require(await session.connectionManager.findConnection(with: sharedCommunicationId)?.call)
        #expect(connectionCall.id == localCall.id, "connection call id was replaced by bob's")
        #expect(connectionCall.signalingIdentityProps?.longTermPublicKey == bobKey)

        // Host hangup: leave with the local call must tear the room down.
        try await session.leave(sfuRecipientId: channelWireId, call: localCall)
        #expect(await session.groupCallForRoom(channelWireId) == nil, "leave skipped teardown")
        #expect(await session.connectionManager.findConnection(with: sharedCommunicationId) == nil,
                "leave left the peer connection open")

        await session.shutdown(with: nil)
        try? await sfuRatchet.flushAndClose()
    }
}
#endif
