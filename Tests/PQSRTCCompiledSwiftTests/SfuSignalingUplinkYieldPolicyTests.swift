import Foundation
import Testing
@testable import PQSRTC

@Suite("SFU signaling uplink yield")
struct SfuSignalingUplinkYieldPolicyTests {
    @Test("count never goes negative")
    func countNeverNegative() {
        #expect(SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: 0,
            event: .completed) == 0)
        #expect(SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: 0,
            event: .cancelled) == 0)
        #expect(SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: 0,
            event: .failed) == 0)
    }

    @Test("two begins and one completed still yields")
    func twoBeginsOneCompletedStillYields() {
        let afterFirst = SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: 0,
            event: .begin)
        let afterSecond = SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: afterFirst,
            event: .begin)
        let afterOneDone = SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: afterSecond,
            event: .completed)
        #expect(afterFirst == 1)
        #expect(afterSecond == 2)
        #expect(afterOneDone == 1)
        #expect(SfuSignalingUplinkYieldPolicy.shouldYield(
            isGroupOrConference: true,
            essentialInFlightCount: afterOneDone))
    }

    @Test("1:1 never yields even with in-flight count")
    func oneToOneDoesNotYield() {
        #expect(!SfuSignalingUplinkYieldPolicy.shouldYield(
            isGroupOrConference: false,
            essentialInFlightCount: 5))
    }

    @Test("group yields only while count is above zero")
    func groupYieldsWhenCountPositive() {
        #expect(!SfuSignalingUplinkYieldPolicy.shouldYield(
            isGroupOrConference: true,
            essentialInFlightCount: 0))
        #expect(SfuSignalingUplinkYieldPolicy.shouldYield(
            isGroupOrConference: true,
            essentialInFlightCount: 1))
    }

    @Test("immediate apply is only the 0 to 1 edge")
    func applyImmediatelyOnlyOnZeroToOne() {
        #expect(SfuSignalingUplinkYieldPolicy.shouldApplyImmediately(
            previousCount: 0,
            newCount: 1))
        #expect(!SfuSignalingUplinkYieldPolicy.shouldApplyImmediately(
            previousCount: 1,
            newCount: 2))
        #expect(!SfuSignalingUplinkYieldPolicy.shouldApplyImmediately(
            previousCount: 1,
            newCount: 0))
        #expect(!SfuSignalingUplinkYieldPolicy.shouldApplyImmediately(
            previousCount: 0,
            newCount: 0))
    }

    @Test("yield targets match survival targets for the same config")
    func yieldTargetsMatchSurvival() {
        let cfg = RTCVideoQualityProfile.standard.adaptiveConfig
        let survival = RTCAdaptiveVideoTargets.survivalTargets(cfg: cfg)
        #expect(survival.maxBitrateBps == max(80_000, min(cfg.maxBitrateBps, RTCAdaptiveVideoTargets.survivalBitrateBps)))
        #expect(survival.maxFramerate == min(cfg.lowFps, RTCAdaptiveVideoTargets.survivalFramerate))
        #expect(survival.scaleResolutionDownBy == RTCAdaptiveVideoTargets.survivalScaleResolutionDownBy)
    }

    @Test("offer answer and mediaReady sites note essential outbound")
    func essentialSitesNoteOutbound() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let groupCall = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+GroupCall.swift"
            ),
            encoding: .utf8
        )
        let exchange = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+Exchange.swift"
            ),
            encoding: .utf8
        )
        #expect(groupCall.contains("noteEssentialOutbound(.begin"))
        #expect(groupCall.contains("noteEssentialOutbound(.completed"))
        #expect(exchange.contains("noteEssentialOutbound(.begin"))
        #expect(exchange.contains("noteEssentialOutbound(.completed"))
        #expect(!groupCall.contains("Task.sleep"))
        #expect(!exchange.contains("Task.sleep"))
    }
}
