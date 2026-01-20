//
//  RTCGroupE2EE.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//

import Foundation
import DoubleRatchetKit

public enum PacketFlag: Codable, Sendable {
    case offer, answer, candidate, handshakeComplete
}

public struct RatchetMessagePacket: Codable, Sendable, Equatable {
    
    /// Routing identifier for the SFU endpoint / group call instance.
    ///
    /// This typically matches the group call's `sfuRecipientId` and the WebRTC PeerConnection's `connectionId`.
    public let sfuIdentity: String
    /// The encrypted header (duplicated from `ratchetMessage.header` for convenience).
    public let header: EncryptedHeader
    /// The encrypted ratchet message containing the payload.
    public let ratchetMessage: RatchetMessage
    
    public let flag: PacketFlag
    
    public init(
        sfuIdentity: String,
        header: EncryptedHeader,
        ratchetMessage: RatchetMessage,
        flag: PacketFlag) {
            self.sfuIdentity = sfuIdentity
            self.header = header
            self.ratchetMessage = ratchetMessage
            self.flag = flag
        }
    
}

