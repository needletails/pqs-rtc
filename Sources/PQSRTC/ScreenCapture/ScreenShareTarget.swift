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

/// User-selected screen sharing preferences.
public struct ScreenShareOptions: Sendable, Equatable {
    public var shareSystemAudio: Bool
    public var optimizeForVideo: Bool

    public init(
        shareSystemAudio: Bool = false,
        optimizeForVideo: Bool = false
    ) {
        self.shareSystemAudio = shareSystemAudio
        self.optimizeForVideo = optimizeForVideo
    }
}

/// Control payload for ``PacketFlag/screenSharePreempt``.
public struct ScreenSharePreemptCommand: Codable, Sendable, Equatable {
    /// Secret name of the participant who must stop screen sharing.
    public var targetParticipantSecretName: String

    public init(targetParticipantSecretName: String) {
        self.targetParticipantSecretName = targetParticipantSecretName
    }
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
/// participant-camera track is added or removed. The `kind` field is generic so future
/// media events can share the same shape, but the built-in video-call controllers subscribe
/// to `"video"` events to assign renderers.
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

/// Fired by ``RTCSession/e2eeStateStream()`` when frame encryption fails or recovers.
public struct E2EEStateEvent: Sendable {
    public enum Kind: String, Sendable {
        case senderCryptorFailed
        case senderCryptorReady
        /// Receiver cryptor exceeded the decrypt failure tolerance (H1); media from
        /// `participantId` is being discarded until a fresh key is installed.
        case receiverDecryptionFailed
        /// Receiver cryptor has no key for `participantId` while encrypted media arrives.
        case receiverMissingKey
        /// Receiver cryptor returned to OK after a failure state.
        case receiverRecovered
    }

    public let connectionId: String
    public let kind: Kind
    /// Media leg, e.g. `"audio"`, `"video"`, `"screen"`, or `"sender"`.
    public let mediaKind: String
    public let reason: String
    /// Remote participant whose cryptor changed state (receiver kinds only).
    public let participantId: String

    public init(
        connectionId: String,
        kind: Kind,
        mediaKind: String,
        reason: String = "",
        participantId: String = ""
    ) {
        self.connectionId = connectionId
        self.kind = kind
        self.mediaKind = mediaKind
        self.reason = reason
        self.participantId = participantId
    }
}

/// One coordinated Android tile-attach episode after SFU renegotiation settles.
///
/// Emitted once per rebound batch so the call UI can bind every affected participant from live
/// peer-connection receivers in a single pass instead of racing `participant-track-refresh`,
/// grid relayout, and inbound-render recovery.
public struct PostSfuRenegotiationAttachEpisode: Sendable {
    public let connectionId: String
    public let participantIds: [String]

    public init(connectionId: String, participantIds: [String]) {
        self.connectionId = connectionId
        self.participantIds = participantIds
    }
}
