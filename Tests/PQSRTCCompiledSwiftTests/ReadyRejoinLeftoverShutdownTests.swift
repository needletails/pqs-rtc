import Foundation
import Testing

@testable import PQSRTC

/// A same-room rejoin that is still `.ready` (SFU registration pending) owns the session.
/// A leftover `shutdown(with:)` for the ended attempt must not tear it down.
@Suite(.serialized)
struct ReadyRejoinLeftoverShutdownTests {
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

    @Test
    func leftoverShutdownForEndedAttemptKeepsReadyRejoin() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: Transport())
        let room = UUID().uuidString
        let sender = try Call.Participant(secretName: "sender", nickname: "Sender", deviceId: "s")
        let endedAttempt = try Call(groupSharedCommunicationId: room, sender: sender, isActive: true)
        let rejoin = try Call(groupSharedCommunicationId: room, sender: sender, isActive: true)

        // Attempt A connects, then ends normally.
        try await session.createStateStream(with: endedAttempt)
        await session.setConnectingIfReady(call: endedAttempt, callDirection: .outbound(.video))
        await session.shutdown(with: endedAttempt)

        // Attempt B for the same room is registered but still `.ready`.
        try await session.createStateStream(with: rejoin)
        #expect(await session.callState.currentState == .ready(rejoin))
        let liveGeneration = await session.cryptoStackGeneration

        // A second end trigger for attempt A arrives late.
        await session.shutdown(with: endedAttempt)

        #expect(await session.callState.currentState == .ready(rejoin))
        #expect(await session.cryptoStackGeneration == liveGeneration)
        await session.shutdown(with: rejoin)
    }
}
