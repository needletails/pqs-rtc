//
//  ScreenShareSystemAudioEgress.swift
//  pqs-rtc
//
//  Copyright (c) 2026 NeedleTails Organization.
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

/// Sink for captured screen-share system audio.
///
/// Capture sources (`MacScreenCaptureSource`, `iOSScreenCaptureSource`) own an
/// egress for the lifetime of one capture session: `activate()` before audio
/// starts flowing, `push(_:)` per captured frame, `deactivate()` on every stop
/// path (including unexpected capture termination).
protocol ScreenShareSystemAudioEgress: AnyObject, Sendable {
    func activate()
    func push(_ frame: ScreenSharePCMFrame)
    func deactivate()
}

/// Discards all audio. Used when system-audio sharing is disabled.
final class NoOpScreenShareSystemAudioEgress: ScreenShareSystemAudioEgress {
    init() {}
    func activate() {}
    func push(_ frame: ScreenSharePCMFrame) {}
    func deactivate() {}
}
