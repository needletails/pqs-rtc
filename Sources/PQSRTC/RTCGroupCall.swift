//
//  RTCGroupCall.swift
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

/// Lightweight SFU group call facade.
///
/// Use this when you want SFU calls with multiple inbound tracks (Unified Plan) and
/// frame-level E2EE.
///
/// `RTCGroupCall` provides:
/// - A single entrypoint for decoded control-plane messages: ``handleControlMessage(_:)``
/// - A stream of high-level events (state/roster/track arrival): ``events()``
/// - Helpers for key distribution:
///   - Control-plane injected keys via ``setFrameEncryptionKey(_:index:for:)``
///   - Optional sender-key distribution via ``rotateAndSendLocalSenderKeyForCurrentParticipants()``
///
/// See <doc:Group-Calls>.
public actor RTCGroupCall: RTCSessionMediaEvents {

    /// High-level lifecycle state for the group call.
    public enum State: Sendable, Equatable {
        case idle
        case joining
        case joined
        case ended
    }

    /// A participant in the group call.
    ///
    /// `demuxId` can be used when your SFU identifies participants via a numeric “demux” id.
    public struct Participant: Sendable, Codable, Hashable {
        public let id: String
        public var demuxId: UInt32?

        public init(id: String, demuxId: UInt32? = nil) {
            self.id = id
            self.demuxId = demuxId
        }
    }

    /// High-level events emitted by the group call facade.
    public enum Event: Sendable, Equatable {
        /// The group call state changed.
        case stateChanged(State)
        /// The participant roster changed.
        case participantsUpdated([Participant])
        /// A new inbound remote track was observed.
        case remoteTrackAdded(participantId: String, kind: String, trackId: String)
    }

    /// Minimal “control-plane” messages needed to operate an SFU group call.
    ///
    /// This is intentionally transport-agnostic: your app decodes whatever JSON/protobuf/etc
    /// and maps into one of these cases.
    public enum ControlMessage: Sendable {
        /// SFU signaling
        case sfuAnswer(SessionDescription)
        case sfuCandidate(IceCandidate)

        /// Roster
        case participants([Participant])
        case participantDemuxId(participantId: String, demuxId: UInt32?)

        /// Frame E2EE keys distributed out-of-band.
        ///
        /// The meaning of `participantId` is “track owner / sender id” (the same id the
        /// receiver cryptor is configured with).
        case frameKey(participantId: String, index: Int, key: Data)

        /// Sender-key group E2EE: per-recipient encrypted sender-key distribution messages.
        ///
        /// You must also provide `participantIdentity` for each participant that can send you
        /// encrypted sender keys (i.e. their DoubleRatchet public identity props).
        case participantIdentity(RTCGroupE2EE.ParticipantIdentity)
        case encryptedSenderKey(RTCGroupE2EE.EncryptedSenderKeyMessage)
    }

    private let session: RTCSession
    private let sfuRecipientId: String
    private var call: Call

    private var state: State = .idle
    private var participantsById: [String: Participant] = [:]

    // Group E2EE (sender keys over pairwise Double Ratchet)
    private var identityPropsByParticipantId: [String: SessionIdentity.UnwrappedProps] = [:]
    private var e2eeSessionIdByParticipantId: [String: UUID] = [:]
    private var e2eeHandshakeSentToParticipantIds: Set<String> = []
    private var localSenderKeyIndex: Int = 0

    private let eventsStream: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation

    public init(session: RTCSession, call: Call, sfuRecipientId: String) {
        self.session = session
        self.call = call
        self.sfuRecipientId = sfuRecipientId
        (self.eventsStream, self.eventsContinuation) = AsyncStream.makeStream(of: Event.self)
    }

    deinit {
        eventsContinuation.finish()
    }

    /// A stream of group-call events.
    ///
    /// Consume this stream to update your UI (roster changes, track arrival, state changes).
    public func events() -> AsyncStream<Event> {
        eventsStream
    }

    /// Returns the current group-call lifecycle state.
    public func currentState() -> State {
        state
    }

    /// Returns the session’s latest view of the current participant roster.
    public func currentParticipants() -> [Participant] {
        Array(participantsById.values)
    }

    /// Joins the group call.
    ///
    /// This creates the SFU PeerConnection and triggers an outbound SDP offer via
    /// ``RTCTransportEvents/sendOffer(call:)``.
    public func join() async throws {
        guard state == .idle else { return }
        state = .joining
        eventsContinuation.yield(.stateChanged(.joining))

        await session.setMediaDelegate(self)
        call = try await session.startGroupCall(call: call, sfuRecipientId: sfuRecipientId)

        // We treat “join” as “connected enough to proceed”; actual ICE connectivity
        // is still tracked by the existing call state machine.
        state = .joined
        eventsContinuation.yield(.stateChanged(.joined))
    }

    public func leave() async {
        guard state != .ended else { return }
        state = .ended
        eventsContinuation.yield(.stateChanged(.ended))
        await session.shutdown(with: call)
    }

    /// Single entrypoint to apply decoded control-plane messages.
    ///
    /// This is the intended transport-agnostic surface: your app owns the networking and
    /// calls into this API as messages arrive.
    ///
    /// Your networking layer should decode inbound SFU signaling, roster updates, and key
    /// distribution messages into ``ControlMessage`` and call this method.
    public func handleControlMessage(_ message: ControlMessage) async throws {
        switch message {
        case .sfuAnswer(let sdp):
            try await handleSfuAnswer(sdp)
        case .sfuCandidate(let candidate):
            try await handleSfuCandidate(candidate)
        case .participants(let participants):
            updateParticipants(participants)
        case .participantDemuxId(let participantId, let demuxId):
            setDemuxId(demuxId, for: participantId)
        case .frameKey(let participantId, let index, let key):
            await setFrameEncryptionKey(key, index: index, for: participantId)

        case .participantIdentity(let identity):
            identityPropsByParticipantId[identity.participantId] = identity.identityProps

        case .encryptedSenderKey(let encrypted):
            try await handleEncryptedSenderKeyMessage(encrypted)
        }
    }

    // MARK: - Signaling ingress (SFU)

    /// Applies an inbound SFU SDP answer to the underlying PeerConnection.
    public func handleSfuAnswer(_ sdp: SessionDescription) async throws {
        try await session.handleAnswer(call: call, sdp: sdp)
    }

    /// Applies an inbound SFU ICE candidate to the underlying PeerConnection.
    public func handleSfuCandidate(_ candidate: IceCandidate) async throws {
        try await session.handleCandidate(call: call, candidate: candidate)
    }

    // MARK: - Control plane / roster

    /// Replaces the participant roster with the given list.
    public func updateParticipants(_ participants: [Participant]) {
        var updated: [String: Participant] = [:]
        for p in participants {
            updated[p.id] = p
        }
        participantsById = updated
        eventsContinuation.yield(.participantsUpdated(participants))
    }

    /// Updates the demux id for a participant.
    public func setDemuxId(_ demuxId: UInt32?, for participantId: String) {
        var participant = participantsById[participantId] ?? Participant(id: participantId)
        participant.demuxId = demuxId
        participantsById[participantId] = participant
        eventsContinuation.yield(.participantsUpdated(Array(participantsById.values)))
    }

    // MARK: - E2EE key injection

    /// Sets (injects) a frame-level E2EE key for a specific sender/participant.
    public func setFrameEncryptionKey(_ key: Data, index: Int = 0, for participantId: String) async {
        await session.setFrameEncryptionKey(key, index: index, for: participantId)
    }

    /// Advances the ratchet for the specified participant and key index.
    ///
    /// The returned key is the newly-derived key bytes.
    public func ratchetFrameEncryptionKey(index: Int = 0, for participantId: String) async -> Data {
        await session.ratchetFrameEncryptionKey(index: index, for: participantId)
    }

    /// Exports the current frame key for the specified participant and key index.
    public func exportFrameEncryptionKey(index: Int = 0, for participantId: String) async -> Data {
        await session.exportFrameEncryptionKey(index: index, for: participantId)
    }

    // MARK: - Sender-key group E2EE (Sender Keys)

    /// Stores / updates the Double Ratchet identity props for participants.
    ///
    /// This is required for sender-key distribution encryption/decryption.
    ///
    /// Your application is responsible for exchanging identity material (e.g. during join/roster updates)
    /// and then calling this method to provide the current set of identity properties.
    ///
    /// - Parameter identities: Participant identities keyed by `participantId`.
    public func setParticipantIdentities(_ identities: [RTCGroupE2EE.ParticipantIdentity]) {
        for identity in identities {
            identityPropsByParticipantId[identity.participantId] = identity.identityProps
        }
    }

    /// Rotates the local sender key and encrypts the distribution message to each other participant.
    ///
    /// The caller is responsible for transporting the returned messages to their recipients.
    ///
    /// - Important: This is designed for groups up to ~20 participants. Complexity is O(N).
    ///
    /// Typical usage:
    /// 1. Call ``setParticipantIdentities(_:)`` whenever the roster changes.
    /// 2. Call this method to get one encrypted message per recipient.
    /// 3. Send each message over your control plane (opaque bytes), keyed by `(recipientId, connectionId)`.
    ///
    /// The local sender key is applied immediately for outbound media encryption. Receivers apply the
    /// sender key after successfully decrypting the message via ``handleEncryptedSenderKeyMessage(_:)``.
    public func rotateAndEncryptLocalSenderKeyForCurrentParticipants() async throws -> [RTCGroupE2EE.EncryptedSenderKeyMessage] {
        let callId = call.sharedCommunicationId
        let localSecretName = call.sender.secretName
        let fromParticipantId = call.sender.secretName

        // Generate a fresh per-sender media key.
        let key = Self.randomSymmetricKeyBytes()
        localSenderKeyIndex += 1
        let keyIndex = localSenderKeyIndex

        // Apply locally for outbound encryption. (participantId = local sender id)
        await session.setFrameEncryptionKey(key, index: keyIndex, for: fromParticipantId)

        let distribution = RTCGroupE2EE.SenderKeyDistribution(
            callId: callId,
            senderParticipantId: fromParticipantId,
            keyIndex: keyIndex,
            key: key
        )

        var messages: [RTCGroupE2EE.EncryptedSenderKeyMessage] = []
        for participant in participantsById.values {
            let toParticipantId = participant.id
            guard toParticipantId != fromParticipantId else { continue }
            guard let props = identityPropsByParticipantId[toParticipantId] else {
                // No identity props: cannot encrypt to this participant.
                continue
            }

            let sessionId = e2eeSessionIdByParticipantId[toParticipantId] ?? {
                let id = UUID()
                e2eeSessionIdByParticipantId[toParticipantId] = id
                return id
            }()

            let includeHandshake = !e2eeHandshakeSentToParticipantIds.contains(toParticipantId)
            let encrypted = try await session.encryptGroupSenderKeyDistribution(
                callId: callId,
                localSecretName: localSecretName,
                fromParticipantId: fromParticipantId,
                toParticipantId: toParticipantId,
                toIdentityProps: props,
                sessionId: sessionId,
                includeHandshakeCiphertext: includeHandshake,
                distribution: distribution
            )
            if includeHandshake {
                e2eeHandshakeSentToParticipantIds.insert(toParticipantId)
            }
            messages.append(encrypted)
        }

        return messages
    }

    /// Convenience: rotates the local sender key and sends per-recipient encrypted sender-key messages
    /// using the existing `RTCTransportEvents.sendCiphertext(...)` callback.
    ///
    /// This keeps group-call key exchange aligned with the 1:1 transport approach: the application
    /// still transports opaque ciphertext blobs, while the SDK owns the Double Ratchet state.
    ///
    /// - Important: This uses `msg.toParticipantId` as the transport recipient and `msg.sessionId.uuidString`
    ///   as the `connectionId` correlation key.
    public func rotateAndSendLocalSenderKeyForCurrentParticipants() async throws {
        let messages = try await rotateAndEncryptLocalSenderKeyForCurrentParticipants()
        for msg in messages {
            let ciphertext = try JSONEncoder().encode(msg)
            try await session.sendCiphertextViaTransport(
                recipient: msg.toParticipantId,
                connectionId: msg.sessionId.uuidString,
                ciphertext: ciphertext,
                call: call)
        }
    }

    /// Convenience: handle inbound sender-key ciphertext delivered via `RTCTransportEvents.sendCiphertext(...)`.
    ///
    /// Your control plane should route these ciphertext blobs to the correct group call instance.
    ///
    /// This method expects `ciphertext` to be the JSON-encoded form of ``RTCGroupE2EE/EncryptedSenderKeyMessage``.
    /// The `fromParticipantId` / `connectionId` parameters are treated as best-effort metadata; the SDK will
    /// not hard-fail if they differ from the decoded payload.
    public func handleCiphertextFromParticipant(
        fromParticipantId: String,
        connectionId: String,
        ciphertext: Data
    ) async throws {
        let message = try JSONDecoder().decode(RTCGroupE2EE.EncryptedSenderKeyMessage.self, from: ciphertext)
        // Best-effort consistency checks.
        if message.fromParticipantId != fromParticipantId {
            // Don't hard-fail; apps may not pass `fromParticipantId` consistently.
        }
        if message.sessionId.uuidString != connectionId {
            // Same rationale: allow decode even if routing metadata differs.
        }
        try await handleEncryptedSenderKeyMessage(message)
    }

    /// Handles an inbound encrypted sender-key distribution message.
    ///
    /// Call this when your transport receives a sender-key distribution message from another participant.
    ///
    /// On success, this applies the decrypted sender key to the underlying session so inbound media frames
    /// from `message.fromParticipantId` can be decrypted.
    ///
    /// - Throws: ``RTCSession/EncryptionErrors`` when required identity/handshake material is missing.
    public func handleEncryptedSenderKeyMessage(_ message: RTCGroupE2EE.EncryptedSenderKeyMessage) async throws {
        guard message.callId == call.sharedCommunicationId else { return }

        // Cache the sessionId by sender so future replies can reuse it if desired.
        if e2eeSessionIdByParticipantId[message.fromParticipantId] == nil {
            e2eeSessionIdByParticipantId[message.fromParticipantId] = message.sessionId
        }

        let localSecretName = call.sender.secretName

        guard let fromProps = identityPropsByParticipantId[message.fromParticipantId] else {
            // Can't decrypt without the sender's identity props.
            throw EncryptionErrors.missingProps
        }

        let dist = try await session.decryptGroupSenderKeyDistribution(
            callId: call.sharedCommunicationId,
            localSecretName: localSecretName,
            fromParticipantId: message.fromParticipantId,
            fromIdentityProps: fromProps,
            message: message
        )

        // Apply for decrypting frames from that sender/participant.
        await session.setFrameEncryptionKey(dist.key, index: dist.keyIndex, for: dist.senderParticipantId)
    }

    private static func randomSymmetricKeyBytes() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - RTCSessionMediaEvents

    /// Notifies the group call that a new inbound remote track was observed.
    ///
    /// This is called by `RTCSession` when Unified Plan receivers appear (typically SFU fan-out).
    public func didAddRemoteTrack(connectionId: String, participantId: String, kind: String, trackId: String) async {
        // Ensure the participant exists in our local view.
        if participantsById[participantId] == nil {
            participantsById[participantId] = Participant(id: participantId)
            eventsContinuation.yield(.participantsUpdated(Array(participantsById.values)))
        }
        eventsContinuation.yield(.remoteTrackAdded(participantId: participantId, kind: kind, trackId: trackId))
    }
}
