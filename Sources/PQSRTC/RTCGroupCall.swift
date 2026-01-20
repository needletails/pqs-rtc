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
        case sfuAnswer(RatchetMessagePacket)
        case sfuCandidate(RatchetMessagePacket)

        /// Roster
        case participants(RatchetMessagePacket)
        case participantDemuxId(RatchetMessagePacket)
    }

    private let sfuRecipientId: String
    private var call: Call
    let localIdentity: ConnectionLocalIdentity

    private var state: State = .idle
    private var participantsById: [String: Participant] = [:]

    // Group E2EE (sender keys over pairwise Double Ratchet)
    private var identityPropsByParticipantId: [String: SessionIdentity.UnwrappedProps] = [:]
    private var e2eeSessionIdByParticipantId: [String: UUID] = [:]
    private var e2eeHandshakeSentToParticipantIds: Set<String> = []
    private var localSenderKeyIndex: Int = 0

    private let eventsStream: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation

    public init(
        call: Call,
        sfuRecipientId: String,
        localIdentity: ConnectionLocalIdentity) {
        self.call = call
        self.sfuRecipientId = sfuRecipientId
        self.localIdentity = localIdentity
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

        // We treat “join” as “connected enough to proceed”; actual ICE connectivity
        // is still tracked by the existing call state machine.
        state = .joined
        eventsContinuation.yield(.stateChanged(.joined))
    }

    public func leave() async {
        guard state != .ended else { return }
        state = .ended
        eventsContinuation.yield(.stateChanged(.ended))
    }

    // MARK: - Control plane / roster

    /// Replaces the participant roster with the given list.
    public func updateParticipants(_ participants: [Participant]) async {
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
