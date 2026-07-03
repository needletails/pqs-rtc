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

    /// When absent in `UserDefaults`, subtle appearance softening defaults to `true`.
    public static let videoAppearanceSofteningUserDefaultsKey = "PQSRTC.videoAppearanceSoftening"

    /// Posted when the host app toggles appearance softening during an active call.
    public static let videoAppearanceSofteningPreferenceDidChangeNotification = Notification.Name("PQSRTC.VideoAppearanceSofteningPreferenceDidChange")

    /// Reads ``videoAppearanceSofteningUserDefaultsKey``; missing key defaults to `true`.
    public static func resolvedVideoAppearanceSofteningEnabled() -> Bool {
        let key = videoAppearanceSofteningUserDefaultsKey
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Reads ``localVideoMirroredUserDefaultsKey``; missing key defaults to `true`.
    public static func resolvedLocalVideoMirroredEnabled() -> Bool {
        let key = localVideoMirroredUserDefaultsKey
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

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
