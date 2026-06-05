import BinaryCodable
import Foundation
import Testing

@testable import PQSRTC

@Test("PacketFlag mediaReady binary round-trips")
func packetFlagMediaReadyBinaryRoundTrips() throws {
    let encoded = try BinaryEncoder().encode(PacketFlag.mediaReady)
    let decoded = try BinaryDecoder().decode(PacketFlag.self, from: encoded)

    switch decoded {
    case .mediaReady:
        break
    default:
        Issue.record("Expected mediaReady, got \(decoded)")
    }
}
