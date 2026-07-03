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

@Test("PacketFlag screenSharePreempt binary round-trips")
func packetFlagScreenSharePreemptBinaryRoundTrips() throws {
    let encoded = try BinaryEncoder().encode(PacketFlag.screenSharePreempt)
    let decoded = try BinaryDecoder().decode(PacketFlag.self, from: encoded)

    switch decoded {
    case .screenSharePreempt:
        break
    default:
        Issue.record("Expected screenSharePreempt, got \(decoded)")
    }
}

@Test("ScreenSharePreemptCommand binary round-trips")
func screenSharePreemptCommandBinaryRoundTrips() throws {
    let command = ScreenSharePreemptCommand(targetParticipantSecretName: "alice")
    let encoded = try BinaryEncoder().encode(command)
    let decoded = try BinaryDecoder().decode(ScreenSharePreemptCommand.self, from: encoded)
    #expect(decoded == command)
}
