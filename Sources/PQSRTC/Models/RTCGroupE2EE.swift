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
    // SFU/1:1 signaling
    case offer, answer, candidate, handshakeComplete
    // SFU group-call control (roster)
    case participants, participantDemuxId
}

public struct RatchetMessagePacket: Codable, Sendable, Equatable {
    
    /// Routing identifier for the SFU endpoint / group call instance.
    ///
    /// This typically matches the group call's `sfuRecipientId` and the WebRTC PeerConnection's `connectionId`.
    public let sfuIdentity: String
    /// The encrypted ratchet message containing the payload.
    public let ratchetMessage: RatchetMessage
    
    public let flag: PacketFlag
    
    public init(
        sfuIdentity: String,
        header: EncryptedHeader,
        ratchetMessage: RatchetMessage,
        flag: PacketFlag
    ) {
            self.sfuIdentity = sfuIdentity
            self.ratchetMessage = ratchetMessage
            self.flag = flag
        }
    
}

