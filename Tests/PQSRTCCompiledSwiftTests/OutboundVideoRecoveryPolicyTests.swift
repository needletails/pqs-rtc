import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct OutboundVideoRecoveryPolicyTests {
    @Test("muted no-traffic recovery does not enable audio")
    func mutedNoTrafficRecoveryDoesNotEnableAudio() {
        #expect(
            OutboundVideoRecoveryPolicy.shouldKickAudio(
                userAudioEgressDisabled: true,
                flowState: OutboundVideoRecoveryFlowState.noTraffic,
                audioPacketsSent: 0,
                deltaAudioPacketsSent: 0
            ) == false
        )
    }

    @Test("unmuted no-traffic recovery may kick audio")
    func unmutedNoTrafficRecoveryMayKickAudio() {
        #expect(
            OutboundVideoRecoveryPolicy.shouldKickAudio(
                userAudioEgressDisabled: false,
                flowState: OutboundVideoRecoveryFlowState.noTraffic,
                audioPacketsSent: 0,
                deltaAudioPacketsSent: 0
            )
        )
    }

    @Test("advancing audio is never kicked")
    func advancingAudioIsNeverKicked() {
        #expect(
            OutboundVideoRecoveryPolicy.shouldKickAudio(
                userAudioEgressDisabled: false,
                flowState: OutboundVideoRecoveryFlowState.stalledEgress,
                audioPacketsSent: 10,
                deltaAudioPacketsSent: 1
            ) == false
        )
    }

    @Test("production recovery delegates audio kick to mute-preserving policy")
    func productionRecoveryUsesMutePreservingPolicy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+Stats.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("OutboundVideoRecoveryPolicy.shouldKickAudio"))
        #expect(source.contains("userAudioEgressDisabled:"))
    }
}
