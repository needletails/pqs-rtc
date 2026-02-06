//
//  RTCVideoQualityProfile.swift
//  pqs-rtc
//
//  SFU/group-call video quality presets.
//

import Foundation

/// Video quality profile used to tune SFU/group-call sender behavior.
///
/// Notes:
/// - These are **sender-side ceilings**; WebRTC congestion control still adapts below them.
/// - `swift-sfu` does not transcode; selecting a higher profile allows higher quality on good uplink,
///   while the adaptive loop still backs off on bad uplink.
public enum RTCVideoQualityProfile: Sendable, Equatable {
    /// Balanced defaults suitable for most networks (good quality, robust on poor uplink).
    case standard
    /// Higher ceiling for consistently strong uplinks (e.g. Wi‑Fi).
    case high
    /// Highest practical ceiling (best quality on great uplink; may stress weak uplinks more).
    case highest
}

extension RTCVideoQualityProfile {
    struct AdaptiveConfig: Sendable {
        /// Minimum bitrate cap applied (keeps video alive on poor uplink).
        let minBitrateBps: Int
        /// Maximum bitrate cap applied (allows high quality on strong uplink).
        let maxBitrateBps: Int
        /// Initial ceiling applied before stats are available.
        let startingBitrateBps: Int
        let startingFramerate: Int
        /// How much of `availableOutgoingBitrate` we are willing to use.
        let headroomFactor: Double
        /// Switch to high fps once above this ceiling.
        let highFpsThresholdBps: Int
        let lowFps: Int
        let highFps: Int
    }

    var adaptiveConfig: AdaptiveConfig {
        switch self {
        case .standard:
            return AdaptiveConfig(
                // Allow survival on truly poor uplinks. WebRTC will still adapt below ceilings.
                // Keeping this too high causes "freeze until keyframe" symptoms on slow/latent internet.
                minBitrateBps: 200_000,
                maxBitrateBps: 4_000_000,
                startingBitrateBps: 1_200_000,
                startingFramerate: 15,
                headroomFactor: 0.75,
                highFpsThresholdBps: 1_800_000,
                // Lower FPS is more resilient under loss/jitter and reduces decoder pressure.
                lowFps: 10,
                highFps: 30
            )
        case .high:
            return AdaptiveConfig(
                minBitrateBps: 300_000,
                maxBitrateBps: 6_000_000,
                startingBitrateBps: 1_800_000,
                startingFramerate: 30,
                headroomFactor: 0.75,
                highFpsThresholdBps: 2_200_000,
                lowFps: 10,
                highFps: 30
            )
        case .highest:
            return AdaptiveConfig(
                minBitrateBps: 400_000,
                maxBitrateBps: 8_000_000,
                startingBitrateBps: 2_500_000,
                startingFramerate: 30,
                headroomFactor: 0.75,
                highFpsThresholdBps: 2_800_000,
                lowFps: 10,
                highFps: 30
            )
        }
    }
}

