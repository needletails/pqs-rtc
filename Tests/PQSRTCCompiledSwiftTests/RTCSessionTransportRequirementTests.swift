import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct RTCSessionTransportRequirementTests {
    actor TestTransportEvents: RTCTransportEvents {
        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
    }

    @Test
    func requireTransportThrowsWhenDelegateNotSet() async {
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: nil
        )

        do {
            _ = try await session.requireTransport()
            Issue.record("Expected requireTransport() to throw")
        } catch let RTCErrors.invalidConfiguration(message) {
            #expect(message == "RTCTransportEvents delegate not set")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await session.shutdown(with: nil)
    }

    @Test
    func requireTransportReturnsDelegateWhenSet() async {
        let events = TestTransportEvents()
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: events
        )

        do {
            let transport = try await session.requireTransport()
            #expect(transport is TestTransportEvents)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await session.shutdown(with: nil)
    }
}
