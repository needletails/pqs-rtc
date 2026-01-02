import Foundation
import Testing

@testable import PQSRTC

@Suite
struct RTCSessionTransportRequirementTests {
    actor TestTransportEvents: RTCTransportEvents {
        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendOffer(call: Call) async throws {}
        func sendAnswer(call: Call, metadata: PQSRTC.SDPNegotiationMetadata) async throws {}
        func sendCandidate(_ candidate: IceCandidate, call: Call) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
    }

    @Test
    func requireTransportThrowsWhenDelegateNotSet() async {
        let session = RTCSession(
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
        let session = RTCSession(
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
