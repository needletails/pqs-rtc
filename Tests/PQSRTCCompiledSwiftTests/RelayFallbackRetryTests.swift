import Foundation
import Testing
#if canImport(WebRTC)
import WebRTC
#endif

@testable import PQSRTC

@Suite(.serialized)
struct RelayFallbackRetryTests {
    actor Transport: RTCTransportEvents {
        private(set) var oneToOneFlags: [PacketFlag] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {
            oneToOneFlags.append(packet.flag)
        }
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
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

#if canImport(WebRTC) && !os(Android)
    @Test("ice_timeout relay retry run by the fallback timer is not cancelled by that timer")
    func iceTimeoutRelayRetryOffersRelayPeerConnection() async throws {
        let transport = Transport()
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "u",
            password: "p",
            iceTransportPolicyStrategy: .allThenRelay(timeoutMilliseconds: 1),
            delegate: transport
        )
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)
        let call = try Call(
            sharedCommunicationId: UUID().uuidString,
            sender: alice,
            recipients: [bob],
            supportsVideo: false,
            isActive: true
        )
        let connectionId = call.sharedCommunicationId

        // Local frame + signaling identities, and the remote peer's identities for this room.
        let frameIdentity = try await session.keyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        _ = try await session.pcKeyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let remoteKeys = KeyManager()
        let remoteFrame = try await remoteKeys.generateSenderIdentity(connectionId: connectionId, secretName: "bob")
        let remoteFrameProps = try #require(await remoteFrame.sessionIdentity.props(symmetricKey: remoteFrame.symmetricKey))
        let remoteSignaling = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: "bob")
        let remoteSignalingProps = try #require(await remoteSignaling.sessionIdentity.props(symmetricKey: remoteSignaling.symmetricKey))
        _ = try await session.keyManager.createRecipientIdentity(connectionId: connectionId, props: remoteFrameProps)
        _ = try await session.pcKeyManager.createRecipientIdentity(connectionId: connectionId, props: remoteSignalingProps)

        try await session.createStateStream(with: call)
        await session.callState.transition(to: .connecting(.outbound(.voice), call))

        // First attempt uses direct ICE.
        _ = try await session.createPeerConnection(
            with: call,
            sender: alice.secretName,
            recipient: bob.secretName,
            localIdentity: frameIdentity
        )
        #expect(await session.currentIceTransportSelection(for: connectionId) == .all)

        // Answer applied, ICE never connects: the fallback timer fires and retries with relay.
        await session.armRelayFallbackTimerIfNeeded(for: call)

        let retryFinished = await waitUntil(timeoutSeconds: 10) {
            let retried = await session.didRetryWithRelay(for: connectionId)
            let retrying = await session.relayFallbackRetryingConnectionIds.contains(connectionId.normalizedConnectionId)
            return retried && !retrying
        }
        #expect(retryFinished)

        let relayConnection = await session.connectionManager.findConnection(with: connectionId)
        #expect(relayConnection?.peerConnection.configuration.iceTransportPolicy == .relay)
        #expect(relayConnection?.peerConnection.localDescription?.type == .offer)

        let offerSent = await waitUntil(timeoutSeconds: 2) {
            await transport.oneToOneFlags.contains(.offer)
        }
        #expect(offerSent, "Expected the relay peer connection's offer to reach the transport")

        await session.shutdown(with: call)
    }
#endif
}
