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
}

