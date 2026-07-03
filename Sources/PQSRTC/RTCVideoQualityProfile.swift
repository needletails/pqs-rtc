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

    /// Base adaptive config for the selected profile (multi-party SFU / group defaults).
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
                minBitrateBps: 200_000,
                maxBitrateBps: 1_500_000,
                startingBitrateBps: 700_000,
                startingFramerate: 20,
                headroomFactor: 0.65,
                highFpsThresholdBps: 450_000,
                lowFps: 15,
                highFps: 24
            )
#else
            return AdaptiveConfig(
                minBitrateBps: 200_000,
                maxBitrateBps: 4_000_000,
                startingBitrateBps: 1_200_000,
                startingFramerate: 20,
                headroomFactor: 0.75,
                highFpsThresholdBps: 600_000,
                lowFps: 15,
                highFps: 30
            )
#endif
        case .high:
#if os(iOS)
            return AdaptiveConfig(
                minBitrateBps: 250_000,
                maxBitrateBps: 2_200_000,
                startingBitrateBps: 900_000,
                startingFramerate: 24,
                headroomFactor: 0.65,
                highFpsThresholdBps: 600_000,
                lowFps: 18,
                highFps: 24
            )
#else
            return AdaptiveConfig(
                minBitrateBps: 300_000,
                maxBitrateBps: 6_000_000,
                startingBitrateBps: 1_800_000,
                startingFramerate: 30,
                headroomFactor: 0.75,
                highFpsThresholdBps: 1_200_000,
                lowFps: 15,
                highFps: 30
            )
#endif
        case .highest:
#if os(iOS)
            return AdaptiveConfig(
                minBitrateBps: 300_000,
                maxBitrateBps: 3_000_000,
                startingBitrateBps: 1_100_000,
                startingFramerate: 24,
                headroomFactor: 0.65,
                highFpsThresholdBps: 800_000,
                lowFps: 20,
                highFps: 30
            )
#else
            return AdaptiveConfig(
                minBitrateBps: 400_000,
                maxBitrateBps: 8_000_000,
                startingBitrateBps: 2_500_000,
                startingFramerate: 30,
                headroomFactor: 0.75,
                highFpsThresholdBps: 1_800_000,
                lowFps: 15,
                highFps: 30
            )
#endif
        }
    }

    /// Adaptive config for an SFU room, optionally elevated for ephemeral 2-person calls.
    func sfuAdaptiveConfig(oneToOneSfu: Bool) -> AdaptiveConfig {
        guard oneToOneSfu else { return adaptiveConfig }
        return adaptiveConfig.elevatedForOneToOneSfu()
    }

    static func resolutionScaleDownBy(for targetBitrateBps: Int, isOneToOneSfu: Bool = false) -> Double {
        if isOneToOneSfu {
#if os(Android)
            if targetBitrateBps < 200_000 { return 4.0 }
            if targetBitrateBps < 400_000 { return 2.0 }
#else
            if targetBitrateBps < 220_000 { return 4.0 }
            if targetBitrateBps < 550_000 { return 2.0 }
#endif
            return 1.0
        }
#if os(Android)
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

extension RTCVideoQualityProfile.AdaptiveConfig {
    /// Elevated ceilings for ephemeral 2-person SFU calls (camera 1:1 routed through the SFU).
    fileprivate func elevatedForOneToOneSfu() -> Self {
#if os(iOS)
        return Self(
            minBitrateBps: max(minBitrateBps, 300_000),
            maxBitrateBps: max(maxBitrateBps, 2_200_000),
            startingBitrateBps: max(startingBitrateBps, 900_000),
            startingFramerate: max(startingFramerate, 24),
            headroomFactor: max(headroomFactor, 0.68),
            highFpsThresholdBps: min(highFpsThresholdBps, 400_000),
            lowFps: max(lowFps, 20),
            highFps: max(highFps, 24)
        )
#elseif os(Android)
        return Self(
            minBitrateBps: max(minBitrateBps, 300_000),
            maxBitrateBps: max(maxBitrateBps, 4_000_000),
            startingBitrateBps: max(startingBitrateBps, 1_200_000),
            startingFramerate: max(startingFramerate, 24),
            headroomFactor: max(headroomFactor, 0.72),
            highFpsThresholdBps: min(highFpsThresholdBps, 500_000),
            lowFps: max(lowFps, 18),
            highFps: max(highFps, 30)
        )
#else
        return Self(
            minBitrateBps: max(minBitrateBps, 350_000),
            maxBitrateBps: max(maxBitrateBps, 5_000_000),
            startingBitrateBps: max(startingBitrateBps, 1_500_000),
            startingFramerate: max(startingFramerate, 24),
            headroomFactor: max(headroomFactor, 0.72),
            highFpsThresholdBps: min(highFpsThresholdBps, 600_000),
            lowFps: max(lowFps, 20),
            highFps: max(highFps, 30)
        )
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
                lowFps: min(lowFps, 12),
                highFps: min(highFps, 18)
            )
        case .serious:
            return capped(
                maxBitrateBps: 750_000,
                startingBitrateBps: 400_000,
                headroomFactor: 0.45,
                lowFps: min(lowFps, 10),
                highFps: min(highFps, 15)
            )
        case .critical:
            return capped(
                maxBitrateBps: 450_000,
                startingBitrateBps: 300_000,
                headroomFactor: 0.35,
                lowFps: min(lowFps, 8),
                highFps: min(highFps, 12)
            )
        @unknown default:
            return capped(
                maxBitrateBps: 750_000,
                startingBitrateBps: 400_000,
                headroomFactor: 0.45,
                lowFps: min(lowFps, 10),
                highFps: min(highFps, 15)
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
