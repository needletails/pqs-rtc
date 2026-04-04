//
//  CallUIPreferences.swift
//  pqs-rtc
//
//  Shared keys and notifications for host-app call UI preferences (UserDefaults, etc.).
//

import Foundation

public enum PQSRTCCallUIPreferences {
    /// When absent in `UserDefaults`, local preview mirroring defaults to `true` (selfie-style).
    public static let localVideoMirroredUserDefaultsKey = "PQSRTC.localVideoMirrored"

    /// Posted when the host app changes the mirror preference so an active call can refresh capture connections.
    public static let localVideoMirrorPreferenceDidChangeNotification = Notification.Name("PQSRTC.LocalVideoMirrorPreferenceDidChange")
}
