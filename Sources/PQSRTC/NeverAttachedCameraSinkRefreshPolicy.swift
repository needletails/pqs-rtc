import Foundation

/// Sink-only refresh when a mapped Apple camera tile never received `renderFrame`
/// while connection-level inbound decode is already advancing.
///
/// Aggregate RTP stats can move because another participant is decoding. The stall
/// watchdog must not treat that as a healthy tile, and must not run decode-stall
/// pulse/cryptor churn. Join-path grace stays on `prolongedStallThresholdMs`.
enum NeverAttachedCameraSinkRefreshPolicy {
    static func shouldRefreshRemoteCameraSink(
        inboundFlowIsAdvancing: Bool,
        hasAnyCallbacks: Bool,
        callbackAgeMs: Int64,
        expectationAgeMs: Int64,
        prolongedStallThresholdMs: Int64 = 12_000
    ) -> Bool {
        guard inboundFlowIsAdvancing else { return false }
        guard !hasAnyCallbacks else { return false }
        let effectiveAgeMs = callbackAgeMs >= 0 ? callbackAgeMs : expectationAgeMs
        return effectiveAgeMs >= prolongedStallThresholdMs
    }
}
