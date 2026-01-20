import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct RTCSessionStateHandlingTests {
    actor TestTransportEvents: RTCTransportEvents {
        private(set) var didEndCalls: [(call: Call, endState: CallStateMachine.EndState)] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}

        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {
            didEndCalls.append((call: call, endState: endState))
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
}
