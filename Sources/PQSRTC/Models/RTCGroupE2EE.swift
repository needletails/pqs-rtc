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
    // SFU media-key readiness. The encrypted payload is a Call whose sender is the source
    // participant this receiver is ready to decrypt.
    case mediaReady
    // SFU group-call control (roster)
    case participants, participantDemuxId
    /// Requests that the targeted participant stop an active screen share so another member
    /// can take over (one active room screen share at a time).
    case screenSharePreempt
}

public struct RatchetMessagePacket: Codable, Sendable, Equatable {
    
    /// Routing identifier for the SFU endpoint / group call instance.
    ///
    /// This typically matches the group call's `sfuRecipientId` and the WebRTC PeerConnection's `connectionId`.
    public let sfuIdentity: String
    /// The encrypted ratchet message containing the payload.
    public let ratchetMessage: RatchetMessage
    /// Compatibility accessor for callers that previously read the packet header directly.
    public var header: EncryptedHeader { ratchetMessage.header }
    
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
