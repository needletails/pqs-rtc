//
//  RTCSessionMediaEvents.swift
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

/// Media events emitted by a call/session.
///
/// This protocol is used as a minimal, transport-agnostic surface for notifying the application
/// (or higher-level wrappers like `RTCGroupCall`) about remote media track availability.
public protocol RTCSessionMediaEvents: Sendable {
    /// Called when a remote track is added for a participant.
    ///
    /// - Parameters:
    ///   - connectionId: The underlying PeerConnection/RTCConnection ID.
    ///   - participantId: Participant identifier (for SFU calls this is typically derived from streamId).
    ///   - kind: Track kind ("audio" or "video").
    ///   - trackId: WebRTC track identifier.
    func didAddRemoteTrack(connectionId: String, participantId: String, kind: String, trackId: String) async
}
