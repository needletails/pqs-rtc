//
//  ViewDelegation.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
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

/// User-initiated call controls.
///
/// A host application (or controller) implements this protocol to handle UI actions such as
/// ending a call or toggling audio/video mute.
public protocol CallActionDelegate: AnyObject, Sendable {
    /// Ends the call.
    func endCall() async

    /// Mutes or unmutes the local microphone.
    func muteAudio() async

    /// Mutes or unmutes the local camera/video track.
    func muteVideo() async

    /// Requests entering or exiting picture-in-picture.
    ///
    /// The default implementation is a no-op.
    func showPictureInPicture(_ show: Bool) async

    /// Starts screen sharing with the given target.
    func startScreenShare(target: ScreenShareTarget) async

    /// Stops the active screen share.
    func stopScreenShare() async
}

// Provide default no-op implementations for platform-specific actions
public extension CallActionDelegate {
    /// Toggles speakerphone routing when supported by the platform.
    ///
    /// This is intentionally not a protocol requirement because it is not available or meaningful
    /// on every platform.
    func toggleSpeakerPhone() {}

    /// Default no-op PiP implementation.
    func showPictureInPicture(_ show: Bool) async {}

    func startScreenShare(target: ScreenShareTarget) async {}
    func stopScreenShare() async {}
}

/// Internal receiver for picture-in-picture events.
protocol PiPEventReceiverDelegate: AnyObject, Sendable {
    func passPause(_ bool: Bool)
}


/// Call-state updates delivered to UI components.
///
/// The SDK uses this delegate to push state transitions and recoverable error messages to the UI.
public protocol VideoCallDelegate: AnyObject, Sendable {
    /// Delivers a human-readable error message intended for user display.
    func passErrorMessage(_ message: String) async

    /// Delivers the current high-level call state.
    func deliverCallState(_ state: CallStateMachine.State) async

    /// Indicates that a call has ended (or is considered ended by the UI layer).
    func endedCall(_ didEnd: Bool) async

    /// Pushes the controller’s mic/camera mute flags to SwiftUI chrome (see ``VideoCallViewControllerRepresentable``).
    ///
    /// Default implementation is a no-op for hosts that do not mirror mute into `@State`.
    func localMuteDisplayDidChange(videoMuted: Bool, audioMuted: Bool) async

    /// Called when the local screen sharing state changes.
    func screenShareDidChange(isSharing: Bool) async

    /// Called when a remote participant starts or stops sharing their screen.
    func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async

    /// Called when conference permissions change (roles updated by server).
    func conferencePermissionsDidChange(_ permissions: ConferencePermissions) async

    /// Called when a permission request is received from another participant (host/cohost sees this).
    func permissionRequestReceived(from participant: String, action: ConferencePermissionAction) async
#if os(macOS)
    /// Provides the updated view size (macOS only).
    func passSize(_ size: NSSize) async
#endif
}

public extension VideoCallDelegate {
    func localMuteDisplayDidChange(videoMuted: Bool, audioMuted: Bool) async {}
    func screenShareDidChange(isSharing: Bool) async {}
    func remoteScreenShareDidChange(participantId: String, isSharing: Bool) async {}
    func conferencePermissionsDidChange(_ permissions: ConferencePermissions) async {}
    func permissionRequestReceived(from participant: String, action: ConferencePermissionAction) async {}
}
