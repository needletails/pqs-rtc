import Foundation
import Testing
import NeedleTailLogger
#if canImport(WebRTC) && !os(Android)
import WebRTC
#endif

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
private extension RTCSession {
    /// Arms the timer and returns its task in one actor step, so a short grace period cannot
    /// expire before the test holds the handle.
    func armDisconnectGraceTimerReturningTask(call: Call, connectionId: String) -> Task<Void, Never>? {
        armDisconnectGraceTimer(call: call, connectionId: connectionId)
        return disconnectGraceTask
    }
}

/// When the ICE disconnect grace period expires, the grace task tears the call down itself. That
/// teardown must not run cancelled: a cancelled task skips the frame-transformer drain
/// (`drainAppleSenderFrameTransformersBeforeSenderTeardown`) before the RTP senders are closed.
@Suite(.serialized)
struct DisconnectGraceTeardownTests {
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

    @Test("the disconnect grace expiry tears the call down in a task that is not cancelled")
    func graceExpiryTeardownIsNotCancelled() async throws {
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            iceDisconnectGracePeriodMs: 100,
            delegate: Transport()
        )
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
        try await session.createStateStream(with: call)
        await session.callState.transition(to: .connecting(.inbound(.voice), call))
        await session.callState.transition(to: .connected(.inbound(.voice), call))

        let graceTask = try #require(await session.armDisconnectGraceTimerReturningTask(call: call, connectionId: connectionId))
        await graceTask.value

        let tornDown = await waitUntil(timeoutSeconds: 5) {
            await session.connectionManager.findConnection(with: connectionId) == nil
        }
        #expect(tornDown, "Expected the grace expiry to tear the call down")
        #expect(!graceTask.isCancelled, "Expected the grace expiry teardown not to cancel the task it runs in")

        await session.shutdown(with: nil)
    }
}
#endif
