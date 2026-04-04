import Foundation

public enum PQSRTCDiagnostics: Sendable {
    /// When true, PQSRTC may run additional background telemetry loops and emit high-volume logs.
    ///
    /// Default: false (unless compiled with `-D PQSRTC_CRITICAL_BUG_LOGGING`).
    public static let criticalBugLoggingEnabled: Bool = {
#if PQSRTC_CRITICAL_BUG_LOGGING
        return true
#else
        return false
#endif
    }()

    /// Enables **high-volume** remote-video diagnostics (I420 wire dumps, first-frame traces, RTP attach
    /// snapshots, inbound/outbound video flow probes, etc.) at log level **`.trace`**.
    ///
    /// - **DEBUG** builds: enabled by default (no env var needed).
    /// - **Release** builds: disabled unless the process environment sets **`PQSRTC_REMOTE_VIDEO_TRACE_LOGGING=1`**.
    ///
    /// `NeedleTailMediaKit` / `MetalProcessor` uses the same env var name for matching I420-upload traces.
    public static let remoteVideoTraceLoggingEnabled: Bool = {
#if DEBUG
        return true
#else
        return ProcessInfo.processInfo.environment["PQSRTC_REMOTE_VIDEO_TRACE_LOGGING"] == "1"
#endif
    }()
}

