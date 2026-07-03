import Foundation
import Testing
@testable import PQSRTC

@Suite("RTCAdaptiveVideoTargets")
struct RTCAdaptiveVideoTargetsTests {

    @Test("1:1 SFU floor prevents TURN pessimism from capping at min bitrate")
    func oneToOneRelayFloor() {
        let cfg = RTCVideoQualityProfile.standard.sfuAdaptiveConfig(oneToOneSfu: true)
        let targets = RTCAdaptiveVideoTargets.compute(
            cfg: cfg,
            isOneToOneSfu: true,
            reportedAvailableOutgoingBps: 90_000,
            currentRttSeconds: 0.13
        )
        #expect(targets.maxFramerate >= 20)
        #expect(targets.maxBitrateBps >= cfg.minBitrateBps)
        #expect(targets.scaleResolutionDownBy <= 2.0)
    }

    @Test("Multi-party call enters survival mode below normal profile minimum")
    func multiPartyUsesReportedBandwidth() {
        let cfg = RTCVideoQualityProfile.standard.adaptiveConfig
        let targets = RTCAdaptiveVideoTargets.compute(
            cfg: cfg,
            isOneToOneSfu: false,
            reportedAvailableOutgoingBps: 90_000,
            currentRttSeconds: nil
        )
        #expect(targets.maxBitrateBps < cfg.minBitrateBps)
        #expect(targets.maxFramerate <= 7)
        #expect(targets.scaleResolutionDownBy == 4.0)
    }

    @Test("1:1 SFU disables optimistic floor on high RTT survival paths")
    func oneToOneRelayFloorDisabledOnHighRtt() {
        let cfg = RTCVideoQualityProfile.standard.sfuAdaptiveConfig(oneToOneSfu: true)
        let targets = RTCAdaptiveVideoTargets.compute(
            cfg: cfg,
            isOneToOneSfu: true,
            reportedAvailableOutgoingBps: 300_000,
            currentRttSeconds: 0.49
        )
        #expect(targets.maxBitrateBps <= RTCAdaptiveVideoTargets.survivalBitrateBps)
        #expect(targets.maxFramerate <= RTCAdaptiveVideoTargets.survivalFramerate)
        #expect(targets.scaleResolutionDownBy == RTCAdaptiveVideoTargets.survivalScaleResolutionDownBy)
    }

    @Test("High fps tier activates at lowered threshold on standard profile")
    func highFpsThreshold() {
        let cfg = RTCVideoQualityProfile.standard.adaptiveConfig
        let targets = RTCAdaptiveVideoTargets.compute(
            cfg: cfg,
            isOneToOneSfu: false,
            reportedAvailableOutgoingBps: 800_000,
            currentRttSeconds: nil
        )
        #expect(targets.maxFramerate == cfg.highFps)
    }

    @Test("1:1 overlay elevates iOS standard fps floor")
    func oneToOneOverlay() {
        let cfg = RTCVideoQualityProfile.standard.sfuAdaptiveConfig(oneToOneSfu: true)
#if os(iOS)
        #expect(cfg.lowFps >= 20)
        #expect(cfg.highFps >= 24)
        #expect(cfg.highFpsThresholdBps <= 400_000)
#else
        #expect(cfg.lowFps >= 18)
        #expect(cfg.highFps >= 30)
#endif
    }

    @Test("shouldApply avoids thrashing on small bitrate changes")
    func shouldApplyThreshold() {
        let targets = AdaptiveVideoTargets(maxBitrateBps: 700_000, maxFramerate: 24, scaleResolutionDownBy: 1.0)
        let last = (bitrateBps: 650_000, framerate: 24, scaleResolutionDownBy: 1.0)
        #expect(RTCAdaptiveVideoTargets.shouldApply(targets, lastApplied: last) == false)
        #expect(
            RTCAdaptiveVideoTargets.shouldApply(
                AdaptiveVideoTargets(maxBitrateBps: 500_000, maxFramerate: 24, scaleResolutionDownBy: 1.0),
                lastApplied: last
            )
        )
        #expect(
            RTCAdaptiveVideoTargets.shouldApply(
                AdaptiveVideoTargets(maxBitrateBps: 770_000, maxFramerate: 24, scaleResolutionDownBy: 1.0),
                lastApplied: (bitrateBps: 700_000, framerate: 24, scaleResolutionDownBy: 1.0)
            ) == false
        )
        #expect(
            RTCAdaptiveVideoTargets.shouldApply(
                AdaptiveVideoTargets(maxBitrateBps: 630_000, maxFramerate: 24, scaleResolutionDownBy: 1.0),
                lastApplied: (bitrateBps: 700_000, framerate: 24, scaleResolutionDownBy: 1.0)
            )
        )
    }
}
