import Foundation
import Testing
#if canImport(WebRTC) && !os(Android)
import WebRTC
#endif

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
/// An outbound call that is already `.connected` and then loses ICE must not stay connected on a
/// dead peer connection: the disconnect grace timer bounds it when no relay retry is left, and
/// while a relay retry's re-offer goes unanswered; relay is only tried when the strategy
/// configures a relay fallback.
@Suite(.serialized)
struct OutboundLiveCallIceLossTests {
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

    private static func isConnected(_ state: CallStateMachine.State?) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private static func isFailed(_ state: CallStateMachine.State?) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// An outbound 1:1 call whose first (direct ICE) peer connection reached `.connected`, with the
    /// signaling identities a relay re-offer needs and the peer-notifications consumer running.
    private func makeConnectedOutboundCall(
        strategy: RTCIceTransportPolicyStrategy,
        gracePeriodMs: UInt64
    ) async throws -> (session: RTCSession, transport: Transport, call: Call, connectionId: String) {
        let transport = Transport()
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "u",
            password: "p",
            iceTransportPolicyStrategy: strategy,
            iceDisconnectGracePeriodMs: gracePeriodMs,
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
        await session.callState.transition(to: .connected(.outbound(.voice), call))
        await session.handleNotificationsStream()
        return (session, transport, call, connectionId)
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

    /// Waits on the app-layer stream, which buffers every transition, so the short-lived `.failed`
    /// (teardown resets the state right after it) cannot be missed.
    private func waitForFailure(_ stream: AsyncStream<CallStateMachine.State>, timeoutSeconds: Double) async -> Bool {
        let observer = Task { () -> Bool in
            for await state in stream where Self.isFailed(state) { return true }
            return false
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            observer.cancel()
        }
        let failed = await observer.value
        timeout.cancel()
        return failed
    }

    @Test("an ICE disconnect on a connected outbound call without a relay fallback arms the grace timer")
    func liveOutboundIceDisconnectArmsGraceTimer() async throws {
        let (session, _, call, connectionId) = try await makeConnectedOutboundCall(
            strategy: .all,
            gracePeriodMs: 60_000
        )

        await deliver(
            .standardizedIceConnectionState(connectionId, SPTIceConnectionState(state: .disconnected)),
            to: session,
            connectionId: connectionId
        )

        let state = await session.callState.currentState
        #expect(Self.isConnected(state), "Expected the call to survive the disconnect for now, got \(state?.description ?? "nil")")
        #expect(await session.disconnectGraceTask != nil, "Expected the disconnect grace timer to be armed")

        await session.shutdown(with: call)
    }

    /// Conference and group participants are outbound: a gradual ICE loss keeps waiting for ICE
    /// `failed` and its relay retry instead of failing on the grace timer first.
    @Test("an ICE disconnect on a connected outbound call waits for the relay retry while one is available")
    func liveOutboundIceDisconnectWaitsForRelayRetry() async throws {
        let (session, _, call, connectionId) = try await makeConnectedOutboundCall(
            strategy: .allThenRelay(timeoutMilliseconds: 60_000),
            gracePeriodMs: 60_000
        )

        await deliver(
            .standardizedIceConnectionState(connectionId, SPTIceConnectionState(state: .disconnected)),
            to: session,
            connectionId: connectionId
        )

        let state = await session.callState.currentState
        #expect(Self.isConnected(state), "Expected the call to survive the disconnect for now, got \(state?.description ?? "nil")")
        #expect(await session.disconnectGraceTask == nil, "Expected no grace timer while the relay retry is still available")

        await session.shutdown(with: call)
    }

    @Test("a mid-call relay retry whose re-offer is never answered fails the call after the grace period")
    func unansweredLiveRelayRetryFailsAfterGrace() async throws {
        let (session, transport, call, connectionId) = try await makeConnectedOutboundCall(
            strategy: .allThenRelay(timeoutMilliseconds: 60_000),
            gracePeriodMs: 300
        )
        let stream = try #require(await session.appStateStream())

        // Interface loss can take ICE from connected straight to failed.
        let continuation = await session.peerConnectionNotificationsContinuation
        continuation.yield(.standardizedIceConnectionState(connectionId, SPTIceConnectionState(state: .failed)))

        let offerSent = await waitUntil(timeoutSeconds: 10) {
            await transport.oneToOneFlags.contains(.offer)
        }
        #expect(offerSent, "Expected the relay retry to re-offer")

        let failed = await waitForFailure(stream, timeoutSeconds: 5)
        let state = await session.callState.currentState
        #expect(failed, "Expected the unanswered relay re-offer to fail the call, got \(state?.description ?? "nil")")

        await session.shutdown(with: call)
    }

    @Test("an ICE failure under the .all strategy does not retry with relay")
    func allStrategyIceFailureDoesNotRetryWithRelay() async throws {
        let (session, transport, call, connectionId) = try await makeConnectedOutboundCall(
            strategy: .all,
            gracePeriodMs: 60_000
        )
        let stream = try #require(await session.appStateStream())

        let continuation = await session.peerConnectionNotificationsContinuation
        continuation.yield(.standardizedIceConnectionState(connectionId, SPTIceConnectionState(state: .failed)))

        let failed = await waitForFailure(stream, timeoutSeconds: 5)
        let state = await session.callState.currentState
        #expect(failed, "Expected ICE failure to fail the call, got \(state?.description ?? "nil")")
        #expect(!(await transport.oneToOneFlags.contains(.offer)), "Expected no relay re-offer under the .all strategy")

        await session.shutdown(with: call)
    }
}
#endif
