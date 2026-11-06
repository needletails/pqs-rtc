import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// The SFU renegotiation answer's outbound-send wait token belongs to the `TaskProcessor` that
/// issued it (see `HangupDuringSfuOfferEncryptTests`). Hangup retires that processor while the
/// answer can still be in the encrypt drain. The answer wait must not move to the next
/// processor, which never resolves the token, and the room's renegotiation in-flight mark must
/// not outlive the call: it defers every later SFU offer in the same room.
@Suite(.serialized)
struct HangupDuringSfuRenegotiationAnswerTests {
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

    /// Holds the encrypt loop once on the first popped `.answer` write.
    actor AnswerGate {
        private var used = false
        private(set) var isHolding = false
        private var release: CheckedContinuation<Void, Never>?

        func hold(_ job: Job) async {
            guard !used, case .writeMessage(let write) = job.task, write.flag == .answer else { return }
            used = true
            isHolding = true
            await withCheckedContinuation { release = $0 }
            isHolding = false
        }

        func open() {
            release?.resume()
            release = nil
        }
    }

    struct Room {
        let session: RTCSession
        let call: Call
        let connectionId: String
        let processor: TaskProcessor
        let gate: AnswerGate
        let handling: Task<Void, Error>
    }

    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return peerConnection
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

    /// A group room whose inbound SFU renegotiation offer was answered and whose answer is held
    /// in the encrypt drain, inside `completeSfuRenegotiationOfferHandling`'s `feedTask`.
    private func roomWithAnswerInEncryptDrain() async throws -> Room {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: Transport())
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let sfu = try Call.Participant(secretName: "sfu", nickname: "SFU", deviceId: "sfu-device")
        let connectionId = "conf-\(UUID().uuidString.lowercased())"
        let call = try Call(sharedCommunicationId: connectionId, sender: alice, recipients: [sfu], supportsVideo: false)
        await session.setSessionParticipant(alice)
        await session.testing_configureGroupSessionForTests(activeConnectionId: connectionId)

        let local = try makePeerConnection()
        _ = try await session.keyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let identity = try await session.pcKeyManager.generateSenderIdentity(connectionId: connectionId, secretName: "alice")
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        await session.connectionManager.addConnection(RTCConnection(
            id: connectionId,
            peerConnection: local,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[HangupDuringSfuRenegotiationAnswerTests]"),
                continuation: continuation
            ),
            sender: "alice",
            recipient: "sfu",
            localKeys: identity.localKeys,
            symmetricKey: identity.symmetricKey,
            sessionIdentity: identity.sessionIdentity,
            call: call
        ))

        // The SFU offers a relay m-line (a member joined).
        let sfuPeer = try makePeerConnection()
        _ = sfuPeer.addTransceiver(of: .audio)
        let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await sfuPeer.offer(for: noConstraints)
        try await sfuPeer.setLocalDescription(offer)
        let sfuOffer = try SessionDescription(fromRTC: offer)

        let processor = await session.taskProcessor
        let gate = AnswerGate()
        await processor.setWillProcessJobForTesting({ job in await gate.hold(job) })

        let handling = Task {
            try await session.completeSfuRenegotiationOfferHandling(sdp: sfuOffer, call: call)
        }
        let held = await waitUntil(timeoutSeconds: 10.0) { await gate.isHolding }
        try #require(held)
        #expect(await session.isSfuGroupRenegotiationInFlight(for: connectionId))

        return Room(
            session: session,
            call: call,
            connectionId: connectionId,
            processor: processor,
            gate: gate,
            handling: handling)
    }

    @Test
    func processorRetiredWhileAnswerIsInEncryptDrain_answerWaitReturns() async throws {
        let room = try await roomWithAnswerInEncryptDrain()
        let session = room.session

        // What hangup does to the answer: finishEndConnection drops the room's queued jobs and
        // retireCryptoStackGeneration retires the processor. The rest of hangup is left out so
        // the room's in-flight mark shows whether the answer wait came back.
        await room.processor.removeJobs(forConnectionId: room.connectionId)
        await session.retireCryptoStackGeneration()
        #expect(await session.taskProcessor !== room.processor, "Hangup should retire the answer's TaskProcessor")
        await room.gate.open()
        try await room.handling.value

        let released = await waitUntil(timeoutSeconds: 5.0) {
            await !session.isSfuGroupRenegotiationInFlight(for: room.connectionId)
        }
        #expect(released, "the renegotiation answer waits on the next TaskProcessor, which never resolves its token")

        await room.processor.setWillProcessJobForTesting(nil)
        await session.shutdown(with: nil)
    }

    @Test
    func hangupWhileAnswerIsInEncryptDrain_clearsRoomRenegotiationMark() async throws {
        let room = try await roomWithAnswerInEncryptDrain()
        let session = room.session

        await session.shutdown(with: room.call)
        #expect(
            await !session.isSfuGroupRenegotiationInFlight(for: room.connectionId),
            "the ended call's renegotiation mark defers every later SFU offer in this room"
        )

        await room.gate.open()
        _ = try? await room.handling.value
        await room.processor.setWillProcessJobForTesting(nil)
        await session.shutdown(with: nil)
    }
}
#endif
