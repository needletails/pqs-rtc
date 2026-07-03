//
//  ScreenShareSystemAudioContract.swift
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

/// Canonical rules for screen-share system-audio egress.
///
/// System audio captured during screen share (ScreenCaptureKit on macOS,
/// ReplayKit `audioApp` on iOS) is mixed into the participant's existing
/// microphone capture pipeline (group-call mid=0). No additional SDP media
/// section, track, or SFU change is introduced — `ScreenShareGroupCallContract`
/// topology is unchanged.
///
/// ## Integration strategy (Phase 0 result)
///
/// The bundled webrtc-sdk XCFramework (needletails/Specs, M144) exposes
/// `RTCDefaultAudioProcessingModule` with a `capturePostProcessingDelegate`
/// that receives each 10 ms capture buffer as writable float channel data.
/// `ScreenShareSystemAudioCapturePostProcessor` adds buffered system-audio
/// samples into those buffers. Mixing happens *after* APM (AEC/AGC/NS), so
/// shared media is not voice-processed.
///
/// ## Rules
///
/// - System audio flows only while screen capture is active **and**
///   `ScreenShareOptions.shareSystemAudio` is true.
/// - Stopping screen share (including unexpected capture termination) must
///   deactivate egress and drop any buffered audio.
/// - The local audio sender must be live for remotes to hear mixed audio. If
///   the user was muted when system-audio sharing started, PQSRTC enables the
///   sender and suppresses mic samples in the capture post-processor so only
///   captured system/app audio is sent.
/// - macOS capture keeps `excludesCurrentProcessAudio = true` so remote
///   playout is never re-captured.
public enum ScreenShareSystemAudioContract: Sendable {

    /// WebRTC processes capture audio in 10 ms steps.
    public static let frameDurationMs = 10

    /// Default capture format requested from ScreenCaptureKit (stereo input).
    /// The mixer target format follows WebRTC's outbound mic capture layout
    /// (mono on macOS ADM) via `audioProcessingInitialize`.
    public static let captureSampleRate = 48_000
    public static let captureChannelCount = 2

    /// Samples per channel in one 10 ms mix chunk at the given rate.
    public static func samplesPerChannelPerFrame(sampleRate: Int) -> Int {
        sampleRate * frameDurationMs / 1_000
    }

    /// Upper bound on buffered (not yet mixed) audio. Older samples are
    /// dropped first so latency stays bounded if the mic capture pipeline
    /// stalls while screen capture keeps producing audio.
    public static let maxBufferedMs = 500

    /// WebRTC `AudioBuffer` float samples use int16 full-scale range
    /// (-32768...32767), not normalized [-1, 1].
    public static let webrtcFloatS16FullScale: Float = 32_768

    /// Gain applied before the final limiter. Keep this conservative because
    /// full-scale app audio clips quickly when mixed into WebRTC's capture path.
    public static let systemAudioMixGain: Float = 1.0
}
