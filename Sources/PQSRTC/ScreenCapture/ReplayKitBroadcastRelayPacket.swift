//
//  ReplayKitBroadcastRelayPacket.swift
//  pqs-rtc
//
//  Copyright (c) 2025 NeedleTails Organization.
//

import Foundation

enum ReplayKitBroadcastRelayPacketType: UInt8, Sendable {
    case started = 1
    case videoFrame = 2
    case paused = 3
    case resumed = 4
    case finished = 5
    case audioApp = 6
    case audioMic = 7
}

struct ReplayKitBroadcastRelayPacket: Sendable, Equatable {
    static let magic = Data([0x4E, 0x54, 0x52, 0x50]) // "NTRP"
    static let headerLength = 28
    static let maxPayloadLength = 16 * 1024 * 1024
    static let defaultOrientationRawValue: UInt8 = 1

    let type: ReplayKitBroadcastRelayPacketType
    let orientationRawValue: UInt8
    let timestampNs: Int64
    let width: UInt32
    let height: UInt32
    let payload: Data

    init(
        type: ReplayKitBroadcastRelayPacketType,
        orientationRawValue: UInt8 = Self.defaultOrientationRawValue,
        timestampNs: Int64,
        width: UInt32 = 0,
        height: UInt32 = 0,
        payload: Data = Data()
    ) {
        self.type = type
        self.orientationRawValue = orientationRawValue == 0 ? Self.defaultOrientationRawValue : orientationRawValue
        self.timestampNs = timestampNs
        self.width = width
        self.height = height
        self.payload = payload
    }

    func encoded() -> Data {
        var packet = Data()
        packet.append(Self.magic)
        packet.append(type.rawValue)
        packet.append(orientationRawValue)
        packet.append(contentsOf: [0, 0])
        packet.appendLittleEndianUInt64(UInt64(bitPattern: timestampNs))
        packet.appendLittleEndianUInt32(width)
        packet.appendLittleEndianUInt32(height)
        packet.appendLittleEndianUInt32(UInt32(payload.count))
        packet.append(payload)
        return packet
    }

    static func payloadLength(inHeader header: Data) -> UInt32? {
        guard header.count >= headerLength, header.prefix(4) == magic else { return nil }
        return header.littleEndianUInt32(at: 24)
    }

    static func parse(_ data: Data) throws -> ReplayKitBroadcastRelayPacket {
        guard data.count >= headerLength else {
            throw ReplayKitBroadcastRelayPacketError.incompleteHeader
        }
        guard data.prefix(4) == magic else {
            throw ReplayKitBroadcastRelayPacketError.invalidMagic
        }
        guard let type = ReplayKitBroadcastRelayPacketType(rawValue: data[4]) else {
            throw ReplayKitBroadcastRelayPacketError.unknownPacketType(data[4])
        }
        let payloadLength = Int(data.littleEndianUInt32(at: 24))
        guard payloadLength <= maxPayloadLength else {
            throw ReplayKitBroadcastRelayPacketError.payloadTooLarge(payloadLength)
        }
        guard data.count == headerLength + payloadLength else {
            throw ReplayKitBroadcastRelayPacketError.invalidPayloadLength(expected: payloadLength, actual: max(0, data.count - headerLength))
        }
        return ReplayKitBroadcastRelayPacket(
            type: type,
            orientationRawValue: data[5] == 0 ? defaultOrientationRawValue : data[5],
            timestampNs: Int64(bitPattern: data.littleEndianUInt64(at: 8)),
            width: data.littleEndianUInt32(at: 16),
            height: data.littleEndianUInt32(at: 20),
            payload: data.subdata(in: headerLength..<data.count)
        )
    }
}

enum ReplayKitBroadcastRelayPacketError: Error, Equatable {
    case incompleteHeader
    case invalidMagic
    case unknownPacketType(UInt8)
    case invalidPayloadLength(expected: Int, actual: Int)
    case payloadTooLarge(Int)
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    func littleEndianUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func appendLittleEndianUInt64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
