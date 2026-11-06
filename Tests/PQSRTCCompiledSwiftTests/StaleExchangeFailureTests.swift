import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// An offer/answer/remote-description attempt for a call that was hung up can fail late, after a
/// redial made a new call live (createOffer waits up to 30 s for its connection, createAnswer
/// ~10 s for its remote description). That late failure must not fail or tear down the new call.
@Suite(.serialized)
struct StaleExchangeFailureTests {
    actor TestTransportEvents: RTCTransportEvents {
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

    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private let events = TestTransportEvents()

    private func makeSession() async -> RTCSession {
        await RTCSession(iceServers: [], username: "u", password: "p", delegate: events)
    }

    private func makeCall() throws -> Call {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        return try Call(sharedCommunicationId: UUID().uuidString, sender: sender, recipients: [recipient])
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
            logger: NeedleTailLogger("[StaleExchangeFailureTests]"),
            continuation: continuation
        )
        return RTCConnection(
            id: call.sharedCommunicationId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "alice",
            recipient: "bob",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
    }

    /// Dials `call` the way the host app does: state stream, then `startCall`.
    private func dial(_ call: Call, on session: RTCSession) async throws {
        try await session.setupCallState(call)
        try await session.startCall(call)
    }

    private func liveState(_ call: Call) -> CallStateMachine.State {
        .connecting(.outbound(.voice), call)
    }

    private func waitUntil(
        timeoutSeconds: Double = 2.0,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    @Test("stale setRemote failure after hangup and redial leaves the redialed call live")
    func staleSetRemoteFailureLeavesRedialedCallLive() async throws {
        let session = await makeSession()
        let callA = try makeCall()
        try await dial(callA, on: session)
        try await session.endCall(callA)

        let callB = try makeCall()
        try await dial(callB, on: session)
        #expect(await session.callState.currentState == liveState(callB))

        await #expect(throws: (any Error).self) {
            try await session.setRemote(sdp: WebRTC.RTCSessionDescription(type: .answer, sdp: "v=0\r\n"), call: callA)
        }
        #expect(await session.callState.currentState == liveState(callB),
                "stale setRemote for call A failed the live call B")
        #expect(await !session.isConnectionFinishingOrEnded(callB.sharedCommunicationId))

        // A failure of the live call itself still fails and tears it down.
        await #expect(throws: (any Error).self) {
            try await session.setRemote(sdp: WebRTC.RTCSessionDescription(type: .answer, sdp: "v=0\r\n"), call: callB)
        }
        #expect(await session.isConnectionFinishingOrEnded(callB.sharedCommunicationId),
                "setRemote failure for the live call B did not end it")
        // The `.failed` transition's state-stream teardown resets the state asynchronously.
        #expect(await waitUntil { await session.callState.currentState == nil },
                "call state was not reset after the live call B failed")

        await session.shutdown(with: nil)
    }

    @Test("stale createOffer failure on the hung-up call's closed peer connection leaves the redialed call live")
    func staleCreateOfferFailureLeavesRedialedCallLive() async throws {
        let session = await makeSession()
        let callA = try makeCall()
        try await dial(callA, on: session)
        let connectionA = try await makeConnection(call: callA)
        await session.connectionManager.addConnection(connectionA)
        try await session.endCall(callA)

        let callB = try makeCall()
        try await dial(callB, on: session)
        #expect(await session.callState.currentState == liveState(callB))

        // The stale offer attempt resolved call A's connection before the hangup closed it.
        await session.connectionManager.addConnection(connectionA)
        await #expect(throws: (any Error).self) {
            _ = try await session.createOffer(call: callA)
        }
        #expect(await session.callState.currentState == liveState(callB),
                "stale createOffer for call A failed the live call B")

        await session.shutdown(with: nil)
    }

    @Test("stale createAnswer timeout after hangup and redial leaves the redialed call live")
    func staleCreateAnswerTimeoutLeavesRedialedCallLive() async throws {
        let session = await makeSession()
        let callA = try makeCall()
        try await dial(callA, on: session)

        // Call A's remote description never lands, so its answer can only time out (~10 s).
        let staleAnswer = Task { try await session.createAnswer(call: callA) }
        try await session.endCall(callA)

        let callB = try makeCall()
        try await dial(callB, on: session)
        #expect(await session.callState.currentState == liveState(callB))

        await #expect(throws: (any Error).self) {
            _ = try await staleAnswer.value
        }
        #expect(await session.callState.currentState == liveState(callB),
                "stale createAnswer for call A failed the live call B")

        await session.shutdown(with: nil)
    }

    /// The Android `setRemote` does not compile on macOS, so its catches are pinned by source:
    /// no exchange path in the file fails or ends a call except through the liveness-checked helper.
    @Test("exchange failure paths fail a call only through the liveness-checked helper")
    func exchangeFailurePathsRouteThroughLivenessCheck() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+Exchange.swift"),
            encoding: .utf8
        )
        let helper = try SourceContract.sourceBody(of: "failCallAfterExchangeError", in: source)
        #expect(helper.contains("isSupersededCall(call)"))
        #expect(source.components(separatedBy: "callState.transition(to: .failed").count - 1 == 1)
        #expect(source.components(separatedBy: "finishEndConnection(").count - 1 == 1)
    }
}
#endif
