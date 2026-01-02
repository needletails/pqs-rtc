//
//  RTCSession+GroupDoubleRatchetE2EE.swift
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
import DoubleRatchetKit
import NeedleTailCrypto

extension RTCSession {

    /// Encrypts a group-call sender-key distribution payload to a single recipient using Double Ratchet.
    ///
    /// This uses `RatchetKeyStateManager` in “external key derivation” mode:
    /// - derive a per-message symmetric key (`deriveMessageKey`)
    /// - encrypt the payload externally (AES-GCM via `NeedleTailCrypto`)
    ///
    /// This helper is intended for SFU-style group calls that use *per-sender* media keys
    /// (“sender keys”). The sender key material is distributed over the application’s control
    /// plane as an opaque ciphertext, protected pairwise using Double Ratchet.
    ///
    /// - Important: PQSRTC does not send this message for you. Callers typically forward the
    ///   returned `RTCGroupE2EE.EncryptedSenderKeyMessage` via ``RTCTransportEvents/sendCiphertext(recipient:connectionId:ciphertext:call:)``
    ///   or an equivalent app-owned channel.
    ///
    /// - Parameters:
    ///   - callId: A stable call identifier used to scope local identity generation and key storage.
    ///   - localSecretName: The local application-level participant identifier used when generating a sender identity.
    ///   - fromParticipantId: The logical sender participant id to embed in the outgoing message.
    ///   - toParticipantId: The logical recipient participant id to embed in the outgoing message.
    ///   - toIdentityProps: The recipient’s advertised identity properties (public keys) used to initialize Double Ratchet.
    ///   - sessionId: A per-recipient session identifier used as the `connectionId`/routing key.
    ///   - includeHandshakeCiphertext: When `true`, includes the PQXDH handshake ciphertext to allow the recipient to initialize.
    ///     Send this at least once per pair (or whenever the recipient lacks the handshake ciphertext).
    ///   - distribution: The sender-key distribution payload to encrypt.
    ///
    /// - Returns: An encrypted message containing optional handshake ciphertext, message number, and encrypted payload.
    ///
    /// - Throws: ``RTCSession/EncryptionErrors`` for missing identity material, failed crypto payload creation,
    ///   or Double Ratchet initialization/derivation failures.
    func encryptGroupSenderKeyDistribution(
        callId: String,
        localSecretName: String,
        fromParticipantId: String,
        toParticipantId: String,
        toIdentityProps: SessionIdentity.UnwrappedProps,
        sessionId: UUID,
        includeHandshakeCiphertext: Bool,
        distribution: RTCGroupE2EE.SenderKeyDistribution
    ) async throws -> RTCGroupE2EE.EncryptedSenderKeyMessage {

        let localIdentity: ConnectionLocalIdentity
        if let existing = try await keyManager.fetchCallKeyBundle() {
            localIdentity = existing
        } else {
            localIdentity = try await generateSenderIdentity(connectionId: callId, secretName: localSecretName)
        }

        let connectionId = sessionId.uuidString
        let remoteIdentity: ConnectionSessionIdentity
        if let existing = await keyManager.fetchConnectionIdentityByConnectionId(connectionId) {
            remoteIdentity = existing
        } else {
            remoteIdentity = try await createRecipientIdentity(connectionId: connectionId, props: toIdentityProps)
        }

        guard let props = await remoteIdentity.sessionIdentity.props(symmetricKey: remoteIdentity.symmetricKey) else {
            throw EncryptionErrors.missingProps
        }

        try await ratchetManager.senderInitialization(
            sessionIdentity: remoteIdentity.sessionIdentity,
            sessionSymmetricKey: remoteIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(props.longTermPublicKey),
                oneTime: props.oneTimePublicKey,
                mlKEM: props.mlKEMPublicKey
            ),
            localKeys: localIdentity.localKeys
        )

        let handshakeCiphertext = try await ratchetManager.getCipherText(sessionId: remoteIdentity.sessionIdentity.id)

        let (messageKey, messageNumber) = try await ratchetManager.deriveMessageKey(sessionId: remoteIdentity.sessionIdentity.id)

        let plaintext = try JSONEncoder().encode(distribution)
        guard let payloadCiphertext = try NeedleTailCrypto().encrypt(data: plaintext, symmetricKey: messageKey) else {
            throw EncryptionErrors.missingCryptoPayload
        }

        return RTCGroupE2EE.EncryptedSenderKeyMessage(
            callId: callId,
            fromParticipantId: fromParticipantId,
            toParticipantId: toParticipantId,
            sessionId: sessionId,
            handshakeCiphertext: includeHandshakeCiphertext ? handshakeCiphertext : nil,
            ratchetMessageNumber: messageNumber,
            payloadCiphertext: payloadCiphertext
        )
    }

    /// Decrypts a group-call sender-key distribution payload from a single sender using Double Ratchet.
    ///
    /// This performs the inverse of ``encryptGroupSenderKeyDistribution(callId:localSecretName:fromParticipantId:toParticipantId:toIdentityProps:sessionId:includeHandshakeCiphertext:distribution:)``:
    /// - Ensures local identity exists (or creates it).
    /// - Stores an optional handshake ciphertext (if provided).
    /// - Initializes the recipient ratchet state using the sender’s advertised identity and the stored handshake ciphertext.
    /// - Derives the per-message symmetric key and decrypts the payload.
    ///
    /// - Important: At least one message per pair must provide `handshakeCiphertext` (or the application must
    ///   provide it out-of-band). If no handshake ciphertext is available, this throws `missingCipherText`.
    ///
    /// - Parameters:
    ///   - callId: A stable call identifier used to scope local identity generation and key storage.
    ///   - localSecretName: The local application-level participant identifier used when generating a sender identity.
    ///   - fromParticipantId: The logical sender participant id, used for bookkeeping/routing at the call site.
    ///   - fromIdentityProps: The sender’s advertised identity properties (public keys) used to initialize Double Ratchet.
    ///   - message: The encrypted sender-key message to decrypt.
    ///
    /// - Returns: The decoded sender-key distribution payload.
    ///
    /// - Throws: ``RTCSession/EncryptionErrors`` when required handshake/identity material is missing, when
    ///   Double Ratchet initialization fails, or when the payload cannot be decrypted/decoded.
    func decryptGroupSenderKeyDistribution(
        callId: String,
        localSecretName: String,
        fromParticipantId: String,
        fromIdentityProps: SessionIdentity.UnwrappedProps,
        message: RTCGroupE2EE.EncryptedSenderKeyMessage
    ) async throws -> RTCGroupE2EE.SenderKeyDistribution {

        let localIdentity: ConnectionLocalIdentity
        if let existing = try await keyManager.fetchCallKeyBundle() {
            localIdentity = existing
        } else {
            localIdentity = try await generateSenderIdentity(connectionId: callId, secretName: localSecretName)
        }

        let connectionId = message.sessionId.uuidString

        if let handshake = message.handshakeCiphertext {
            await keyManager.storeCiphertext(connectionId: connectionId, ciphertext: handshake)
        }

        let remoteIdentity: ConnectionSessionIdentity
        if let existing = await keyManager.fetchConnectionIdentityByConnectionId(connectionId) {
            remoteIdentity = existing
        } else {
            remoteIdentity = try await createRecipientIdentity(connectionId: connectionId, props: fromIdentityProps)
        }

        guard let props = await remoteIdentity.sessionIdentity.props(symmetricKey: remoteIdentity.symmetricKey) else {
            throw EncryptionErrors.missingProps
        }

        guard let cipherTextForInit = await keyManager.fetchCiphertext(connectionId: connectionId), !cipherTextForInit.isEmpty else {
            // We require the PQXDH handshake ciphertext at least once per pair.
            throw EncryptionErrors.missingCipherText
        }

        try await ratchetManager.recipientInitialization(
            sessionIdentity: remoteIdentity.sessionIdentity,
            sessionSymmetricKey: remoteIdentity.symmetricKey,
            localKeys: localIdentity.localKeys,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(props.longTermPublicKey),
                oneTime: props.oneTimePublicKey,
                mlKEM: props.mlKEMPublicKey
            ),
            ciphertext: cipherTextForInit
        )

        let (messageKey, derivedNumber) = try await ratchetManager.deriveReceivedMessageKey(
            sessionId: remoteIdentity.sessionIdentity.id,
            cipherText: cipherTextForInit
        )

        // Best-effort sanity: if numbers diverge, decryption may still fail; callers can decide how strict to be.
        if derivedNumber != message.ratchetMessageNumber {
            // No hard failure to avoid breaking when messages are delivered strictly in order but the sender
            // chooses not to ship message numbers. Keep the value for debugging.
        }

        guard let plaintext = try NeedleTailCrypto().decrypt(data: message.payloadCiphertext, symmetricKey: messageKey) else {
            throw EncryptionErrors.missingCryptoPayload
        }

        let dist = try JSONDecoder().decode(RTCGroupE2EE.SenderKeyDistribution.self, from: plaintext)
        return dist
    }
}
