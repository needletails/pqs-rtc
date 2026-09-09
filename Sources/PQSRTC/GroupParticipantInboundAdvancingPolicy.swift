import Foundation

/// Connection-wide inbound decode can be another participant's camera.
/// A mapped tile with no renderer callbacks is not advancing for that source.
enum GroupParticipantInboundAdvancingPolicy {
    static func isSourceInboundAdvancing(
        connectionInboundIsAdvancing: Bool,
        mappedRendererCallbackAgeMs: Int64
    ) -> Bool {
        connectionInboundIsAdvancing && mappedRendererCallbackAgeMs >= 0
    }
}
