import Foundation
import Testing

@testable import PQSRTC

@Suite
struct PeerConnectionNotificationsTests {
    @Test
    func payloadsRoundTripThroughEnumCases() {
        let data = Data([0x01, 0x02, 0x03])
        let event = PeerConnectionNotifications.dataChannelMessage("conn", "label", data)

        switch event {
        case .dataChannelMessage(let connectionId, let channelLabel, let payload):
            #expect(connectionId == "conn")
            #expect(channelLabel == "label")
            #expect(payload == data)
        default:
            Issue.record("Expected .dataChannelMessage")
        }
    }

    @Test
    func simpleCasesCarryExpectedValues() {
        let event = PeerConnectionNotifications.removedIceCandidates("conn", 7)
        switch event {
        case .removedIceCandidates(let connectionId, let count):
            #expect(connectionId == "conn")
            #expect(count == 7)
        default:
            Issue.record("Expected .removedIceCandidates")
        }
    }
}
