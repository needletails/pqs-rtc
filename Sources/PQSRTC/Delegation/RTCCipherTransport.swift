//
//  RTCCipherTransport.swift
//  pqs-rtc
//
//  Created by Cole M on 12/2/25.
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

/// Transport callbacks implemented by the application.
///
/// `PQSRTC` does not define a signaling protocol. Instead, the SDK emits outbound intents
/// via this protocol and your app is responsible for transmitting them over your control plane
/// (websocket, push, HTTP, etc.) and routing inbound messages back into the SDK.
///
/// See <doc:Transport> for practical routing guidance.
public protocol RTCTransportEvents: Sendable {
    /// Sends an opaque ciphertext blob to a specific recipient.
    ///
    /// The SDK uses ciphertext messages for:
    /// - 1:1 Double Ratchet handshake/ratcheting
    /// - Optional group sender-key distribution (when using ``RTCGroupCall`` sender keys)
    ///
    /// - Parameters:
    ///   - recipient: Application-level recipient identifier (often a participant `secretName`).
    ///   - connectionId: A stable routing identifier that must be round-tripped back on receive.
    ///   - ciphertext: Opaque payload (do not parse or modify).
    ///   - call: Call context for routing (typically `call.sharedCommunicationId`).
    func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws

    /// Sends an SDP offer.
    ///
    /// - Important: For SFU group calls, this offer is intended for the SFU endpoint.
    func sendOffer(call: Call) async throws

    /// Sends an SDP answer and 1:1 negotiation metadata.
    ///
    /// - Note: This callback is used for 1:1 calls.
    func sendAnswer(call: Call, metadata: PQSRTC.SDPNegotiationMetadata) async throws

    /// Sends an ICE candidate.
    func sendCandidate(_ candidate: IceCandidate, call: Call) async throws

    /// Called when the SDK ends a call.
    func didEnd(call: Call, endState: CallStateMachine.EndState) async throws
}
