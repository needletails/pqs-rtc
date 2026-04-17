//
//  ConferencePermissions.swift
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

/// IRC-rooted conference role hierarchy.
///
/// Maps directly to IRC channel modes:
/// - Admin (`O`) -> Host
/// - Operator (`o`) -> Cohost
/// - Voice (`v`) -> Presenter
/// - (none) -> Viewer
public enum ConferenceRole: String, Codable, Sendable, Comparable, CaseIterable {
    case host
    case cohost
    case presenter
    case viewer

    private var privilege: Int {
        switch self {
        case .host: return 3
        case .cohost: return 2
        case .presenter: return 1
        case .viewer: return 0
        }
    }

    public static func < (lhs: ConferenceRole, rhs: ConferenceRole) -> Bool {
        lhs.privilege < rhs.privilege
    }
}

/// Actions that can be permission-gated in a conference call.
public enum ConferencePermissionAction: String, Codable, Sendable {
    case screenShare
}

/// Tracks the local user's role and all participant roles for a conference/group call.
public struct ConferencePermissions: Sendable, Equatable {
    public var localRole: ConferenceRole
    public var participantRoles: [String: ConferenceRole]

    public init(localRole: ConferenceRole = .viewer, participantRoles: [String: ConferenceRole] = [:]) {
        self.localRole = localRole
        self.participantRoles = participantRoles
    }

    public var canScreenShare: Bool { localRole >= .presenter }
    public var canMuteOthers: Bool { localRole >= .cohost }
    public var canKick: Bool { localRole >= .cohost }
    public var canChangeRoles: Bool { localRole >= .cohost }
    public var isHost: Bool { localRole == .host }

    /// Derives a `ConferenceRole` from IRC member flags.
    public static func role(
        isChannelAdminOperator: Bool,
        isChannelOperator: Bool,
        isVoiceUser: Bool
    ) -> ConferenceRole {
        if isChannelAdminOperator { return .host }
        if isChannelOperator { return .cohost }
        if isVoiceUser { return .presenter }
        return .viewer
    }
}
