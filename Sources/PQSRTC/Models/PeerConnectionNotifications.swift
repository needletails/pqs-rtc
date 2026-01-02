//
//  PeerConnectionNotifications.swift
//  pqs-rtc
//
//  Created by Cole M on 10/4/25.
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

/// High-level WebRTC/PeerConnection notifications emitted by `RTCSession`.
///
/// These notifications are primarily intended for:
/// - Debugging and analytics (ICE/signaling transitions, negotiation triggers)
/// - UI coordination in the sample/host app (stream add/remove, data channel activity)
/// - SFU-style calls, where Unified Plan receiver events must be surfaced with stream/track identifiers
///
/// Most applications will observe these via the session’s notification stream and then
/// react at a higher level (e.g. update UI, route candidates over your transport).
public enum PeerConnectionNotifications: Sendable {
    /// ICE gathering state changed for a given connection.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - state: The new ICE gathering state.
    case iceGatheringDidChange(String, SPTIceGatheringState)

    /// SDP signaling state changed for a given connection.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - state: The new signaling state.
    case signalingStateDidChange(String, SPTSignalingState)

    /// A media stream was added.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - streamId: The WebRTC media stream identifier.
    case addedStream(String, String)

    /// A media stream was removed.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - streamId: The WebRTC media stream identifier.
    case removedStream(String, String)

    /// Unified Plan track event: a receiver was added along with its associated media streams.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection ID
    ///   - trackKind: Track kind (e.g. "audio", "video")
    ///   - streamIds: Associated media stream IDs (often used as a participant identifier in SFU/conference calls)
    ///   - trackId: Track identifier for debugging/mapping
    case didAddReceiver(String, String, [String], String)

    /// ICE connection state changed for a given connection.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - state: The new ICE connection state.
    case iceConnectionStateDidChange(String, SPTIceConnectionState)

    /// An ICE candidate was generated.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - sdp: Candidate SDP string.
    ///   - sdpMLineIndex: Candidate m-line index.
    ///   - sdpMid: Candidate mid, if available.
    case generatedIceCandidate(String, String, Int32, String?)

    /// Standardized ICE connection state changed.
    ///
    /// Some platforms expose both a legacy and standardized ICE state; this event allows
    /// consumers to observe the standardized variant.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - state: The new standardized ICE connection state.
    case standardizedIceConnectionState(String, SPTIceConnectionState)

    /// ICE candidates were removed.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - count: Number of candidates removed.
    case removedIceCandidates(String, Int)

    /// Indicates the connection started receiving media.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - streamId: Stream identifier associated with receiving.
    case startedReceiving(String, String)

    /// A data channel was created/opened.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - label: The data channel label.
    case dataChannel(String, String)

    /// A data channel message was received.
    ///
    /// - Parameters:
    ///   - connectionId: The owning connection identifier.
    ///   - label: The data channel label.
    ///   - data: The raw message payload.
    case dataChannelMessage(String, String, Data)

    /// The PeerConnection indicates negotiation is needed.
    ///
    /// - Parameter connectionId: The owning connection identifier.
    case shouldNegotiate(String)
}
