import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC
#endif

    @Suite(.serialized)
struct RTCSessionStateHandlingTests {
    actor TestTransportEvents: RTCTransportEvents {
        private(set) var didEndCalls: [(call: Call, endState: CallStateMachine.EndState)] = []
        private(set) var didBeginStartCall = false
        private let suspendStartCall: Bool
        private var startCallContinuation: CheckedContinuation<Void, Never>?

        init(suspendStartCall: Bool = false) {
            self.suspendStartCall = suspendStartCall
        }

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {
            didBeginStartCall = true
            if suspendStartCall {
                await withCheckedContinuation { continuation in
                    startCallContinuation = continuation
                }
            }
        }
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}

        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {
            didEndCalls.append((call: call, endState: endState))
        }

        func releaseStartCall() {
            startCallContinuation?.resume()
            startCallContinuation = nil
        }
    }

    private func makeCall(sharedId: String) throws -> Call {
        let sender = try Call.Participant(secretName: "sender", nickname: "Sender", deviceId: "s-device")
        let recipient = try Call.Participant(secretName: "recipient", nickname: "Recipient", deviceId: "r-device")
        return try Call(sharedCommunicationId: sharedId, sender: sender, recipients: [recipient])
    }

    private func runHandleStateOnce(
        direction: CallStateMachine.CallDirection,
        error: String
    ) async throws -> CallStateMachine.EndState? {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )

        let call = try makeCall(sharedId: "c1")
        let (stream, continuation) = AsyncStream<CallStateMachine.State>.makeStream()

        let handleTask = Task {
            try await session.handleState(stateStream: stream)
        }

        continuation.yield(.failed(direction, call, error))
        continuation.finish()

        _ = try await handleTask.value

        let endState = await events.didEndCalls.last?.endState
        await session.shutdown(with: nil)
        return endState
    }

    @Test
    func peerConnectionFailedInboundMapsToPartnerInitiatedUnanswered() async throws {
        let endState = try await runHandleStateOnce(
            direction: .inbound(.video),
            error: "PeerConnection Failed"
        )
        #expect(endState == .partnerInitiatedUnanswered)
    }

    @Test
    func peerConnectionFailedOutboundMapsToUserInitiatedUnanswered() async throws {
        let endState = try await runHandleStateOnce(
            direction: .outbound(.voice),
            error: "PeerConnection Failed"
        )
        #expect(endState == .userInitiatedUnanswered)
    }

    @Test
    func otherFailureMapsToFailed() async throws {
        let endState = try await runHandleStateOnce(
            direction: .inbound(.voice),
            error: "Some Other Failure"
        )
        #expect(endState == .failed)
    }

    // MARK: - appStateStream accessor

    @Test("appStateStream returns nil before createStateStream")
    func appStateStreamNilBeforeCreate() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let stream = await session.appStateStream()
        #expect(stream == nil)
    }

    @Test("appStateStream returns stream after createStateStream")
    func appStateStreamExistsAfterCreate() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(sharedId: "c1")
        try await session.createStateStream(with: call)

        let stream = await session.appStateStream()
        #expect(stream != nil)
    }

    @Test("outbound start enters connecting before invite delivery completes")
    func outboundStartConnectsBeforeInviteDeliveryCompletes() async throws {
        let events = TestTransportEvents(suspendStartCall: true)
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(sharedId: "slow-outbound-start")
        try await session.createStateStream(with: call)

        let startTask = Task {
            try await session.startCall(call)
        }
        for _ in 0..<100 {
            if await events.didBeginStartCall {
                break
            }
            await Task.yield()
        }

        let didBeginStartCall = await events.didBeginStartCall
        let state = await session.callState.currentState
        #expect(didBeginStartCall)
        if case .connecting(.outbound(.voice), _) = state {
            #expect(true)
        } else {
            Issue.record("Expected outbound call to be connecting while start_call transport is suspended")
        }

        await events.releaseStartCall()
        _ = try await startTask.value
    }

    // MARK: - ICE disconnect grace period

    @Test("armDisconnectGraceTimer does not fail the call immediately")
    func disconnectGraceTimerDoesNotImmediatelyFail() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            iceDisconnectGracePeriodMs: 500,
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(sharedId: "grace-1")
        try await session.createStateStream(with: call)
        await session.callState.transition(to: .connecting(.outbound(.voice), call))
        await session.callState.transition(to: .connected(.outbound(.voice), call))

        await session.armDisconnectGraceTimer(call: call, connectionId: call.sharedCommunicationId)

        let state = await session.callState.currentState
        #expect(state?.description.contains("Connected") == true)
        let endCalls = await events.didEndCalls
        #expect(endCalls.isEmpty)
    }

    @Test("disconnectGraceTimer fires after grace period expires")
    func disconnectGraceTimerFiresAfterExpiry() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            iceDisconnectGracePeriodMs: 100,
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(sharedId: "grace-2")
        try await session.createStateStream(with: call)
        guard let stream = await session.appStateStream() else {
            Issue.record("Expected app state stream after createStateStream")
            return
        }
        let observedFailure = BoolBox()
        let observeTask = Task {
            for await state in stream {
                if state.description.contains("Failed") {
                    await observedFailure.setTrue()
                    break
                }
            }
        }
        await session.callState.transition(to: .connecting(.outbound(.voice), call))
        await session.callState.transition(to: .connected(.outbound(.voice), call))

        await session.armDisconnectGraceTimer(call: call, connectionId: call.sharedCommunicationId)

        try await Task.sleep(nanoseconds: 250_000_000)
        observeTask.cancel()

        #expect(await observedFailure.value)
    }

    @Test("cancelDisconnectGraceTask prevents the timer from firing")
    func cancelDisconnectGraceTaskPreventsFailure() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            iceDisconnectGracePeriodMs: 100,
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(sharedId: "grace-3")
        try await session.createStateStream(with: call)
        await session.callState.transition(to: .connecting(.outbound(.voice), call))
        await session.callState.transition(to: .connected(.outbound(.voice), call))

        await session.armDisconnectGraceTimer(call: call, connectionId: call.sharedCommunicationId)
        await session.cancelDisconnectGraceTask()

        try await Task.sleep(nanoseconds: 250_000_000)

        let state = await session.callState.currentState
        #expect(state?.description.contains("Connected") == true)
        let endCalls = await events.didEndCalls
        #expect(endCalls.isEmpty)
    }

    // MARK: - Per-connection candidate scoping

    @Test("per-connection candidate dictionaries are independent")
    func perConnectionCandidateDictionariesAreIndependent() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let readyA = await session.readyForCandidatesByConnectionId["conn-a"]
        let readyB = await session.readyForCandidatesByConnectionId["conn-b"]
        #expect(readyA == nil)
        #expect(readyB == nil)

        let dequeA = await session.iceDequeByConnectionId["conn-a"]
        let dequeB = await session.iceDequeByConnectionId["conn-b"]
        #expect(dequeA == nil)
        #expect(dequeB == nil)
    }

#if canImport(WebRTC) && !os(Android)
    private enum PrePcStateStreamTestError: Error {
        case peerConnectionCreationFailed
    }

    private func makePeerConnectionForStateOrderingTest() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw PrePcStateStreamTestError.peerConnectionCreationFailed
        }
        return pc
    }

    /// When a peer connection is registered before `createStateStream`, `setConnectingIfReady` must
    /// not be lost (otherwise the UI can remain on `.ready` / "Ready" indefinitely).
    @Test("createStateStream after existing connection advances to connecting from ready")
    func createStateStreamWithPreexistingConnectionReachesConnecting() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )
        defer { Task { await session.shutdown(with: nil) } }

        let sharedId = "pre-pc-then-state"
        let call = try makeCall(sharedId: sharedId)

        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(
            connectionId: sharedId,
            secretName: "sender"
        )
        let (notifStream, notifCont) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = notifStream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: sharedId,
            logger: NeedleTailLogger("[test]"),
            continuation: notifCont
        )
        let connection = RTCConnection(
            id: sharedId,
            peerConnection: try makePeerConnectionForStateOrderingTest(),
            delegateWrapper: delegateWrapper,
            sender: "sender",
            recipient: "recipient",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
        await session.connectionManager.addConnection(connection)

        try await session.createStateStream(with: call)

        let state = await session.callState.currentState
        var isConnecting = false
        if case .connecting = state {
            isConnecting = true
        }
        #expect(isConnecting)
    }
#endif
}

private actor BoolBox {
    private(set) var value = false

    func setTrue() {
        value = true
    }
}
