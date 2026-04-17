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

    /// Preferred camera `AVCaptureDevice.uniqueID`. Absent or empty means “first available”.
    public static let preferredVideoCaptureDeviceUIDKey = "PQSRTC.preferredVideoCaptureDeviceUID"

    /// Posted after updating ``preferredVideoCaptureDeviceUIDKey`` so an active preview can swap inputs.
    public static let preferredVideoCaptureDeviceDidChangeNotification = Notification.Name("PQSRTC.PreferredVideoCaptureDeviceDidChange")

#if os(macOS)
    /// macOS: preferred input device UID from CoreAudio (`kAudioDevicePropertyDeviceUID`).
    public static let preferredMacAudioInputUIDKey = "PQSRTC.preferredMacAudioInputUID"

    public static let preferredMacAudioInputDidChangeNotification = Notification.Name("PQSRTC.PreferredMacAudioInputDidChange")
#endif
}
