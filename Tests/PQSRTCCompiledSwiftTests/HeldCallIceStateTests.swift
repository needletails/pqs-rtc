import Foundation
import Testing
import NeedleTailLogger
#if canImport(WebRTC) && !os(Android)
import WebRTC
#endif

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
/// ICE state changes on a call the host has put on hold (`.held`, set by the host app through
/// `callState.transition(to: .held(...))`) must be handled like the same changes on a connected call.
@Suite(.serialized)
struct HeldCallIceStateTests {
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

    private static func isHeld(_ state: CallStateMachine.State?) -> Bool {
        if case .held = state { return true }
        return false
    }

    private static func isFailed(_ state: CallStateMachine.State?) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// An inbound 1:1 call that reached `.connected` and was then held by the host, with a real
    /// peer connection registered and the peer-notifications consumer running.
    private func makeHeldCall(
        gracePeriodMs: UInt64
    ) async throws -> (session: RTCSession, call: Call, connectionId: String) {
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            iceDisconnectGracePeriodMs: gracePeriodMs,
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
        await session.callState.transition(to: .held(.inbound(.voice), call))
        await session.handleNotificationsStream()
        return (session, call, connectionId)
    }

    /// Yields `notification`, then a generated ICE candidate. The consumer handles notifications in
    /// order, so once the candidate is queued the first notification has been fully handled.
    private func deliver(
        _ notification: PeerConnectionNotifications,
        to session: RTCSession,
        connectionId: String
    ) async {
        let continuation = await session.peerConnectionNotificationsContinuation
        continuation.yield(notification)
        continuation.yield(
            .generatedIceCandidate(connectionId, "candidate:1 1 UDP 2122260223 192.0.2.1 50000 typ host", 0, "0")
        )
        let key = connectionId.normalizedConnectionId
        _ = await waitUntil(timeoutSeconds: 2) {
            if await session.iceDequeByConnectionId[key]?.count == 1 { return true }
            return Self.isFailed(await session.callState.currentState)
        }
    }

    @Test("an ICE disconnect while held arms the grace timer instead of failing the call")
    func iceDisconnectWhileHeldArmsGraceTimer() async throws {
        let (session, _, connectionId) = try await makeHeldCall(gracePeriodMs: 60_000)

        await deliver(
            .standardizedIceConnectionState(connectionId, SPTIceConnectionState(state: .disconnected)),
            to: session,
            connectionId: connectionId
        )

        let state = await session.callState.currentState
        #expect(Self.isHeld(state), "Expected the held call to survive an ICE disconnect, got \(state?.description ?? "nil")")
        #expect(await session.disconnectGraceTask != nil, "Expected the disconnect grace timer to be armed")

        await session.shutdown(with: nil)
    }

    @Test("the disconnect grace timer fails a held call when it expires")
    func disconnectGraceExpiryFailsHeldCall() async throws {
        let (session, call, connectionId) = try await makeHeldCall(gracePeriodMs: 100)
        // The app-layer stream buffers every transition, so the short-lived `.failed` (teardown
        // resets the state right after it) cannot be missed.
        let stream = try #require(await session.appStateStream())

        await session.armDisconnectGraceTimer(call: call, connectionId: connectionId)

        let observer = Task { () -> Bool in
            for await state in stream where Self.isFailed(state) { return true }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            observer.cancel()
        }
        let failed = await observer.value
        timeout.cancel()
        let state = await session.callState.currentState
        #expect(failed, "Expected grace expiry to fail the held call, got \(state?.description ?? "nil")")

        await session.shutdown(with: nil)
    }

    @Test("an ICE reconnect while held keeps the host's held state")
    func iceReconnectWhileHeldKeepsHeldState() async throws {
        let (session, _, connectionId) = try await makeHeldCall(gracePeriodMs: 60_000)

        await deliver(
            .iceConnectionStateDidChange(connectionId, SPTIceConnectionState(state: .connected)),
            to: session,
            connectionId: connectionId
        )

        let state = await session.callState.currentState
        #expect(Self.isHeld(state), "Expected an ICE reconnect to keep the call held, got \(state?.description ?? "nil")")

        await session.shutdown(with: nil)
    }
}
#endif
