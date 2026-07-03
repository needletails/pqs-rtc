import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct ReplayKitBroadcastRelayPacketTests {

    @Test("ReplayKit video packet round-trips")
    func videoPacketRoundTrip() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let packet = ReplayKitBroadcastRelayPacket(
            type: .videoFrame,
            orientationRawValue: 6,
            timestampNs: 123_456_789,
            width: 1280,
            height: 720,
            payload: payload
        )

        let encoded = packet.encoded()
        #expect(encoded[5] == 6)
        #expect(ReplayKitBroadcastRelayPacket.payloadLength(inHeader: encoded.prefixData(ReplayKitBroadcastRelayPacket.headerLength)) == UInt32(payload.count))
        #expect(try ReplayKitBroadcastRelayPacket.parse(encoded) == packet)
    }

    @Test("ReplayKit legacy zero orientation defaults to upright")
    func legacyZeroOrientationDefaultsToUpright() throws {
        var encoded = ReplayKitBroadcastRelayPacket(
            type: .videoFrame,
            orientationRawValue: 6,
            timestampNs: 1
        ).encoded()
        encoded[5] = 0

        let parsed = try ReplayKitBroadcastRelayPacket.parse(encoded)
        #expect(parsed.orientationRawValue == ReplayKitBroadcastRelayPacket.defaultOrientationRawValue)
    }

    @Test("ReplayKit control packets round-trip")
    func controlPacketsRoundTrip() throws {
        for type in [
            ReplayKitBroadcastRelayPacketType.started,
            .paused,
            .resumed,
            .finished
        ] {
            let packet = ReplayKitBroadcastRelayPacket(type: type, timestampNs: 42)
            #expect(try ReplayKitBroadcastRelayPacket.parse(packet.encoded()) == packet)
        }
    }

    @Test("ReplayKit audio packets round-trip for future egress")
    func audioPacketsRoundTrip() throws {
        let payload = Data([0x10, 0x11, 0x12])
        let appAudio = ReplayKitBroadcastRelayPacket(
            type: .audioApp,
            timestampNs: 999,
            width: 48_000,
            height: 2,
            payload: payload
        )
        let micAudio = ReplayKitBroadcastRelayPacket(
            type: .audioMic,
            timestampNs: 1_000,
            width: 16_000,
            height: 1,
            payload: payload
        )

        #expect(try ReplayKitBroadcastRelayPacket.parse(appAudio.encoded()) == appAudio)
        #expect(try ReplayKitBroadcastRelayPacket.parse(micAudio.encoded()) == micAudio)
    }

    @Test("ReplayKit parser rejects malformed packets")
    func parserRejectsMalformedPackets() throws {
        #expect(throws: ReplayKitBroadcastRelayPacketError.self) {
            try ReplayKitBroadcastRelayPacket.parse(Data([0x4E, 0x54]))
        }

        var invalidMagic = ReplayKitBroadcastRelayPacket(type: .started, timestampNs: 0).encoded()
        invalidMagic[0] = 0x00
        #expect(throws: ReplayKitBroadcastRelayPacketError.self) {
            try ReplayKitBroadcastRelayPacket.parse(invalidMagic)
        }

        var invalidLength = ReplayKitBroadcastRelayPacket(type: .videoFrame, timestampNs: 0, payload: Data([1, 2, 3])).encoded()
        _ = invalidLength.removeLast()
        #expect(throws: ReplayKitBroadcastRelayPacketError.self) {
            try ReplayKitBroadcastRelayPacket.parse(invalidLength)
        }
    }

    @Test("ReplayKit parser rejects oversized payloads before allocation")
    func parserRejectsOversizedPayloads() throws {
        var header = ReplayKitBroadcastRelayPacket(type: .videoFrame, timestampNs: 0).encoded()
        header.replaceLittleEndianUInt32(
            UInt32(ReplayKitBroadcastRelayPacket.maxPayloadLength + 1),
            at: 24
        )

        #expect(throws: ReplayKitBroadcastRelayPacketError.payloadTooLarge(ReplayKitBroadcastRelayPacket.maxPayloadLength + 1)) {
            try ReplayKitBroadcastRelayPacket.parse(header)
        }
    }
}

private extension Data {
    func prefixData(_ maxLength: Int) -> Data {
        Data(prefix(maxLength))
    }

    mutating func replaceLittleEndianUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 {
            self[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xFF)
        }
    }
}
