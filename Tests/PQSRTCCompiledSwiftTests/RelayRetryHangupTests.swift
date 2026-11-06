import Foundation
import NeedleTailAsyncSequence
import Testing
#if canImport(WebRTC)
import WebRTC
#endif

@testable import PQSRTC

/// A suspended dispatch queue backing an actor's executor: every hop onto that actor
/// waits until `open()`, without blocking a thread.
private final class HeldQueue: @unchecked Sendable {
    let queue = DispatchQueue(label: "relay-retry-hangup-held-queue")
    private let lock = NSLock()
    private var held = true

    init() { queue.suspend() }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard held else { return }
        held = false
        queue.resume()
    }
}

@Suite(.serialized)
struct RelayRetryHangupTests {
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

    private func installCandidateConsumer(
        _ consumer: NeedleTailAsyncConsumer<IceCandidate>,
        for connectionId: String,
        on session: isolated RTCSession
    ) {
        session.inboundCandidateConsumers[connectionId.normalizedConnectionId] = consumer
    }

#if canImport(WebRTC) && !os(Android)
    @Test("a hangup while a relay retry is suspended leaves no peer connection and sends no offer")
    func hangupDuringRelayRetryLeavesNoPeerConnection() async throws {
        let transport = Transport()
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "u",
            password: "p",
            iceTransportPolicyStrategy: .allThenRelay(timeoutMilliseconds: 60_000),
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

        let frameIdentity = try await session.keyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        _ = try await session.pcKeyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let remoteFrame = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: "bob")
        let remoteFrameProps = try #require(await remoteFrame.sessionIdentity.props(symmetricKey: remoteFrame.symmetricKey))
        let remoteSignaling = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: "bob")
        let remoteSignalingProps = try #require(await remoteSignaling.sessionIdentity.props(symmetricKey: remoteSignaling.symmetricKey))
        _ = try await session.keyManager.createRecipientIdentity(connectionId: connectionId, props: remoteFrameProps)
        _ = try await session.pcKeyManager.createRecipientIdentity(connectionId: connectionId, props: remoteSignalingProps)

        try await session.createStateStream(with: call)
        await session.callState.transition(to: .connecting(.outbound(.voice), call))
        _ = try await session.createPeerConnection(
            with: call,
            sender: alice.secretName,
            recipient: bob.secretName,
            localIdentity: frameIdentity
        )

        // The retry's teardown of the direct attempt hops onto this consumer; hold it there.
        let held = HeldQueue()
        defer { held.open() }
        await installCandidateConsumer(
            NeedleTailAsyncConsumer<IceCandidate>(executor: NTAExecutor(queue: held.queue)),
            for: connectionId,
            on: session
        )

        let retry = Task { await session.retryWithRelayIfNeeded(call: call, reason: "ice_failed") }
        while await session.inboundCandidateConsumers[connectionId.normalizedConnectionId] != nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        // The user hangs up while the retry is suspended.
        try await session.endCall(call)
        #expect(await session.connectionManager.findAllConnections().isEmpty)

        held.open()
        let retried = await retry.value

        let leftover = await session.connectionManager.findAllConnections()
        #expect(!retried)
        #expect(leftover.isEmpty, "relay retry left \(leftover.count) peer connection(s) after hangup")
        #expect(leftover.allSatisfy { $0.peerConnection.signalingState == .closed },
                "relay retry left an open peer connection after hangup")
        #expect(await transport.oneToOneFlags.contains(.offer) == false, "relay retry sent an offer after hangup")
        #expect(await session.connectionFallbackStateByConnectionId[connectionId.normalizedConnectionId] == nil)

        await session.shutdown(with: call)
    }
#endif
}
