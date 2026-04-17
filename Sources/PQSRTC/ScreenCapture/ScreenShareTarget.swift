//
//  ScreenShareTarget.swift
//  pqs-rtc
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

/// Describes what the user chose to share.
///
/// macOS offers full-screen or single-window capture; iOS and Android capture
/// the entire device screen (via ReplayKit / MediaProjection).
public enum ScreenShareTarget: Sendable {
    /// Share an entire display (macOS). `displayID` matches `CGDirectDisplayID`.
    case entireScreen(displayID: UInt32)
    /// Share a single application window (macOS).
    case window(windowID: UInt32, title: String)
    /// Share the app's own screen via ReplayKit (iOS).
    case appScreen
    /// Share the device screen via MediaProjection (Android).
    case androidScreen
}

/// Fired by ``RTCSession/remoteScreenTrackStream()`` whenever a remote participant
/// starts or stops sharing their screen.
public struct RemoteScreenTrackEvent: Sendable {
    /// The peer connection identifier.
    public let connectionId: String
    /// The participant who is sharing (derived from stream/track ID prefixes).
    ///
    /// For streams that do not carry participant identity metadata, this may fall
    /// back to ``connectionId``.
    public let participantId: String
    /// `true` when screen sharing started, `false` when it stopped.
    public let isActive: Bool

    public init(connectionId: String, participantId: String, isActive: Bool) {
        self.connectionId = connectionId
        self.participantId = participantId
        self.isActive = isActive
    }
}

/// Fired by ``RTCSession/remoteParticipantTrackStream()`` when a remote participant's
/// camera video track is added or removed. The Android controller subscribes to this
/// stream to dynamically assign ``AndroidSampleCaptureView`` instances to participants.
public struct RemoteParticipantTrackEvent: Sendable {
    public let connectionId: String
    public let participantId: String
    /// Media kind, e.g. `"video"` or `"audio"`.
    public let kind: String
    /// `true` when the track was added, `false` when removed.
    public let isActive: Bool

    public init(connectionId: String, participantId: String, kind: String, isActive: Bool) {
        self.connectionId = connectionId
        self.participantId = participantId
        self.kind = kind
        self.isActive = isActive
    }
}
