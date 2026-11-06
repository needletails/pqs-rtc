import Foundation
import Testing
import NeedleTailLogger
#if canImport(WebRTC) && !os(Android)
import WebRTC
#endif

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
/// Two `handleNotificationsStream()` calls in one actor-isolated step, before the first
/// consumer task has reached the actor (createPeerConnection followed by createOffer,
/// createAnswer or setRemote can do this). Returns the task after each call.
private func ensureNotificationsConsumerTwice(
    _ session: isolated RTCSession
) -> (first: Task<Void, Error>?, latest: Task<Void, Error>?) {
    session.handleNotificationsStream()
    let first = session.notificationsTask
    session.handleNotificationsStream()
    return (first, session.notificationsTask)
}

@Suite(.serialized)
struct NotificationsConsumerRestartTests {
    actor Transport: RTCTransportEvents {
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

    @Test("a second ensure before the consumer starts keeps the shared notifications stream delivering")
    func secondEnsureBeforeConsumerStartsKeepsStreamDelivering() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: Transport())
        let connectionId = UUID().uuidString
        let sender = try Call.Participant(secretName: "sender", nickname: "Sender", deviceId: "s-device")
        let recipient = try Call.Participant(secretName: "recipient", nickname: "Recipient", deviceId: "r-device")
        let call = try Call(sharedCommunicationId: connectionId, sender: sender, recipients: [recipient])

        let localIdentity = try await KeyManager().generateSenderIdentity(connectionId: connectionId, secretName: "sender")
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let peerConnection = try #require(RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil))
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: connectionId,
            logger: NeedleTailLogger("[test]"),
            continuation: await session.peerConnectionNotificationsContinuation
        )
        await session.connectionManager.addConnection(RTCConnection(
            id: connectionId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "sender",
            recipient: "recipient",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        ))

        let tasks = await ensureNotificationsConsumerTwice(session)
        // A consumer the second call replaced must have run to its exit before we probe.
        if let first = tasks.first, first != tasks.latest {
            _ = await first.result
        }

        let yieldResult = await session.peerConnectionNotificationsContinuation.yield(
            .generatedIceCandidate(connectionId, "candidate:1 1 UDP 2122260223 192.0.2.1 50000 typ host", 0, "0")
        )
        if case .terminated = yieldResult {
            Issue.record("Peer-notifications stream was finished by the consumer restart")
        }

        let key = connectionId.normalizedConnectionId
        let candidateQueued = await waitUntil(timeoutSeconds: 2) {
            await session.iceDequeByConnectionId[key]?.count == 1
        }
        #expect(candidateQueued, "Expected the generated ICE candidate to reach the consumer")

        await session.shutdown(with: nil)
    }
}
#endif
