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
    /// Lowest data use; favors continuity over detail on weak networks.
    case low
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
        case .low:
#if os(iOS)
            return AdaptiveConfig(
                minBitrateBps: 120_000,
                maxBitrateBps: 850_000,
                startingBitrateBps: 350_000,
                startingFramerate: 10,
                headroomFactor: 0.55,
                highFpsThresholdBps: 600_000,
                lowFps: 7,
                highFps: 12
            )
#else
            return AdaptiveConfig(
                minBitrateBps: 150_000,
                maxBitrateBps: 1_000_000,
                startingBitrateBps: 450_000,
                startingFramerate: 10,
                headroomFactor: 0.60,
                highFpsThresholdBps: 700_000,
                lowFps: 7,
                highFps: 15
            )
#endif
        case .standard:
#if os(iOS)
            return AdaptiveConfig(
                // iPhone sustained-call default: keep encoder/network work bounded for long rooms.
                minBitrateBps: 150_000,
                maxBitrateBps: 1_500_000,
                startingBitrateBps: 650_000,
                startingFramerate: 15,
                headroomFactor: 0.65,
                highFpsThresholdBps: 1_000_000,
                lowFps: 10,
                highFps: 15
            )
#else
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
#endif
        case .high:
#if os(iOS)
            return AdaptiveConfig(
                minBitrateBps: 200_000,
                maxBitrateBps: 2_200_000,
                startingBitrateBps: 900_000,
                startingFramerate: 15,
                headroomFactor: 0.65,
                highFpsThresholdBps: 1_400_000,
                lowFps: 10,
                highFps: 20
            )
#else
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
#endif
        case .highest:
#if os(iOS)
            return AdaptiveConfig(
                minBitrateBps: 250_000,
                maxBitrateBps: 3_000_000,
                startingBitrateBps: 1_100_000,
                startingFramerate: 20,
                headroomFactor: 0.65,
                highFpsThresholdBps: 1_800_000,
                lowFps: 12,
                highFps: 24
            )
#else
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
#endif
        }
    }

    static func resolutionScaleDownBy(for targetBitrateBps: Int) -> Double {
#if os(Android)
        // Android hardware/WebRTC adaptation is already willing to reduce captured frames. Keep
        // resolution stable longer so good networks do not quickly collapse to soft 360p video.
        if targetBitrateBps < 250_000 { return 4.0 }
        if targetBitrateBps < 500_000 { return 2.0 }
        return 1.0
#else
        if targetBitrateBps < 350_000 { return 4.0 }
        if targetBitrateBps < 900_000 { return 2.0 }
        return 1.0
#endif
    }
}

#if os(iOS)
extension RTCVideoQualityProfile.AdaptiveConfig {
    func adjustedForThermalState(_ state: ProcessInfo.ThermalState) -> Self {
        switch state {
        case .nominal:
            return self
        case .fair:
            return capped(
                maxBitrateBps: 1_100_000,
                startingBitrateBps: 550_000,
                headroomFactor: 0.55,
                lowFps: min(lowFps, 10),
                highFps: min(highFps, 12)
            )
        case .serious:
            return capped(
                maxBitrateBps: 750_000,
                startingBitrateBps: 400_000,
                headroomFactor: 0.45,
                lowFps: min(lowFps, 8),
                highFps: min(highFps, 10)
            )
        case .critical:
            return capped(
                maxBitrateBps: 450_000,
                startingBitrateBps: 300_000,
                headroomFactor: 0.35,
                lowFps: min(lowFps, 5),
                highFps: min(highFps, 8)
            )
        @unknown default:
            return capped(
                maxBitrateBps: 750_000,
                startingBitrateBps: 400_000,
                headroomFactor: 0.45,
                lowFps: min(lowFps, 8),
                highFps: min(highFps, 10)
            )
        }
    }

    private func capped(
        maxBitrateBps capMaxBitrateBps: Int,
        startingBitrateBps capStartingBitrateBps: Int,
        headroomFactor capHeadroomFactor: Double,
        lowFps capLowFps: Int,
        highFps capHighFps: Int
    ) -> Self {
        let nextMax = min(maxBitrateBps, capMaxBitrateBps)
        let nextMin = min(minBitrateBps, nextMax)
        let cappedStarting = min(min(startingBitrateBps, capStartingBitrateBps), nextMax)
        let nextStarting = max(nextMin, cappedStarting)
        let nextLowFps = max(1, capLowFps)
        let nextHighFps = max(nextLowFps, capHighFps)
        return Self(
            minBitrateBps: nextMin,
            maxBitrateBps: nextMax,
            startingBitrateBps: nextStarting,
            startingFramerate: min(startingFramerate, nextHighFps),
            headroomFactor: min(headroomFactor, capHeadroomFactor),
            highFpsThresholdBps: min(highFpsThresholdBps, nextMax),
            lowFps: nextLowFps,
            highFps: nextHighFps
        )
    }
}
#endif
