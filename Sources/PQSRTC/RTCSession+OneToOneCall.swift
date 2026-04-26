//
//  RTCSession+OneToOneCall.swift
//  pqs-rtc
//
//  Created by Cole M on 1/15/26.
//

import Foundation
import Crypto
import DoubleRatchetKit
import BinaryCodable

extension RTCSession {
    
    /// Decrypts 1:1 signaling data using the call's Double Ratchet keys.
    ///
    /// Uses `pcRatchetManager` to decrypt packets received via SwiftSFU.
    public func decryptOneToOneSignaling(
        header: EncryptedHeader,
        ciphertext: RatchetMessage,
        connectionId: String
    ) async throws -> Data {
        
        // Get connection identity for this 1:1 signaling channel.
        // Some transports (e.g. IRC/SFU) may deliver a channel-style id like "#<uuid>".
        // The key store supports both, but we normalize here for consistency.
        let connectionIdentity = try await pcKeyManager.fetchConnectionIdentity(connection: connectionId.normalizedConnectionId)
        // Get local identity
        let callBundle = try await pcKeyManager.fetchCallKeyBundle()
        
        try await pcRatchetManager.recipientInitialization(
            sessionIdentity: connectionIdentity.sessionIdentity,
            sessionSymmetricKey: callBundle.symmetricKey,
            header: header,
            localKeys: callBundle.localKeys)
        
        // Decrypt
        let decrypted = try await pcRatchetManager.ratchetDecrypt(
            ciphertext,
            sessionId: connectionIdentity.sessionIdentity.id)
        
        return decrypted
    }
    
    public func startCall(_ call: Call) async throws {
        shouldOffer = true
        try await requireTransport().sendStartCall(call)
        logger.log(level: .info, message: "Sent start_call message for \(call.sharedCommunicationId)")
    }
    
    public func setupCallState(_ call: Call) async throws {
        resetAttemptFlagsForNewCall(connectionId: call.sharedCommunicationId)
        try await createStateStream(with: call)
    }
    
    /// Initiates an outbound 1:1 call.
    /// - Parameter call: The call to initiate (must have recipient's identityProps)
    public func initiateCall(with call: Call) async throws {
        //Create crypto session (establishes Double Ratchet handshake)
        try await createCryptoPeerConnection(with: call)
        logger.log(level: .info, message: "Initiated 1:1 call setup for \(call.sharedCommunicationId)")
    }
    
    /// Answers an incoming 1:1 call.
    ///
    /// This method:
    /// 1. Handles the incoming SDP offer and generates an answer
    /// 2. Sends encrypted SDP answer via SwiftSFU
    /// 3. Sends call_answered notification to the caller
    /// 4. Sends call_answered_aux_device notification to other devices
    ///
    /// - Parameter call: The incoming call with SDP offer in metadata
    public func answerCall(_ call: Call) async throws {
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId.normalizedConnectionId
        let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: call)
        if isOneToOneSfuRoom {
            // 1:1-over-SFU is still a client<->SFU media session on each device, so the answering
            // participant must negotiate its own peer connection with the SFU.
            shouldOffer = true
        } else if isGroupCall {
            shouldOffer = true
        } else {
            // Direct 1:1 answerers must not switch to offerer role.
            shouldOffer = false
        }
        
        guard let recipient = call.recipients.first else {
            throw RTCErrors.invalidConfiguration("Answering a call with no recipients is not supported.")
        }

        // Resolve the local participant's secretName for sender-identity provisioning.
        //
        // For direct 1:1, the inbound `Call` keeps the wire orientation: `sender` is the
        // remote caller and `recipients.first` is the local user — so `recipient.secretName`
        // is correct.
        //
        // For 1:1-over-SFU, the host app (CallManager.answerCall) rewrites the call before
        // invoking us so that `sender` becomes the local user and `recipients` carries the
        // remote DR target. Using `recipient.secretName` here would provision the local
        // frame/signaling identities under the **remote** peer's secretName, leading to
        // FrameCryptor key-id mismatches and silently undecryptable inbound media.
        // Prefer the cached `sessionParticipant`; fall back to the SFU-shape sender, then
        // to the direct-shape recipient.
        let localSecretName: String = {
            if let sp = sessionParticipant?.secretName, !sp.isEmpty {
                return sp
            }
            if isOneToOneSfuRoom {
                return call.sender.secretName
            }
            return recipient.secretName
        }()

        let frameLocalIdentity: ConnectionLocalIdentity
        if let foundLocalIdentity = try? await keyManager.fetchCallKeyBundle() {
            frameLocalIdentity = foundLocalIdentity
        } else {
            frameLocalIdentity = try await keyManager.generateSenderIdentity(
                connectionId: call.sharedCommunicationId,
                secretName: localSecretName
            )
        }
        
        let signalingLocalIdentity: ConnectionLocalIdentity
        if let foundSignalingLocalIdentity = try? await pcKeyManager.fetchCallKeyBundle() {
            signalingLocalIdentity = foundSignalingLocalIdentity
        } else {
            signalingLocalIdentity = try await pcKeyManager.generateSenderIdentity(
               connectionId: call.sharedCommunicationId,
               secretName: localSecretName)
        }
        
        var call = call
        call.frameIdentityProps = await frameLocalIdentity.sessionIdentity.props(symmetricKey: frameLocalIdentity.symmetricKey)
        call.signalingIdentityProps = await signalingLocalIdentity.sessionIdentity.props(symmetricKey: signalingLocalIdentity.symmetricKey)
        
        // This is the soonest place that we can create a state stream with the call built
        try await createStateStream(with: call)
        await setConnectingIfReady(call: call, callDirection: .inbound(call.supportsVideo ? .video : .voice))
        
        setCanAnswer(true)
        // Send call_answered notification to the caller
        try await requireTransport().sendCallAnswered(call)
        logger.log(level: .info, message: "Sent call_answered notification for \(call.sharedCommunicationId)")
        
        // Send call_answered_aux_device notification to other devices
        try await requireTransport().sendCallAnsweredAuxDevice(call)
        logger.log(level: .info, message: "Sent call_answered_aux_device notification for \(call.sharedCommunicationId)")
    }
    
    /// Handles notification that the call was answered on another device.
    ///
    /// Transitions the call state to indicate it was answered elsewhere.
    ///
    /// - Parameter call: The call that was answered elsewhere
    public func handleCallAnsweredElsewhere(_ call: Call) async throws {
        await callState.transition(to: .callAnsweredAuxDevice(call))
        logger.log(level: .info, message: "Call answered on another device: \(call.sharedCommunicationId)")
    }
    
    /// Ends a 1:1 call.
    ///
    /// Shuts down the peer connection and cleans up resources.
    ///
    /// - Parameter call: The call to end
    public func endCall(_ call: Call) async throws {
        await shutdown(with: call)
        logger.log(level: .info, message: "Ended 1:1 call: \(call.sharedCommunicationId)")
    }

    /// Delivers user-initiated hangup to the transport delegate (`didEnd`) without tearing down the session.
    /// Use with ``shutdown(with:)`` when call UI is dismissed without ``VideoCallViewController``/``tearDownCall`` (e.g. window chrome close).
    public func notifyTransportUserEndedCall(_ call: Call) async throws {
        let transport = try requireTransport()
        try await transport.didEnd(call: call, endState: .userInitiated)
    }
}

extension String {
    /// Channel-backed group rooms use a `#` prefix. SFU conference rooms often use `conf-<uuid>` (with or
    /// without `#`) as the peer-connection id — treat those as group for E2EE sender deferral, SSRC stripping,
    /// and related paths that key off ``String/isGroupCall``.
    public var isGroupCall: Bool {
        if self.first == "#" { return true }
        return normalizedConnectionId.hasPrefix("conf-")
    }
    
    public var normalizedConnectionId: String {
        self.hasPrefix("#") ? String(self.dropFirst()) : self
    }

    /// Normalizes identifiers that should map to a stable connection/session stem.
    ///
    /// Accepted forms:
    /// - `room`
    /// - `#room`
    /// - `conf-room`
    /// - `#conf-room`
    ///
    /// UUID-shaped room stems are preserved for backwards compatibility.
    public var normalizedUUIDConnectionId: String {
        let noChannelPrefix = self
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedConnectionId
        if noChannelPrefix.hasPrefix("conf-") {
            return String(noChannelPrefix.dropFirst("conf-".count))
        }
        return noChannelPrefix
    }

    /// Returns a stable UUID for any supported connection/session id.
    ///
    /// If the normalized room stem is already a UUID, the UUID is returned unchanged. Otherwise,
    /// SHA-256 is used to derive a deterministic UUID payload for ratchet/session APIs that are
    /// UUID-keyed internally.
    public var stableUUIDConnectionId: UUID {
        let normalized = normalizedUUIDConnectionId.lowercased()
        if let uuid = UUID(uuidString: normalized) {
            return uuid
        }

        let digest = SHA256.hash(data: Data(normalized.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
    
    public var ensureIRCChannel: String {
        self.hasPrefix("#") ? self : "#\(self)"
    }
}
