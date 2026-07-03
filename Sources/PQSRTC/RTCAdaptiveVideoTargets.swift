//
//  RTCAdaptiveVideoTargets.swift
//  pqs-rtc
//
//  Pure helpers for SFU adaptive video sender targets (Apple + Android).
//

import Foundation

/// Sender encoding targets derived from bandwidth signals and quality profile.
struct AdaptiveVideoTargets: Sendable, Equatable {
    let maxBitrateBps: Int
    let maxFramerate: Int
    let scaleResolutionDownBy: Double
}

enum RTCAdaptiveVideoTargets {

    /// Minimum fraction of `startingBitrateBps` used when TURN under-reports `availableOutgoingBitrate`.
    static let oneToOneRelayBandwidthFloorFactor = 0.45
    static let survivalBitrateBps = 120_000
    static let survivalFramerate = 7
    static let survivalScaleResolutionDownBy = 4.0

    /// Computes adaptive sender targets from WebRTC candidate-pair bandwidth.
    ///
    /// TURN/relay paths often report pessimistic `availableOutgoingBitrate` while audio and video
    /// are otherwise stable. For 1:1 SFU calls we apply a conservative floor so steady camera calls
    /// are not capped at slideshow fps when the link is usable.
    static func compute(
        cfg: RTCVideoQualityProfile.AdaptiveConfig,
        isOneToOneSfu: Bool,
        reportedAvailableOutgoingBps: Double,
        currentRttSeconds: Double?
    ) -> AdaptiveVideoTargets {
        if shouldUseSurvivalMode(
            reportedAvailableOutgoingBps: reportedAvailableOutgoingBps,
            currentRttSeconds: currentRttSeconds
        ) {
            return survivalTargets(cfg: cfg)
        }

        var headroom = cfg.headroomFactor
        if let rtt = currentRttSeconds {
            if rtt >= 0.70 {
                headroom = min(headroom, 0.55)
            } else if rtt >= 0.35 {
                headroom = min(headroom, 0.65)
            }
        }

        var available = reportedAvailableOutgoingBps
        if isOneToOneSfu, shouldApplyOneToOneRelayFloor(
            reportedAvailableOutgoingBps: reportedAvailableOutgoingBps,
            currentRttSeconds: currentRttSeconds
        ) {
            available = max(available, Double(cfg.startingBitrateBps) * oneToOneRelayBandwidthFloorFactor)
        }

        let rawTarget = Int(available * headroom)
        let targetBps = max(cfg.minBitrateBps, min(cfg.maxBitrateBps, rawTarget))
        let targetFps = (targetBps >= cfg.highFpsThresholdBps) ? cfg.highFps : cfg.lowFps
        let targetScale = RTCVideoQualityProfile.resolutionScaleDownBy(
            for: targetBps,
            isOneToOneSfu: isOneToOneSfu
        )

        return AdaptiveVideoTargets(
            maxBitrateBps: targetBps,
            maxFramerate: targetFps,
            scaleResolutionDownBy: targetScale
        )
    }

    static func conservativeStartupTargets(
        cfg: RTCVideoQualityProfile.AdaptiveConfig,
        isOneToOneSfu: Bool
    ) -> AdaptiveVideoTargets {
        let targetBps = max(cfg.minBitrateBps, min(cfg.startingBitrateBps, isOneToOneSfu ? 450_000 : 350_000))
        return AdaptiveVideoTargets(
            maxBitrateBps: targetBps,
            maxFramerate: min(cfg.startingFramerate, cfg.lowFps),
            scaleResolutionDownBy: RTCVideoQualityProfile.resolutionScaleDownBy(
                for: targetBps,
                isOneToOneSfu: isOneToOneSfu
            )
        )
    }

    static func survivalTargets(cfg: RTCVideoQualityProfile.AdaptiveConfig) -> AdaptiveVideoTargets {
        AdaptiveVideoTargets(
            maxBitrateBps: max(80_000, min(cfg.maxBitrateBps, survivalBitrateBps)),
            maxFramerate: min(cfg.lowFps, survivalFramerate),
            scaleResolutionDownBy: survivalScaleResolutionDownBy
        )
    }

    private static func shouldUseSurvivalMode(
        reportedAvailableOutgoingBps: Double,
        currentRttSeconds: Double?
    ) -> Bool {
        if reportedAvailableOutgoingBps < 80_000 { return true }
        if reportedAvailableOutgoingBps < 150_000, (currentRttSeconds ?? 0.35) >= 0.35 { return true }
        if reportedAvailableOutgoingBps <= 300_000, let rtt = currentRttSeconds, rtt >= 0.35 { return true }
        return false
    }

    private static func shouldApplyOneToOneRelayFloor(
        reportedAvailableOutgoingBps: Double,
        currentRttSeconds: Double?
    ) -> Bool {
        if reportedAvailableOutgoingBps < 150_000, (currentRttSeconds ?? 0) >= 0.35 {
            return false
        }
        if let rtt = currentRttSeconds, rtt >= 0.35 {
            return false
        }
        return true
    }

    /// Returns true when a new plan differs enough from the last applied settings to avoid thrashing.
    static func shouldApply(
        _ targets: AdaptiveVideoTargets,
        lastApplied: (bitrateBps: Int, framerate: Int, scaleResolutionDownBy: Double)?
    ) -> Bool {
        guard let last = lastApplied else { return true }
        if last.bitrateBps == 0 { return true }
        let bitrateDelta = targets.maxBitrateBps - last.bitrateBps
        let ratio = Double(abs(bitrateDelta)) / Double(max(1, last.bitrateBps))
        let bitrateChangedEnough = bitrateDelta < 0 ? ratio >= 0.05 : ratio >= 0.25
        return bitrateChangedEnough
            || targets.maxFramerate < last.framerate
            || abs(targets.scaleResolutionDownBy - last.scaleResolutionDownBy) >= 0.25
    }
}

extension RTCSession {
    /// Profile-derived adaptive config for an SFU call (1:1 overlay applied when applicable).
    func sfuAdaptiveConfig(for call: Call) -> RTCVideoQualityProfile.AdaptiveConfig {
        sfuVideoQualityProfile.sfuAdaptiveConfig(
            oneToOneSfu: Self.isTrueOneToOneSfuRoom(call: call)
        )
    }
}
