import Foundation
import Testing

@testable import PQSRTC

/// A call that reached `.connected` and then loses its PeerConnection was answered.
/// The host must get `.failed`, not an unanswered end state (which the peer records as missed).
@Suite(.serialized)
struct ConnectedCallFailureEndStateTests {
    actor Transport: RTCTransportEvents {
        private(set) var endStates: [CallStateMachine.EndState] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {
            endStates.append(endState)
        }
    }

    @Test(arguments: [
        CallStateMachine.CallDirection.inbound(.voice),
        CallStateMachine.CallDirection.outbound(.video),
    ])
    func connectedCallThatFailsEndsAsFailedNotUnanswered(direction: CallStateMachine.CallDirection) async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: transport)
        let sender = try Call.Participant(secretName: "sender", nickname: "Sender", deviceId: "s-device")
        let recipient = try Call.Participant(secretName: "recipient", nickname: "Recipient", deviceId: "r-device")
        let call = try Call(sharedCommunicationId: UUID().uuidString, sender: sender, recipients: [recipient])

        // The same order the session's state stream delivers for a call whose ICE fails mid-call.
        let (stream, continuation) = AsyncStream<CallStateMachine.State>.makeStream()
        let handler = Task { try await session.handleState(stateStream: stream) }
        continuation.yield(.ready(call))
        continuation.yield(.connecting(direction, call))
        continuation.yield(.connected(direction, call))
        continuation.yield(.failed(direction, call, "PeerConnection Failed"))
        continuation.finish()
        try await handler.value

        let endStates = await transport.endStates
        #expect(endStates == [.failed])
        await session.shutdown(with: nil)
    }
}
