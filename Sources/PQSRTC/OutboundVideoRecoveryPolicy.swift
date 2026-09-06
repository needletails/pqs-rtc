import Foundation

enum OutboundVideoRecoveryFlowState: String, Sendable {
    case noTraffic
    case stalledEgress
    case advancingEgress
    case encodeStalled
}

/// Preserves user audio intent while recovering an independently stalled video sender.
enum OutboundVideoRecoveryPolicy {
    static func shouldKickAudio(
        userAudioEgressDisabled: Bool,
        flowState: OutboundVideoRecoveryFlowState,
        audioPacketsSent: Int64,
        deltaAudioPacketsSent: Int64
    ) -> Bool {
        guard !userAudioEgressDisabled else { return false }
        return flowState == .noTraffic
            && audioPacketsSent == 0
            && deltaAudioPacketsSent <= 0
    }
}
