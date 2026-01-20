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
import BinaryCodable

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

    // MARK: - SFU group-call signaling (encrypted)
    /// Sends an encrypted SFU signaling packet (group calls).
    ///
    /// Use `packet.flag` to distinguish `.offer` / `.answer` / `.candidate` / `.handshakeComplete`.
    ///
    /// Routing guidance:
    /// - `packet.sfuIdentity` identifies the SFU endpoint / room route
    /// - `call.sharedCommunicationId` identifies the local call instance
    func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws
    
    // MARK: - 1:1 call signaling (encrypted via SwiftSFU)
    
    /// Sends a start_call message to trigger VoIP notifications for the recipient.
    ///
    /// This should be sent before establishing the crypto session. The message contains
    /// `StartCallMetadata` and triggers push notifications so the recipient can accept/decline.
    /// - Parameter call: The call to start (must have sender, recipients, and sharedCommunicationId)
    func sendStartCall(_ call: Call) async throws
    
    /// Sends a call_answered notification to notify the caller that the call was answered.
    ///
    /// This should be sent after the callee accepts the call and generates an SDP answer.
    /// - Parameter call: The call that was answered
    func sendCallAnswered(_ call: Call) async throws
    
    /// Sends a call_answered_aux_device notification to notify other devices that the call was answered on this device.
    ///
    /// This is used for multi-device scenarios where the user has multiple devices.
    /// - Parameter call: The call that was answered on this device
    func sendCallAnsweredAuxDevice(_ call: Call) async throws
    
    /// Sends an encrypted 1:1 message.
    ///
    /// The packet contains an encrypted `Call` object with SDP offer in metadata.
    /// Default behavior encodes the packet and forwards it through `sendCiphertext(...)` using
    /// `recipient = packet.sfuIdentity` and `connectionId = call.sharedCommunicationId`.
    func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws
    
    /// Called when the SDK ends a call.
    func didEnd(call: Call, endState: CallStateMachine.EndState) async throws
    
    //Information will not be encrypted should go through a secure route
    func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws
    //Information will not be encrypted should go through a secure route
    func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws
}
