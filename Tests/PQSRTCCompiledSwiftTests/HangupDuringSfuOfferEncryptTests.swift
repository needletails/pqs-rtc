import Foundation
import Testing
import DoubleRatchetKit
#if canImport(WebRTC) && !os(Android)

@testable import PQSRTC

/// An outbound-send wait token belongs to the `TaskProcessor` that issued it. Hangup retires
/// that processor and the next `taskProcessor` access builds a new one, which has never heard
/// of the token. A hangup while the SFU offer is still in the encrypt drain must not leave
/// `sendGroupCallOffer` waiting on the new processor forever.
@Suite(.serialized)
struct HangupDuringSfuOfferEncryptTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [Call] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws { negotiated.append(call) }
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
    }

    /// Holds the encrypt loop once on the first popped `.offer` write.
    actor OfferGate {
        private var used = false
        private(set) var isHolding = false
        private var release: CheckedContinuation<Void, Never>?

        func hold(_ job: Job) async {
            guard !used, case .writeMessage(let write) = job.task, write.flag == .offer else { return }
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

    actor Outcome {
        private(set) var finished = false

        func finish() { finished = true }
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

    @Test
    func hangupWhileOfferIsInEncryptDrain_sendGroupCallOfferReturns() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.negotiated.isEmpty == false }
        try #require(negotiated)
        var call = try #require(await transport.negotiated.last)

        // SFU registration reply.
        let sfuKeyStore = KeyManager()
        let sfuIdentity = try await sfuKeyStore.generateSenderIdentity(connectionId: sfuRecipientId, secretName: sfuRecipientId)
        call.signalingIdentityProps = try #require(await sfuIdentity.sessionIdentity.props(symmetricKey: sfuIdentity.symmetricKey))
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)

        let processor = await session.taskProcessor
        let gate = OfferGate()
        await processor.setWillProcessJobForTesting({ job in await gate.hold(job) })

        // Media bootstrap creates the PeerConnection and sends the initial offer through
        // `sendGroupCallOffer`, which starts the encrypt drain and stays inside `feedTask`.
        let outcome = Outcome()
        let registrationReply = call
        let bootstrap = Task {
            _ = try? await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(
                sfuRecipientId: sfuRecipientId,
                updatedCall: registrationReply)
            await outcome.finish()
        }
        let held = await waitUntil(timeoutSeconds: 10.0) { await gate.isHolding }
        try #require(held)

        // The user hangs up while the offer is still in the encrypt drain.
        let group = try #require(await session.groupCallForRoom(sfuRecipientId))
        try await session.leave(sfuRecipientId: sfuRecipientId, call: await group.currentCall)
        #expect(await session.taskProcessor !== processor, "Hangup should retire the offer's TaskProcessor")
        await gate.open()

        let finished = await waitUntil(timeoutSeconds: 5.0) { await outcome.finished }
        #expect(finished, "sendGroupCallOffer still waits for its offer send after hangup retired the TaskProcessor")

        await processor.setWillProcessJobForTesting(nil)
        bootstrap.cancel()
        await session.shutdown(with: nil)
    }
}
#endif
