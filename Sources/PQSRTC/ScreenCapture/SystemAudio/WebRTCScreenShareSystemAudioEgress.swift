//
//  WebRTCScreenShareSystemAudioEgress.swift
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

#if canImport(WebRTC) && !os(Android)
import Foundation

/// Routes captured system audio into the session-wide capture post-processor
/// so it is mixed into the outbound microphone track (group-call mid=0).
final class WebRTCScreenShareSystemAudioEgress: ScreenShareSystemAudioEgress {

    private let mixer: ScreenShareSystemAudioMixer

    init(processor: ScreenShareSystemAudioCapturePostProcessor) {
        self.mixer = processor.mixer
    }

    func activate() {
        mixer.activate()
    }

    func push(_ frame: ScreenSharePCMFrame) {
        mixer.push(frame)
    }

    func deactivate() {
        mixer.deactivate()
    }
}
#endif
