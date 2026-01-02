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

/// Models for sender-key E2EE group calls.
///
/// The SFU forwards media, but never sees plaintext: media frames are encrypted with per-sender keys.
/// Those per-sender keys are distributed to each participant using pairwise Double Ratchet sessions.
///
/// `RTCGroupE2EE` contains the message and payload types used by:
/// - ``RTCGroupCall`` (to create/consume control-plane messages)
/// - Group Double Ratchet helpers on ``RTCSession`` (see `RTCSession+GroupDoubleRatchetE2EE.swift`)
public enum RTCGroupE2EE {

    /// Per-device identity information needed to establish a Double Ratchet session.
    public struct ParticipantIdentity: Codable, Sendable, Equatable {
        /// Application-level participant identifier.
        ///
        /// This is used for routing and mapping identities to participants. It should match
        /// the identifiers used by your app’s roster/control plane.
        public let participantId: String

        /// The participant’s advertised public identity material.
        ///
        /// This includes the public keys required to perform the initial PQXDH handshake and
        /// establish a Double Ratchet session.
        public let identityProps: SessionIdentity.UnwrappedProps

        public init(participantId: String, identityProps: SessionIdentity.UnwrappedProps) {
            self.participantId = participantId
            self.identityProps = identityProps
        }
    }

    /// Plaintext “sender key” distribution payload.
    ///
    /// This is encrypted (per recipient) using Double Ratchet and sent over the control plane.
    public struct SenderKeyDistribution: Codable, Sendable, Equatable {
        /// The call identifier this distribution belongs to.
        public let callId: String

        /// The participant id of the sender (the key owner).
        public let senderParticipantId: String

        /// The media key index associated with `key`.
        ///
        /// Implementations typically rotate keys by incrementing an index so receivers can
        /// update their key ring deterministically.
        public let keyIndex: Int

        /// Raw key bytes for frame encryption.
        ///
        /// The interpretation of these bytes is controlled by the frame encryption key provider.
        public let key: Data

        public init(callId: String, senderParticipantId: String, keyIndex: Int, key: Data) {
            self.callId = callId
            self.senderParticipantId = senderParticipantId
            self.keyIndex = keyIndex
            self.key = key
        }
    }

    /// Encrypted sender-key distribution message.
    ///
    /// - `handshakeCiphertext` is the PQXDH ciphertext that the receiver uses to initialize the
    ///   Double Ratchet state for this pair. It only needs to be included until the receiver has
    ///   initialized the session.
    /// - `payloadCiphertext` is the AES-GCM combined ciphertext produced by encrypting
    ///   `SenderKeyDistribution` with the derived per-message ratchet key.
    public struct EncryptedSenderKeyMessage: Codable, Sendable, Equatable {
        /// The call identifier this message belongs to.
        public let callId: String

        /// Sender participant id for routing/validation.
        public let fromParticipantId: String

        /// Recipient participant id for routing/validation.
        public let toParticipantId: String

        /// Session identifier used to scope the pairwise Double Ratchet state.
        ///
        /// This value is typically round-tripped through the application transport as a
        /// `connectionId` so both sides can find the correct stored session identity.
        public let sessionId: UUID

        /// Optional PQXDH handshake ciphertext.
        ///
        /// Include this until the receiver has successfully initialized the session.
        public let handshakeCiphertext: Data?

        /// Sender-provided ratchet message number.
        ///
        /// Receivers may treat this as best-effort debugging metadata.
        public let ratchetMessageNumber: Int

        /// AES-GCM ciphertext of the encoded ``SenderKeyDistribution``.
        public let payloadCiphertext: Data

        public init(
            callId: String,
            fromParticipantId: String,
            toParticipantId: String,
            sessionId: UUID,
            handshakeCiphertext: Data?,
            ratchetMessageNumber: Int,
            payloadCiphertext: Data
        ) {
            self.callId = callId
            self.fromParticipantId = fromParticipantId
            self.toParticipantId = toParticipantId
            self.sessionId = sessionId
            self.handshakeCiphertext = handshakeCiphertext
            self.ratchetMessageNumber = ratchetMessageNumber
            self.payloadCiphertext = payloadCiphertext
        }
    }
}
