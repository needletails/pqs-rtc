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
        let callDirection: CallStateMachine.CallDirection = .outbound(
            call.supportsVideo ? .video : .voice
        )

        // The outgoing party has committed to the call at this point. Enter connecting before
        // transport delivery so local preview and voice-call progress are immediate on slow links.
        await setConnectingIfReady(call: call, callDirection: callDirection)

        do {
            try await requireTransport().sendStartCall(call)
            logger.log(level: .info, message: "Sent start_call message for \(call.sharedCommunicationId)")
        } catch {
            shouldOffer = false
            await callState.transition(to: .failed(callDirection, call, error.localizedDescription))
            throw error
        }
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
    /// 3. Sends call_answered_aux_device notification to the user's other devices (always immediate)
    /// 4. Sends call_answered notification to the caller (immediate, or deferred via
    ///    ``sendCallAnsweredNotifications(for:)`` when `deferTransportAnswered` is `true`)
    ///
    /// - Parameters:
    ///   - call: The incoming call with SDP offer in metadata
    ///   - deferTransportAnswered: When `true`, prepares local state and acceptance gating but does
    ///     not send `call_answered` yet. The host app should call ``sendCallAnsweredNotifications(for:)``
    ///     when ready. Prefer deferring only CallKit-gated media bootstrap — not `call_answered` —
    ///     for inbound 1:1 SFU relay, so the caller can proceed after SFU registration.
    ///     `call_answered_aux_device` is **not** deferred: sibling devices must stop ringing the
    ///     moment this device commits to answering, independent of media/audio bootstrap.
    public func answerCall(_ call: Call, deferTransportAnswered: Bool = false) async throws {
        // Mark this call's PeerConnection as the active one (SFU uses a single PC).
        activeConnectionId = call.sharedCommunicationId.normalizedConnectionId
        let roleCall = await callForOneToOneSfuRoleDetection(call)
        let isOneToOneSfuRoom = Self.isTrueOneToOneSfuRoom(call: roleCall)
        if isOneToOneSfuRoom {
            // Inbound 1:1-over-SFU answerers establish their SFU leg via
            // `beginGroupCallMediaAfterSfuRegistrationIfNeeded(sendInitialOffer: true)` (host app).
            // The caller's first encrypted `.offer` is consumed by SwiftSFU, not relayed here.
            // Remote caller media arrives on a deferred SFU renegotiation `.offer` after
            // `call_cipher` + post-cipher `handshakeComplete`. Keep `shouldOffer = false` so
            // `finishCryptoSessionCreation` does not emit a competing WebRTC createOffer.
            shouldOffer = false
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
        
        // Register the answered state under this call's stable id, not only the global flag.
        // The inbound `call_cipher` sibling-device guard reads
        // `callAnswerStatesById[callId] ?? callAnswerState`; if only the global flag is set,
        // `finishCryptoSessionCreation` later seeds the per-call entry and can shadow the
        // answered intent, leaving the direct 1:1 answerer stuck with `answerState=pending`
        // (cipher ignored → no PC → no offer ever reaches the server).
        pendingAnswerCallId = call.sharedCommunicationId.stableUUIDConnectionId
        setCanAnswer(true)

        // Stop ringing on this user's other devices the moment this device commits to answering.
        // Unlike `call_answered`, this control message carries no crypto/media dependency, so it
        // must never wait for CallKit audio activation or SFU media bootstrap (which previously
        // left sibling devices ringing for 10+ seconds after an answer).
        do {
            try await requireTransport().sendCallAnsweredAuxDevice(call)
            logger.log(level: .info, message: "Sent call_answered_aux_device notification for \(call.sharedCommunicationId)")
        } catch {
            // Failing to notify sibling devices must not abort the answer on this device.
            logger.log(level: .error, message: "Failed to send call_answered_aux_device for \(call.sharedCommunicationId): \(error)")
        }

        if deferTransportAnswered {
            logger.log(
                level: .info,
                message: "Deferred call_answered transport notifications until inbound SFU media bootstrap for \(call.sharedCommunicationId)")
        } else {
            try await sendCallAnsweredNotifications(for: call)
        }
    }

    /// Sends `call_answered` after inbound media bootstrap is ready.
    ///
    /// `call_answered_aux_device` is sent eagerly by ``answerCall(_:deferTransportAnswered:)``
    /// and is intentionally not resent here.
    public func sendCallAnsweredNotifications(for call: Call) async throws {
        // `answerCall` provisions frame/signaling props on the RTCSession call state. Deferred SFU
        // bootstrap sends `call_answered` from CallManager's tracked copy, which can omit them and
        // leave the caller unable to derive outbound `call_cipher` keys before the initial offer.
        let normalizedId = call.sharedCommunicationId.normalizedConnectionId
        let outbound: Call
        if let sessionCall = await callState.currentCall,
           sessionCall.sharedCommunicationId.normalizedConnectionId == normalizedId {
            outbound = sessionCall
        } else {
            outbound = call
        }

        try await requireTransport().sendCallAnswered(outbound)
        logger.log(level: .info, message: "Sent call_answered notification for \(outbound.sharedCommunicationId)")
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

public extension Call {
    /// True for 1:1 calls relayed through the SFU using a transient `#<uuid>` room id.
    ///
    /// These rooms use a `#`-prefixed ``sharedCommunicationId`` but still have a single remote peer.
    /// Prefer this over ``String/isGroupCall`` when choosing UI layout (e.g. Android remote tile count).
    var isTrueOneToOneSfuRoom: Bool {
        RTCSession.isTrueOneToOneSfuRoom(call: self)
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
    /// - `conf-room` / `#conf-room`
    /// - `slug_<uuid>` / `#slug_<uuid>` (conference wire routes; mirrors SwiftSFU ``SFURoomId``)
    /// - bare UUID strings
    public var normalizedUUIDConnectionId: String {
        let noChannelPrefix = self
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedConnectionId

        if noChannelPrefix.hasPrefix("conf-") {
            let conferenceId = String(noChannelPrefix.dropFirst("conf-".count))
            if let uuid = UUID(uuidString: conferenceId) {
                return uuid.uuidString.lowercased()
            }
            return conferenceId.lowercased()
        }

        if let uuid = UUID(uuidString: noChannelPrefix) {
            return uuid.uuidString.lowercased()
        }

        if let separatorIndex = noChannelPrefix.lastIndex(of: "_") {
            let suffix = String(noChannelPrefix[noChannelPrefix.index(after: separatorIndex)...])
            if let uuid = UUID(uuidString: suffix) {
                return uuid.uuidString.lowercased()
            }
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
